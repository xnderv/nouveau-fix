#!/bin/bash
# ОПЫТ 122 (ночь 24–25.11), модуль 1124a, наша GF114. Длинный ночной прогон в четыре части; стоп на первой ошибке или
# зависании (после зависания GR нужна перезагрузка). Первым идёт контроль к зависанию опыта 121 — ради него и запуск:
#   1 — КОНТРОЛЬ: «только память» 03 <-> 0f (135 <-> 2004 МГц при ядре на 0f) БЕЗ сегодняшних правок
#       (lab_mem_syncwait=0, lab_mem_vidmask=0), N3 раз под glxgears. Зависнет — дело в самом сочетании «ядро наверху,
#       память 135 МГц под нагрузкой», а не в правках;
#   2 — то же со всеми правками, N3 раз (если часть 1 прошла): зависнет только здесь — под подозрением правки;
#   3 — обычная работа со всеми правками: N1 кругов 03 -> 0f -> 07 -> 03 под нагрузкой браузера (ядро + память);
#   4 — «только память» 07 <-> 0f (324 <-> 2004 при ядре на 0f), все правки, N2 раз под glxgears.
#   5 — стоянка: один заход на память 135 МГц при ядре на 0f, 10 минут под нагрузкой без переключений. Отделяет «опасно само
#       сочетание» от «опасны переключения в нём».
# SKIP12=1 — пропустить части 1 и 2 (24.11 21:24: часть 1 зависла на 7-м спуске — режим опасен и без правок).
# Экран будится и удерживается; каждые 30 с в файл .load пишутся загрузка GR и состояние экрана.
# Запуск по SSH внутри screen:   screen -S night122 bash ~/Home/nouveau-fix/lab/night122.sh [N1=3000] [N2=1500] [N3=600]
# Пароль sudo — один раз в начале; потом Ctrl-a d (отцепиться). Итог — results/test122-*.txt (+ .sum, .load).
set -uo pipefail
KIT=~/Home/nouveau-fix; LAB="$KIT/lab"; PRM=/sys/module/nouveau/parameters
N1="${1:-3000}"; N2="${2:-1500}"; N3="${3:-600}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"; export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
[ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
scr() { gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver."$@" 2>&1; }
for p in lab_mem_syncwait lab_mem_vidmask lab_mem_only; do
    [ -e "$PRM/$p" ] || { echo "В модуле нет $p — нужна сборка 1124a или новее"; exit 1; }
done
if [ -z "${NIGHT122_INH:-}" ]; then
    scr SetActive false >/dev/null; sleep 2
    exec env NIGHT122_INH=1 HANG_INHIBITED=1 NIGHT_INHIBITED=1 GOV_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend \
         --reason "nouveau night122" bash "$0" "$@"
fi
mkdir -p "$KIT/results"; OUT="$KIT/results/test122-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
( while sleep 30; do echo "$(date +%T) gr=$(cat $PRM/lab_perf_gr 2>/dev/null)‰ экран погашен: $(scr GetActive)" >> "$OUT.load"; done ) & SAMP=$!
S0="$(cat $PRM/lab_mem_syncwait)"; V0="$(cat $PRM/lab_mem_vidmask)"; G0="$(cat $PRM/lab_gov)"
finish() {
    kill $KEEP $SAMP 2>/dev/null
    w lab_mem_syncwait "$S0"; w lab_mem_vidmask "$V0"; w lab_gov "$G0"
    grep -E "опыт 122|^.{8} ---|итог|журнал|стоп|СТОП|=== конец|экран|нагрузка за опыт" "$OUT" > "$OUT.sum"
}
trap finish EXIT
ERRPAT='Xid|FAULT|TRAP|DATA_ERROR|ТАЙМ-АУТ|не переключилась|отклон|failed to idle|SCHED_ERROR|ОСТАЛСЯ НА PLL|fifo: fault|killed|нет пути|не годится'
say "опыт 122: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), $(sudo journalctl -k -b 0 --no-pager | grep -m1 -oE 'LAB build: .*'), загрузка $(uptime -s); N1=$N1 N2=$N2 N3=$N3"
say "ключи при старте: lab_mem_syncwait=$S0 lab_mem_vidmask=$V0 lab_mem_unit_ns=$(cat $PRM/lab_mem_unit_ns) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_gov=$G0"
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
memonly() {   # $1 — число заходов, $2 — нижний уровень (пусто — средний), $3 — сколько секунд стоять на уровне
    LOWER="$2" RESULTS="$KIT/results" bash "$LAB/memonly-test.sh" "$1" "$3" > /dev/null 2>&1; local f
    f="$(ls -t "$KIT"/results/memonly-*.txt | head -n 1)"
    say "    итог: $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //') ($(basename "$f"))"
    grep -q 'ошибок нет' <(grep '=== итог' "$f") || { say "    $(grep -m1 -E 'ОШИБКА' "$f" | cut -c1-120)"; say "    стоп"; exit 1; }
}

if [ "${SKIP12:-0}" != 1 ]; then
say "--- 1: КОНТРОЛЬ — только память 03 <-> 0f БЕЗ сегодняшних правок, $N3 раз"
w lab_mem_syncwait 0; w lab_mem_vidmask 0; T="$(date "+%F %T")"; memonly "$N3" 03 3; report "$T"

say "--- 2: только память 03 <-> 0f, все правки, $N3 раз"
w lab_mem_syncwait 1; w lab_mem_vidmask 1; T="$(date "+%F %T")"; memonly "$N3" 03 3; report "$T"
fi

say "--- 3: обычная работа, все правки: $N1 кругов 03 -> 0f -> 07 -> 03 (ядро + память)"
w lab_mem_syncwait 1; w lab_mem_vidmask 1; T="$(date "+%F %T")"; rounds "$N1"; report "$T"

say "--- 4: только память 07 <-> 0f, все правки, $N2 раз"
T="$(date "+%F %T")"; memonly "$N2" "" 3; report "$T"

say "--- 5: стоянка — память 135 МГц при ядре на 0f под нагрузкой, один заход на ${HOLD5:-600} с без переключений"
T="$(date "+%F %T")"; memonly 1 03 "${HOLD5:-600}"; report "$T"

say "нагрузка за опыт (файл .load): замеров $(wc -l < "$OUT.load"), с погашенным экраном $(grep -c 'true' "$OUT.load"), с загрузкой GR ниже 20‰: $(awk -F'gr=|‰' '$2 + 0 < 20' "$OUT.load" | wc -l)"
say "=== конец опыта 122: ошибок нет"
