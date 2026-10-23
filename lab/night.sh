#!/bin/bash
# НОЧНАЯ СЕРИЯ ТЕСТОВ (24.10). Запуск из терминала в графическом сеансе, окно браузера с нагрузкой будет на экране:
#   bash ~/Home/nouveau-fix/lab/night.sh
# Один раз пароль sudo (дальше его держит сам hangtest: sudo вызывается каждые несколько секунд).
# Экран не гаснет и система не засыпает (gnome-session-inhibit). Тесты по очереди, по 60 подъёмов; каждый — база
# (боевая конфигурация: память, PCIe, напряжение по таблице, скобка по признаку) + ровно свои отличия.
# На первом зависании: копия журнала ядра и ящика в results/, sync, и (AUTOREBOOT=1, по умолчанию) перезагрузка
# через SysRq (S, U, B) — как вручную. Дальнейшие тесты после перезагрузки не идут. Итог — results/night-*.txt.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; PRM=/sys/module/nouveau/parameters
AUTOREBOOT="${AUTOREBOOT:-1}"
if [ -z "${NIGHT_INHIBITED:-}" ]; then
    exec env NIGHT_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend --inhibit logout \
         --reason "nouveau night tests" bash "$0" "$@"
fi
for p in lab_therm_div lab_clk_mmu_lock lab_therm_real; do
    [ -e "$PRM/$p" ] || { echo "Нет параметра $p — загружен не тот драйвер"; exit 1; }
done
sudo -v || exit 1
mkdir -p "$KIT/results"; LOG="$KIT/results/night-$(date +%Y%m%d-%H%M).txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }
setp() { local kv; for kv in "$@"; do sudo sh -c "echo ${kv#*=} > $PRM/${kv%%=*}"; done; }
base() { setp lab_gov=0 lab_mem=1 lab_pcie=1 lab_volt_min_uv=0 lab_therm=1 lab_therm_wait=1 lab_therm_wait_us=0 \
              lab_therm_real=0 lab_therm_div=1 lab_clk_mmu_lock=0; }
hung() {
    local T; T="$(date +%Y%m%d-%H%M%S)"
    say "ЗАВИСАНИЕ в тесте $1 — сохраняю журнал и ящик"
    journalctl -b 0 -o short-precise --no-pager > "$KIT/results/night-journal-$T.txt" 2>/dev/null
    tail -n 400 /var/log/gpu-blackbox/current.txt > "$KIT/results/night-blackbox-$T.txt" 2>/dev/null
    cp /var/log/gpu-blackbox/hang-*.txt "$KIT/results/" 2>/dev/null
    sync
    if [ "$AUTOREBOOT" = 1 ]; then
        say "перезагрузка через SysRq через 10 с"; sleep 10
        sudo sh -c 'echo s > /proc/sysrq-trigger; sleep 3; echo u > /proc/sysrq-trigger; sleep 2; echo b > /proc/sysrq-trigger'
    fi
    exit 2
}
run() {   # run ИМЯ НИЗ-ВЕРХ [параметр=значение ...]
    local name="$1" lv="$2"; shift 2
    base; [ "$#" -gt 0 ] && setp "$@"
    say "=== тест $name: уровни $lv; отличия от базы: ${*:-нет}"
    local t0 R rc=0 pid kerr; t0="$(date '+%Y-%m-%d %H:%M:%S')"
    LOW="${lv%%-*}" HIGH="${lv##*-}" bash "$HERE/hangtest.sh" 60 & pid=$!
    sleep 20; R="$(ls -t "$KIT/results"/hangtest-*.txt | head -n1)"
    # сторож: тест сам может застрять (карта пропала с шины — тест 18); журнал теста растёт каждые ~12 с
    while kill -0 "$pid" 2>/dev/null; do
        sleep 10
        kerr="$(journalctl -k -b 0 --no-pager --since "$t0" 2>/dev/null | grep -cE 'intr.c:191|vmmgf100.c|g84_bar_flush|failed to idle' || true)"
        if [ "${kerr:-0}" -gt 0 ]; then
            say "тест $name: в журнале ядра подпись зависания ($kerr строк) — жду 100 с, чтобы тест и ящик записали своё"
            local w=0; while kill -0 "$pid" 2>/dev/null && [ $w -lt 100 ]; do sleep 5; w=$((w+5)); done
            tail -n 3 "$R" >> "$LOG"; hung "$name"
        fi
        if [ $(( $(date +%s) - $(stat -c %Y "$R") )) -gt 240 ]; then
            say "тест $name: журнал теста не растёт 4 мин — считаю зависанием"; tail -n 3 "$R" >> "$LOG"; hung "$name"
        fi
    done
    wait "$pid"; rc=$?
    say "тест $name: код $rc, лог $(basename "$R")"; tail -n 3 "$R" >> "$LOG"; sync
    grep -q "ЗАВИСАНИЕ ВОСПРОИЗВЕДЕНО" "$R" && hung "$name"
    grep -q "подъёмов без зависания" "$R" || { say "тест $name не дошёл до конца (код $rc) — серия остановлена"; exit 1; }
}
say "ночная серия: драйвер $(modinfo -n nouveau), ядро $(uname -r), AUTOREBOOT=$AUTOREBOOT"
run 19  03-07                                   # скобка вокруг пост-делителей (тест 18 + одно изменение)
run 19b 07-0f                                   # та же конфигурация на проверенной паре 07↔0f
run 21  03-07 lab_clk_mmu_lock=1                # + блокировка MMU (= значения по умолчанию)
run 20  03-07 lab_therm=0 lab_therm_div=0       # контроль: без скобки вообще, как до 24.10
setp lab_gov=2 lab_therm_div=1 lab_clk_mmu_lock=1
say "=== серия закончена без зависаний; регулятор включён, параметры по умолчанию"
