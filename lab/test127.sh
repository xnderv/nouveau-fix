#!/bin/bash
# ОПЫТ 127 (26.11), наша GF114: длинный прогон обычной работы на порядке NVIDIA (lab_nv_xbarmem = -1: память снаружи шины
# XBAR2CLK) на той же сборке и тем же сценарием, что опыт 125. Опыт 125 (наш порядок 1, шина снаружи памяти) остановился
# на 6727-м круге: сбой страницы графического блока в начале шага памяти, восстановление не удалось, блок встал
# (docs/2026-11-26/hang-125.md). Всего на порядке 1 — один сбой на 10 357 кругов; на порядке NVIDIA после правок 24.11
# пройдено только 3000 кругов (опыт 124) — при той же частоте сбоев чистый прогон такой длины вышел бы в 75 % случаев.
# Вопрос: есть ли такой же редкий сбой на порядке NVIDIA. Одно отличие от опыта 125 — порядок.
# Сколько кругов (сбой считаем редким независимым событием, оценка частоты — 1 на 10 357 кругов):
#   10 000 кругов — сбой поймается с вероятностью 62 %; 20 000 — 85 %; 30 000 — 94,5 %; 35 000 — 96,6 %; 48 000 — 99 %.
# По умолчанию опыт идёт ДО СРОКА (UNTIL, по умолчанию «завтра 10:00»): число кругов не задаётся, а подбирается по
# времени — каждая часть берёт столько кругов, сколько помещается до срока по измеренному темпу (на порядке NVIDIA в
# опыте 124 круг занимал 2,38 с; запуск около 11:00 даёт примерно 34 800 кругов). Последняя часть укорачивается, чтобы
# закончить за пару минут до срока. Если число кругов задано первым аргументом — идёт ровно столько, срок не действует.
# Что значит исход: сбой с той же картиной — дело не в порядке (или не только в нём); чистый прогон — порядок NVIDIA не
# хуже 1 сбоя на 11 000 кругов (верхняя граница на 95 %), но различие порядков этим ещё не доказано: событие у нас одно.
# Идёт частями по CHUNK кругов (по умолчанию 5000, около 3,3 часа): после каждой части — проверка журнала ядра.
# ORDER=-1 (по умолчанию) | 0 | 1 — порядок на время опыта; в конце ключ возвращается.
# Запуск по SSH внутри screen:   screen -S test127 bash ~/Home/nouveau-fix/lab/test127.sh [N1]
#                                UNTIL="2026-11-27 10:00" screen -S test127 bash ~/Home/nouveau-fix/lab/test127.sh
# Пароль sudo — один раз в начале; потом Ctrl-a d (отцепиться). Итог — results/test127-*.txt (+ .sum, .load).
set -uo pipefail
KIT=~/Home/nouveau-fix; LAB="$KIT/lab"; PRM=/sys/module/nouveau/parameters
N1="${1:-0}"; ORDER="${ORDER:--1}"; CHUNK="${CHUNK:-5000}"; UNTIL="${UNTIL:-tomorrow 10:00}"
END="$(date -d "$UNTIL" +%s)" || { echo "UNTIL не разобран: $UNTIL"; exit 1; }      # срок считается один раз, при запуске
export UNTIL="$(date -d "@$END" "+%F %T")"                                          # дальше — готовой датой (скрипт перезапускает себя)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"; export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
[ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
scr() { gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver."$@" 2>&1; }
for p in lab_mem_syncwait lab_mem_vidmask lab_nv_xbarmem lab_mem_line750; do
    [ -e "$PRM/$p" ] || { echo "В модуле нет $p — нужна сборка 1125c или новее"; exit 1; }
done
if [ -z "${TEST127_INH:-}" ]; then
    scr SetActive false >/dev/null; sleep 2
    exec env TEST127_INH=1 HANG_INHIBITED=1 NIGHT_INHIBITED=1 GOV_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend \
         --reason "nouveau test127" bash "$0" "$@"
fi
mkdir -p "$KIT/results"; OUT="$KIT/results/test127-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
( while sleep 30; do echo "$(date +%T) gr=$(cat $PRM/lab_perf_gr 2>/dev/null)‰ экран погашен: $(scr GetActive)" >> "$OUT.load"; done ) & SAMP=$!
S0="$(cat $PRM/lab_mem_syncwait)"; V0="$(cat $PRM/lab_mem_vidmask)"; G0="$(cat $PRM/lab_gov)"; X0="$(cat $PRM/lab_nv_xbarmem)"
finish() {
    kill $KEEP $SAMP 2>/dev/null
    w lab_mem_syncwait "$S0"; w lab_mem_vidmask "$V0"; w lab_nv_xbarmem "$X0"; w lab_gov "$G0"
    grep -E "опыт 127|^.{8} ---|итог|журнал|стоп|СТОП|=== конец|экран|нагрузка за опыт" "$OUT" > "$OUT.sum"
}
trap finish EXIT
ERRPAT='Xid|FAULT|TRAP|DATA_ERROR|ТАЙМ-АУТ|не переключилась|отклон|failed to idle|SCHED_ERROR|ОСТАЛСЯ НА PLL|fifo: fault|killed|нет пути|не годится'
say "опыт 127: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), $(sudo journalctl -k -b 0 --no-pager | grep -m1 -oE 'LAB build: .*'), загрузка $(uptime -s); $( [ "$N1" -gt 0 ] && echo "кругов $N1" || echo "до срока $UNTIL" ), частями по $CHUNK"
say "ключи при старте: lab_mem_syncwait=$S0 lab_mem_vidmask=$V0 lab_mem_unit_ns=$(cat $PRM/lab_mem_unit_ns) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_gov=$G0 lab_nv_xbarmem=$(cat $PRM/lab_nv_xbarmem) lab_mem_line750=$(cat $PRM/lab_mem_line750)"
a="$(scr GetActive)"; say "экран погашен: $a"
case "$a" in *false*) ;; *) say "СТОП: экран не разбудился — нагрузки не будет"; exit 1;; esac

# GR встал? загрузка 999 ‰ и выше 10 секунд подряд
stuck() {
    local i g
    for i in 1 2 3 4 5 6 7 8 9 10; do
        g="$(cat $PRM/lab_perf_gr 2>/dev/null || echo 0)"; [ "$g" -ge 999 ] 2>/dev/null || return 1; sleep 1
    done
    return 0
}
report() {   # $1 — время начала части
    local j e; j="$(sudo journalctl -k -b 0 --no-pager --since "$1")"; e="$(echo "$j" | grep -cE "$ERRPAT")"
    say "    журнал: ошибок $e; шагов повтора $(echo "$j" | grep -c 'LAB replay .*: выполнен за'), с ожиданиями после 0x13d8x4: $(echo "$j" | grep -c 'ожиданий после 0x13d8x4: [1-9]'), без них: $(echo "$j" | grep -c 'ожиданий после 0x13d8x4: 0 ')"
    say "    экран погашен: $(scr GetActive); загрузка GR сейчас $(cat $PRM/lab_perf_gr 2>/dev/null)‰"
    [ "$e" = 0 ] || { echo "$j" | grep -E "$ERRPAT" | head -n 5 | tee -a "$OUT"; say "    стоп"; exit 1; }
    if stuck; then say "    СТОП: GR занят на 100 % дольше 10 с — похоже на зависание"; exit 1; fi
}
rounds() {
    FAST=1 LOW=03 HIGH=0f MID=07 bash "$LAB/hangtest.sh" "$1" > /dev/null 2>&1; local rc=$? h
    h="$(ls -t "$KIT"/results/hangtest-*.txt | head -n 1)"
    say "    итог: код $rc; $(grep -E '^=== ' "$h" | tail -n 1 | sed -E 's/ Лог:.*//') ($(basename "$h"))"
    grep -qE "^=== $1 подъёмов без зависания" "$h" || { say "    стоп"; exit 1; }
}

w lab_nv_xbarmem "$ORDER"
say "--- обычная работа, порядок lab_nv_xbarmem=$(cat $PRM/lab_nv_xbarmem) (было $X0): круги 03 -> 0f -> 07 -> 03 (ядро + память), частями по $CHUNK"
DONE=0; PART=0; PACE=2400; T00="$(date +%s)"      # PACE — миллисекунд на круг: начальная оценка, дальше — измеренная
while :; do
    if [ "$N1" -gt 0 ]; then n=$(( N1 - DONE ))
    else n=$(( ( END - 120 - $(date +%s) ) * 1000 / PACE )); fi      # сколько кругов помещается до срока (запас 2 мин)
    [ "$n" -ge 50 ] || break
    [ "$n" -gt "$CHUNK" ] && n="$CHUNK"; PART=$(( PART + 1 ))
    say "--- часть $PART: круги $(( DONE + 1 ))…$(( DONE + n )) (темп $PACE мс на круг)"
    T="$(date "+%F %T")"; rounds "$n"; report "$T"
    [ "$PART" = 1 ] && say "    порядок в журнале: $(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -oE 'LAB nv_(hub07mem|xbarmem): [^$]*' | sort | uniq -c | sort -rn | head -n 3 | tr '\n' ';' | cut -c1-200)"
    DONE=$(( DONE + n )); PACE=$(( ( $(date +%s) - T00 ) * 1000 / DONE ))
    say "    пройдено кругов: $DONE$( [ "$N1" -gt 0 ] && echo " из $N1" || echo "; срок $UNTIL" )"
done
say "нагрузка за опыт (файл .load): замеров $(wc -l < "$OUT.load"), с погашенным экраном $(grep -c 'true' "$OUT.load"), с загрузкой GR ниже 20‰: $(awk -F'gr=|‰' '$2 + 0 < 20' "$OUT.load" | wc -l)"
say "=== конец опыта 127: ошибок нет, кругов $DONE"
