#!/bin/bash
# ОПЫТ «СОН БЕЗ НАШИХ ЧАСТОТ» — точка отсчёта: засыпает ли компьютер и просыпается ли вообще,
# если карта с момента загрузки ни разу не переключалась (служба автопереключения выключена).
#   sleep0.sh run   — проверить, что переключений с загрузки не было, включить «чёрный ящик» сна (pm_trace)
#                     и уснуть. Будить — коротким нажатием кнопки питания (или клавишей) секунд через 15.
#   sleep0.sh after — после перезагрузки (если зависло): прочитать «чёрный ящик» — на каком устройстве встало.
# «Чёрный ящик» pm_trace: при засыпании/пробуждении ядро пишет номер текущего устройства в часы (RTC) —
# они переживают даже выключение питания. Побочный эффект: часы после этого врут, их поправит интернет-время.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"
mkdir -p "$KIT/results"
case "${1:-}" in
run)
    LOG="$KIT/results/sleep0-$(date +%Y%m%d-%H%M%S).txt"
    say() { echo "$*" | tee -a "$LOG"; sync; }
    sudo -v || exit 1
    ok=1
    [ "$(modinfo -n nouveau)" = "/lib/modules/$(uname -r)/updates/nouveau-fix/nouveau.ko" ] && echo "  ✓ драйвер тот же (лабораторный)" || { echo "  ✗ загружен другой драйвер"; ok=0; }
    systemctl is-active --quiet gpu-autoclock.service && { echo "  ✗ служба автопереключения работает (нужно выключить и перезагрузиться)"; ok=0; } || echo "  ✓ служба автопереключения не работает"
    N="$(journalctl -k -b 0 --no-pager | grep -c 'LAB pstate' || true)"
    [ "$N" = 0 ] && echo "  ✓ с загрузки карта ни разу не переключалась" || { echo "  ✗ с загрузки были переключения ($N) — нужна перезагрузка с выключенной службой"; ok=0; }
    [ -e /sys/power/pm_trace ] && echo "  ✓ «чёрный ящик» pm_trace есть в ядре" || { echo "  ✗ pm_trace нет в ядре"; ok=0; }
    echo "  вид сна: $(cat /sys/power/mem_sleep)"
    echo "  режим сейчас: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    [ "$ok" = 1 ] || { echo "--- СТОП: окружение не то. Опыт не запускаю."; exit 1; }
    echo "--- Окружение верное"
    echo "Компьютер уснёт. Подожди ~15 с и разбуди КОРОТКИМ нажатием кнопки питания."
    echo "Если экран не включится за минуту: нажми Caps Lock — мигает ли лампочка? Потом выключи (держать 5 с),"
    echo "включи и запусти: bash ~/nouveau-fix/lab/sleep0.sh after"
    read -r -p "Начинаем? Enter — да, Ctrl+C — отмена " _
    say "Сон без наших частот $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), ядро $(uname -r)"
    say "до сна: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    T0="$(date '+%F %T')"
    sudo sh -c 'echo 1 > /sys/power/pm_print_times; echo 1 > /sys/power/pm_trace'
    say "$(date +%T) засыпаю (pm_trace включён)..."
    sudo sh -c 'echo mem > /sys/power/state'; RC=$?
    sleep 3
    sudo sh -c 'echo 0 > /sys/power/pm_trace'
    say "проснулся (код $RC), часы сейчас: $(date +%T) — могут врать из-за pm_trace"
    say "после сна: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    say "--- журнал с момента сна (сон, пробуждение, драйвер):"
    journalctl -k -b 0 --no-pager --since "$T0" | grep -E 'PM:|nouveau|ACPI: (PM|Waking)|resume|timeout|error|fail' \
      | sed -E 's/^.*kernel: //' | grep -vE 'calling|returned 0 after' | tail -n 40 | tee -a "$LOG"
    say "=== Сон без наших частот: компьютер проснулся ✅"
    say "Служба автопереключения выключена. Включить снова: sudo systemctl enable --now gpu-autoclock.service"
    say "Лог: $LOG"
    ;;
after)
    LOG="$KIT/results/sleep0-after-$(date +%Y%m%d-%H%M%S).txt"
    { echo "Чтение «чёрного ящика» $(date '+%F %T')"
      journalctl -k -b 0 --no-pager | grep -E 'PM: +Magic number|hash matches' | sed -E 's/^.*kernel: //'
      echo "--- пред. загрузка: последние строки журнала"
      journalctl -b -1 --no-pager | tail -n 15 | sed -E 's/^[A-Za-z]+ [0-9]+ //'
    } | tee "$LOG"
    grep -q 'hash matches' "$LOG" && echo "=== Есть совпадение — устройство, на котором встало, названо выше" \
      || echo "=== Совпадения нет: либо встало вне драйверов устройств (прошивка, процессор), либо часы перебили до записи"
    echo "Лог: $LOG"
    ;;
*) echo "Использование: sleep0.sh run | after"; exit 1;;
esac
