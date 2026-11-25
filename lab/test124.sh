#!/bin/bash
# ОПЫТ 124 (25.11), модуль 1125c, наша GF114: обычная работа с порядком NVIDIA (lab_nv_xbarmem = −1 — снова по умолчанию после
# опыта 123: шина XBAR поднимается после памяти и опускается до неё) и со всеми правками 24.11. N1 кругов 03 -> 0f -> 07 -> 03
# под нагрузкой браузера (ядро + память). Стоп на первой ошибке или зависании. Вопрос опыта: чист ли порядок NVIDIA вместе с
# ожиданиями после строба (до них на этом порядке было одно зависание на ≈ 4150 подъёмов, опыт 99).
# Запуск по SSH внутри screen:   screen -S test124 bash ~/Home/nouveau-fix/lab/test124.sh [N1=3000]
# Пароль sudo — один раз в начале; потом Ctrl-a d (отцепиться). Итог — results/test124-*.txt (+ .sum, .load).
set -uo pipefail
KIT=~/Home/nouveau-fix; LAB="$KIT/lab"; PRM=/sys/module/nouveau/parameters
N1="${1:-3000}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"; export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
[ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
scr() { gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver."$@" 2>&1; }
for p in lab_mem_syncwait lab_mem_vidmask lab_nv_xbarmem lab_mem_line750; do
    [ -e "$PRM/$p" ] || { echo "В модуле нет $p — нужна сборка 1125c или новее"; exit 1; }
done
if [ -z "${TEST124_INH:-}" ]; then
    scr SetActive false >/dev/null; sleep 2
    exec env TEST124_INH=1 HANG_INHIBITED=1 NIGHT_INHIBITED=1 GOV_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend \
         --reason "nouveau test124" bash "$0" "$@"
fi
mkdir -p "$KIT/results"; OUT="$KIT/results/test124-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
( while sleep 30; do echo "$(date +%T) gr=$(cat $PRM/lab_perf_gr 2>/dev/null)‰ экран погашен: $(scr GetActive)" >> "$OUT.load"; done ) & SAMP=$!
S0="$(cat $PRM/lab_mem_syncwait)"; V0="$(cat $PRM/lab_mem_vidmask)"; G0="$(cat $PRM/lab_gov)"
finish() {
    kill $KEEP $SAMP 2>/dev/null
    w lab_mem_syncwait "$S0"; w lab_mem_vidmask "$V0"; w lab_gov "$G0"
    grep -E "опыт 124|^.{8} ---|итог|журнал|стоп|СТОП|=== конец|экран|нагрузка за опыт" "$OUT" > "$OUT.sum"
}
trap finish EXIT
ERRPAT='Xid|FAULT|TRAP|DATA_ERROR|ТАЙМ-АУТ|не переключилась|отклон|failed to idle|SCHED_ERROR|ОСТАЛСЯ НА PLL|fifo: fault|killed|нет пути|не годится'
say "опыт 124: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), $(sudo journalctl -k -b 0 --no-pager | grep -m1 -oE 'LAB build: .*'), загрузка $(uptime -s); N1=$N1"
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

[ "$(cat $PRM/lab_nv_xbarmem)" = -1 ] || { say "СТОП: lab_nv_xbarmem=$(cat $PRM/lab_nv_xbarmem), а опыт — про порядок по умолчанию (−1)"; exit 1; }
say "--- обычная работа, порядок NVIDIA: $N1 кругов 03 -> 0f -> 07 -> 03 (ядро + память)"
T="$(date "+%F %T")"; rounds "$N1"; report "$T"
say "    порядок в журнале: $(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -oE 'LAB nv_(hub07mem|xbarmem): [^$]*' | sort | uniq -c | sort -rn | head -n 3 | tr '\n' ';' | cut -c1-200)"
say "нагрузка за опыт (файл .load): замеров $(wc -l < "$OUT.load"), с погашенным экраном $(grep -c 'true' "$OUT.load"), с загрузкой GR ниже 20‰: $(awk -F'gr=|‰' '$2 + 0 < 20' "$OUT.load" | wc -l)"
say "=== конец опыта 124: ошибок нет"
