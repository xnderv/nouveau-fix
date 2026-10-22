#!/bin/bash
# ОПЫТ «ТЕМПЕРАТУРНЫЙ ТОРМОЗ» регулятора (патч 0004, 22.10). Одна переменная: пороги lab_gov_hot / lab_gov_crit.
# Карту не греем: пороги на время опыта ставятся НИЖЕ текущей температуры, и регулятор должен повести себя так,
# будто горячо: 1) под нагрузкой на 0f — уйти в 07 и не возвращаться в 0f; 2) при «очень горячо» — уйти в 03;
# 3) после снятия порогов — снова подняться в 0f. Боевые пороги потом ставит служба (90 / 95 °C).
#   thermtest.sh        — провести опыт (~2 мин, нагрузка glmark2)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
[ -e "$P/lab_gov_hot" ] || { echo "--- СТОП: в драйвере нет lab_gov_hot — нужен lab.sh install и перезагрузка"; exit 1; }
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "--- СТОП: нет glmark2"; exit 1; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
H="$(for h in /sys/class/hwmon/hwmon*; do grep -q nouveau "$h/name" 2>/dev/null && echo "$h"; done | head -n1)"
t() { echo $(( $(cat "$H/temp1_input") / 1000 )); }
ac() { sudo grep '^AC' "$PS" | sed 's/AC: //'; }
LOG="$KIT/results/therm-$(date +%Y%m%d-%H%M%S).txt"
HOT0="$(cat $P/lab_gov_hot)"; CRIT0="$(cat $P/lab_gov_crit)"
[ "$(cat $P/lab_gov)" = 2 ] || { echo "--- СТОП: регулятор не включён (lab_gov=$(cat $P/lab_gov)); запусти службу"; exit 1; }
echo "Опыт тормоза $(date '+%F %T'); сейчас $(t) °C, $(ac); пороги были hot=$HOT0 crit=$CRIT0" | tee "$LOG"
sudo sh -c "echo 0 > $P/lab_gov_hot; echo 0 > $P/lab_gov_crit"
"$G" --run-forever -s 1600x900 -b refract >/dev/null 2>&1 & GP=$!
echo "  нагрузка, жду 0f (до 20 с)..." | tee -a "$LOG"
for i in $(seq 1 20); do sleep 1; ac | grep -q 'core 900' && break; done
echo "  $(date +%T) $(t) °C: $(ac)" | tee -a "$LOG"
T="$(t)"; HOT=$((T - 5)); CRIT=$((T + 20))
echo "=== 1) «горячо»: hot=$HOT (на 5 ниже текущих $T °C), crit=$CRIT. Ожидание: уход 0f -> 07 за ~6 с и никакого 0f" | tee -a "$LOG"
sudo sh -c "echo $CRIT > $P/lab_gov_crit; echo $HOT > $P/lab_gov_hot"
for i in $(seq 1 25); do sleep 1; [ $((i % 5)) = 0 ] && echo "  $(date +%T) $(t) °C: $(ac) | датчик регулятора: $(cat $P/lab_gov_temp) °C" | tee -a "$LOG"; done
R1="$(ac)"
echo "=== 2) «очень горячо»: crit=$HOT. Ожидание: уход в 03 за ~6 с" | tee -a "$LOG"
sudo sh -c "echo $HOT > $P/lab_gov_crit"
for i in $(seq 1 15); do sleep 1; [ $((i % 5)) = 0 ] && echo "  $(date +%T) $(t) °C: $(ac)" | tee -a "$LOG"; done
R2="$(ac)"
echo "=== 3) пороги сняты. Ожидание: возврат в 0f под нагрузкой за ~10 с" | tee -a "$LOG"
sudo sh -c "echo 0 > $P/lab_gov_hot; echo 0 > $P/lab_gov_crit"
for i in $(seq 1 20); do sleep 1; [ $((i % 5)) = 0 ] && echo "  $(date +%T) $(t) °C: $(ac)" | tee -a "$LOG"; done
R3="$(ac)"
kill $GP 2>/dev/null; wait $GP 2>/dev/null
sudo sh -c "echo $HOT0 > $P/lab_gov_hot; echo $CRIT0 > $P/lab_gov_crit"
echo "--- строки регулятора:" | tee -a "$LOG"
journalctl -k -b 0 --no-pager --since "-3min" | grep -E "LAB gov" | sed -E 's/.*nouveau [^ ]+ pmu: //' | tee -a "$LOG"
ok=1
grep -q 'core 405' <<<"$R1" || ok=0; grep -q 'memory 135' <<<"$R2" || ok=0; grep -q 'core 900' <<<"$R3" || ok=0
echo "1) $R1 | 2) $R2 | 3) $R3" | tee -a "$LOG"
[ $ok = 1 ] && echo "=== Тормоз работает ✅ (пороги возвращены: hot=$HOT0 crit=$CRIT0). Лог: $LOG" | tee -a "$LOG" || echo "=== Есть отличия от ожидания — пришли вывод. Лог: $LOG" | tee -a "$LOG"
