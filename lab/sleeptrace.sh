#!/bin/bash
# ЗАПИСЬ СБОЯ СНА, версия 2.
# Что известно из журнала сбоя 17:34: systemd заморозил сеанс пользователя (user.slice) — и дальше 16+ с НЕ дошёл
# до «Performing sleep operation», ядро засыпать даже не начинало. В удачном сне этот шаг занимает 0,05 с.
# Между этими двумя точками systemd-sleep выполняет «крючки сна» (/usr/lib/systemd/system-sleep, /etc/systemd/system-sleep),
# ждёт каждый до 90 с. Экран при этом «мёртвый», потому что рабочий стол заморожен, — компьютер может быть жив.
# Поэтому записываем НЕ ядро, а то, чем занят systemd-sleep:
#   - отдельный «наблюдатель» (системная служба, её сон пользователя не замораживает) раз в секунду пишет в файл:
#     кто сейчас дочерний процесс systemd-sleep (какой крючок), их состояние и где они ждут в ядре,
#     все процессы в состоянии D (непрерываемое ожидание), состояние службы автопереключения;
#   - каждая запись сразу сбрасывается на диск (переживает Reset).
# Условия — как при сбое: служба автопереключения работает, засыпание обычным systemctl suspend, рабочий стол активен.
# Запуск: bash ~/nouveau-fix/lab/sleeptrace.sh run      Посмотреть запись: ... sleeptrace.sh show
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
case "${1:-}" in
run)
    TS="$(date +%Y%m%d-%H%M%S)"; LOG="$KIT/results/sleeptrace-$TS.txt"; W="$KIT/results/sleepwatch-$TS.txt"
    say() { echo "$*" | tee -a "$LOG"; sync; }
    sudo -v || exit 1
    # остатки прошлой попытки (17:48 — прервана): вернуть настройки по умолчанию
    sudo sh -c 'echo 0 > /sys/power/pm_trace; echo 0 > /sys/power/pm_debug_messages; echo 0 > /sys/power/pm_print_times;
                echo Y > /sys/module/printk/parameters/console_suspend; dmesg -n 4' 2>/dev/null
    ok=1
    systemctl is-active --quiet gpu-autoclock.service && echo "  ✓ служба автопереключения работает (условие сбоя)" \
      || { echo "  ✗ служба не работает — запусти: sudo systemctl start gpu-autoclock.service"; ok=0; }
    if systemctl is-enabled --quiet gpu-autoclock-sleep.service 2>/dev/null; then
        echo "  ✗ стоит «ассистент сна» — сбой не повторится. Временно: sudo systemctl disable gpu-autoclock-sleep.service"; ok=0
    else echo "  ✓ «ассистента сна» нет"; fi
    systemctl is-active --quiet sleepwatch.service && { echo "  ✗ наблюдатель уже запущен: sudo systemctl stop sleepwatch.service"; ok=0; }
    [ "$ok" = 1 ] || { echo "--- СТОП: окружение не то."; exit 1; }
    echo "--- Окружение верное"
    echo
    echo "ЧТО БУДЕТ: запустится наблюдатель, затем компьютер пойдёт в сон обычным способом (рабочий стол НЕ переключается)."
    echo "  • Уснул — через 15 с разбуди коротким нажатием кнопки питания. Потом: bash ~/nouveau-fix/lab/sleeptrace.sh show"
    echo "  • Экран застыл и не гаснет — НЕ жми Reset сразу: подожди 2 минуты (systemd ждёт зависший крючок до 90 с"
    echo "    и потом может уснуть сам — тогда разбуди кнопкой). Если через 2 минуты всё ещё застыл:"
    echo "    зажми Alt+PrtSc и нажми S, подожди 5 с, потом Alt+PrtSc+B (перезагрузка). Не помогло — Reset."
    echo "    После загрузки: bash ~/nouveau-fix/lab/sleeptrace.sh show"
    read -r -p "Понятно, начинаем? Enter — да, Ctrl+C — отмена " _
    PID="$(systemctl show -p MainPID --value gpu-autoclock.service)"
    say "Запись сбоя сна v2 $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), ядро $(uname -r), служба pid $PID"
    say "режим карты: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    say "--- крючки сна:"
    ls -l /usr/lib/systemd/system-sleep /etc/systemd/system-sleep 2>&1 | tee -a "$LOG"; sync
    say "--- служба перед сном: $(sudo grep '^State' /proc/$PID/status), ждёт: $(sudo cat /proc/$PID/wchan)"
    sudo systemd-run --quiet --unit=sleepwatch --collect -p RuntimeMaxSec=600 /bin/bash -c '
        W="'"$W"'"; SPID="'"$PID"'"
        for i in $(seq 1 400); do
          {
            echo "=== $(date +%T.%N | cut -c1-12)"
            for p in $(pgrep -x systemd-sleep); do
              echo "systemd-sleep $p: $(grep ^State /proc/$p/status) ждёт: $(cat /proc/$p/wchan 2>/dev/null)"
              for c in $(pgrep -P $p); do
                echo "  дочерний $c: $(tr "\0" " " < /proc/$c/cmdline 2>/dev/null | cut -c1-150) | $(grep ^State /proc/$c/status) | ждёт: $(cat /proc/$c/wchan 2>/dev/null)"
                for g in $(pgrep -P $c); do echo "    внук $g: $(tr "\0" " " < /proc/$g/cmdline 2>/dev/null | cut -c1-150) | $(grep ^State /proc/$g/status) | ждёт: $(cat /proc/$g/wchan 2>/dev/null)"; done
              done
              sed "s/^/    стек: /" /proc/$p/stack 2>/dev/null | head -n 8
            done
            ps -eo pid,stat,wchan:32,args --no-headers | awk "\$2 ~ /^D/" | cut -c1-200 | sed "s/^/D: /"
            [ -d /proc/$SPID ] && echo "служба: $(grep ^State /proc/$SPID/status) ждёт: $(cat /proc/$SPID/wchan)"
          } >> "$W"
          sync "$W"
          sleep 1
        done'
    sleep 2
    [ -s "$W" ] && say "наблюдатель пишет в $W" || { say "--- СТОП: наблюдатель не пишет"; exit 1; }
    say "$(date +%T) засыпаю: systemctl suspend"
    T0="$(date '+%F %T')"
    systemctl suspend
    for i in $(seq 1 240); do
        journalctl -b 0 --no-pager --since "$T0" | grep -q 'System returned from sleep operation' && break
        sleep 1
    done
    sleep 3
    sudo systemctl stop sleepwatch.service 2>/dev/null
    say "$(date +%T) вернулся"
    "$0" show "$TS"
    ;;
show)
    TS="${2:-$(ls -t "$KIT"/results/sleepwatch-*.txt 2>/dev/null | head -n 1 | sed -E 's/.*sleepwatch-(.*)\.txt/\1/')}"
    W="$KIT/results/sleepwatch-$TS.txt"; LOG="$KIT/results/sleeptrace-$TS.txt"
    [ -s "$W" ] || { echo "Нет записи наблюдателя"; exit 1; }
    sudo systemctl stop sleepwatch.service 2>/dev/null
    { echo "--- запись наблюдателя $W: секунд $(grep -c '^===' "$W")"
      echo "--- секунды, где был systemd-sleep (первые 30 строк и последние 40):"
      awk '/^===/{t=$0} /systemd-sleep|дочерний|внук|^D: /{print t" | "$0}' "$W" | head -n 30
      echo "..."
      awk '/^===/{t=$0} /systemd-sleep|дочерний|внук|стек|^D: /{print t" | "$0}' "$W" | tail -n 40
      echo "--- журнал systemd-sleep:"
      journalctl -b -1 --no-pager -t systemd-sleep 2>/dev/null | tail -n 5
      journalctl -b 0 --no-pager -t systemd-sleep | tail -n 5
    } | tee -a "$LOG"
    echo "Лог: $LOG"
    ;;
*) echo "Использование: sleeptrace.sh run | show"; exit 1;;
esac
