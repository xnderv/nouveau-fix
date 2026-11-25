#!/bin/bash
# ОПЫТ 121 (24.11), модуль 1124a, наша GF114 (GDDR5): правки повтора памяти — каждая отдельно, затем вместе. Стоп на ошибке.
#   0 — контроль: обе новые ветки выключены (lab_mem_syncwait=0, lab_mem_vidmask=0), то есть как сборка 1123c: 30 кругов
#       03 -> 0f -> 07 -> 03 (ядро + память, все пять скриптов);
#   А — только ожидания после записи 0x13d8x4 (lab_mem_syncwait=1): N кругов;
#   Б — только маска линий напряжения в прямых записях (lab_mem_vidmask=1): N/2 кругов, затем сверка напряжения ядра и линий
#       GPIO с записью NVIDIA на 0f, 07 и 03 (voltcheck.py);
#   В — обе вместе (значения по умолчанию): «только память» 07 <-> 0f × 3N/4 и 03 <-> 0f × 3N/8 под glxgears.
# Третья правка (состояние памяти по регистрам 0x137360 / 0x132004) на GDDR5 не срабатывает (там 0x137360 = 1): проверяется
# только, что строка «память теперь» в журнале совпадает с уровнем. Экран будится и удерживается (gnome-session-inhibit);
# каждые 30 с в файл .load пишутся загрузка графического блока и состояние экрана — видно, была ли нагрузка весь опыт.
# Запуск по SSH внутри screen (переживает разрыв связи):   screen -S mem121 bash ~/Home/nouveau-fix/lab/mem121.sh [N=200]
# Пароль sudo — один раз в начале; потом Ctrl-a d (отцепиться). Итог — results/test121-*.txt (+ .sum, .load).
set -uo pipefail
KIT=~/Home/nouveau-fix; LAB="$KIT/lab"; PRM=/sys/module/nouveau/parameters; N="${1:-200}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"; export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
[ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
scr() { gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver."$@" 2>&1; }
for p in lab_mem_syncwait lab_mem_vidmask lab_mem_unit_ns; do
    [ -e "$PRM/$p" ] || { echo "В модуле нет $p — нужна сборка 1124a или новее"; exit 1; }
done
if [ -z "${MEM121_INH:-}" ]; then
    scr SetActive false >/dev/null; sleep 2
    exec env MEM121_INH=1 HANG_INHIBITED=1 NIGHT_INHIBITED=1 GOV_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend \
         --reason "nouveau mem121" bash "$0" "$@"
fi
mkdir -p "$KIT/results"; OUT="$KIT/results/test121-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
( while sleep 30; do echo "$(date +%T) gr=$(cat $PRM/lab_perf_gr 2>/dev/null)‰ экран погашен: $(scr GetActive)" >> "$OUT.load"; done ) & SAMP=$!
S0="$(cat $PRM/lab_mem_syncwait)"; V0="$(cat $PRM/lab_mem_vidmask)"; G0="$(cat $PRM/lab_gov)"
PSF="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n 1')"
finish() {
    kill $KEEP $SAMP 2>/dev/null
    w lab_mem_syncwait "$S0"; w lab_mem_vidmask "$V0"; w lab_gov "$G0"
    grep -E "опыт 121|^.{8} ---|итог|журнал|напряжени|стоп|СТОП|=== конец|экран" "$OUT" > "$OUT.sum"
}
trap finish EXIT
ERRPAT='Xid|FAULT|TRAP|DATA_ERROR|ТАЙМ-АУТ|не переключилась|отклон|failed to idle|SCHED_ERROR|ОСТАЛСЯ НА PLL|fifo: fault|killed|нет пути|не годится'
say "опыт 121: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), $(sudo journalctl -k -b 0 --no-pager | grep -m1 -oE 'LAB build: .*'), загрузка $(uptime -s); N=$N"
say "ключи при старте: lab_mem_syncwait=$S0 lab_mem_vidmask=$V0 lab_mem_unit_ns=$(cat $PRM/lab_mem_unit_ns) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_gov=$G0"
a="$(scr GetActive)"; say "экран погашен: $a"
case "$a" in *false*) ;; *) say "СТОП: экран не разбудился — нагрузки не будет"; exit 1;; esac

# после части: ошибки журнала ядра и счёт строк повтора за часть
report() {   # $1 — время начала части
    local j; j="$(sudo journalctl -k -b 0 --no-pager --since "$1")"
    local e; e="$(echo "$j" | grep -cE "$ERRPAT")"
    say "    журнал: ошибок $e; шагов повтора $(echo "$j" | grep -c 'LAB replay .*: выполнен за'), из них с ожиданиями после 0x13d8x4: $(echo "$j" | grep -c 'ожиданий после 0x13d8x4: [1-9]'), без них: $(echo "$j" | grep -c 'ожиданий после 0x13d8x4: 0 '); списков с сохранёнными линиями напряжения: $(echo "$j" | grep -c 'линиями напряжения ядра: [1-9]')"
    say "    журнал: память после шагов — $(echo "$j" | grep -oE '(replay [A-E][^:]*): выполнен.*память теперь [0-9]+ МГц' | sed -E 's/: выполнен.*память теперь/ →/' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
    say "    экран погашен: $(scr GetActive); загрузка GR сейчас $(cat $PRM/lab_perf_gr 2>/dev/null)‰"
    [ "$e" = 0 ] || { echo "$j" | grep -E "$ERRPAT" | head -n 5 | tee -a "$OUT"; say "    стоп"; exit 1; }
}
rounds() {   # $1 — число кругов 03 -> 0f -> 07 -> 03 под нагрузкой браузера
    FAST=1 LOW=03 HIGH=0f MID=07 bash "$LAB/hangtest.sh" "$1" > /dev/null 2>&1; local rc=$?
    local h; h="$(ls -t "$KIT"/results/hangtest-*.txt | head -n 1)"
    say "    итог: код $rc; $(grep -E '^=== ' "$h" | tail -n 1 | sed -E 's/ Лог:.*//') ($(basename "$h"))"
    grep -qE "^=== $1 подъёмов без зависания" "$h" || { say "    стоп"; exit 1; }
}
memonly() {  # $1 — число переключений туда-обратно, $2 — нижний уровень (пусто — средний)
    LOWER="$2" RESULTS="$KIT/results" bash "$LAB/memonly-test.sh" "$1" 3 > /dev/null 2>&1
    local f; f="$(ls -t "$KIT"/results/memonly-*.txt | head -n 1)"
    say "    итог: $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //') ($(basename "$f"))"
    grep -q 'ошибок нет' <(grep '=== итог' "$f") || { say "    стоп"; exit 1; }
}

say "--- 0: контроль, как 1123c (ожиданий нет, 0x00e104 пропускается), 30 кругов"
w lab_mem_syncwait 0; w lab_mem_vidmask 0; T="$(date "+%F %T")"; rounds 30; report "$T"

say "--- А: только ожидания после 0x13d8x4, $N кругов"
w lab_mem_syncwait 1; w lab_mem_vidmask 0; T="$(date "+%F %T")"; rounds "$N"; report "$T"

say "--- Б: только маска линий напряжения, $((N / 2)) кругов"
w lab_mem_syncwait 0; w lab_mem_vidmask 1; T="$(date "+%F %T")"; rounds "$((N / 2))"
w lab_gov 0
for L in 0f 07 03; do
    sudo sh -c "echo $L > $PSF"; sleep 3
    v="$(sudo python3 -I "$LAB/voltcheck.py" 2>&1)"
    say "    напряжение на $L: $(echo "$v" | grep -oE 'ядро: VID [0-9]+ \([0-9b]+\) -> [0-9.]+ В'); $(echo "$v" | grep -E 'напряжение ядра:' | sed -E 's/^ +//')"
    echo "$v" | grep -q 'напряжение ядра: ✅' || { say "    СТОП: напряжение ядра не как у NVIDIA"; echo "$v" | tee -a "$OUT"; exit 1; }
done
w lab_gov "$G0"; report "$T"

say "--- В: обе правки вместе (по умолчанию), только память 07 <-> 0f, $((N * 3 / 4)) раз"
w lab_mem_syncwait 1; w lab_mem_vidmask 1; T="$(date "+%F %T")"; memonly "$((N * 3 / 4))" ""; report "$T"
say "--- В2: обе правки вместе, только память 03 <-> 0f, $((N * 3 / 8)) раз"
T="$(date "+%F %T")"; memonly "$((N * 3 / 8))" 03; report "$T"
say "нагрузка за опыт (файл .load): замеров $(wc -l < "$OUT.load"), с погашенным экраном $(grep -c 'true' "$OUT.load"), с загрузкой GR ниже 50‰: $(awk -F'gr=|‰' '$2 + 0 < 50' "$OUT.load" | wc -l)"
say "=== конец опыта 121: ошибок нет"
