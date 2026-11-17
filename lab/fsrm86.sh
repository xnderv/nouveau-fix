#!/bin/bash
# ТЕСТ 86 (17.11), модуль build-1117c. Замедление GPC в простое при ОДНОМ условии: у условия B своя глубина (поле B)? бит 7?
# Тест 85: при обоих условиях простоя глубину задаёт поле A 0x020160 (вытесняет команду 0x020180), поле B и бит 7 не влияют,
# условия по «или». Здесь включено одно условие. Опора I: только условие B (0x0201a0 = 0x40 — условие A «никогда»);
# опора II: только условие A (0x0201a0 = 0x4000). A = B = 0x020180 = /6, бит 7. Каждый прогон отличается от своей опоры ОДНИМ.
#   I:  1 опора; 2 только A = /2; 3 только B = /8; 4 только бит 7 = 0
#   II: 5 опора; 6 только A = /2; 7 только B = /8; 8 только бит 7 = 0
#   bash ~/Home/nouveau-fix/lab/fsrm86.sh     — в терминале рабочего стола; около полутора минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters
for k in lab_pmu_slow lab_pmu_slow_val lab_pmu_slow_rel lab_pmu_slow_f3 lab_pmu_slow_f4; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117c"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr|big83|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test86-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
declare -A ORIG
for k in lab_gov lab_therm_gpc_factor lab_pmu_slow lab_pmu_slow_val lab_pmu_slow_rel lab_pmu_slow_f3 lab_pmu_slow_f4; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 86: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; w lab_therm_gpc_factor 0xa; sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"
w lab_pmu_slow_rel 2
# val | f3 | f4 | подпись   (0x000a008a = A /6, бит 7, B /6; коды: 0x2 = /2, 0xa = /6, 0xe = /8)
for v in "0x000a008a|10|0x40|1 только условие B: опора" \
         "0x0002008a|10|0x40|2 только условие B: только A = /2" \
         "0x000a008e|10|0x40|3 только условие B: только B = /8" \
         "0x000a000a|10|0x40|4 только условие B: только бит 7 = 0" \
         "0x000a008a|10|0x4000|5 только условие A: опора" \
         "0x0002008a|10|0x4000|6 только условие A: только A = /2" \
         "0x000a008e|10|0x4000|7 только условие A: только B = /8" \
         "0x000a000a|10|0x4000|8 только условие A: только бит 7 = 0"; do
  IFS='|' read -r val f3 f4 name <<< "$v"
  w lab_pmu_slow_val "$val"; w lab_pmu_slow_f3 "$f3"; w lab_pmu_slow_f4 "$f4"
  sudo sh -c "echo 03 > $PS"; sleep 2
  T0=$(date "+%F %T"); w lab_pmu_slow 3; sudo sh -c "echo 07 > $PS"; sleep 2; w lab_pmu_slow 0
  R=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB PMU-устоявшееся" | sed -E 's/.*в ([0-9.]+) раза; признак [^ ]+ = ([0-9a-f]+) \(делитель ([0-9]+), действует ([0-9])\).*/\1 (признак \2: код \3, по команде \4)/' | tr '\n' ';')
  say "    $name: такт замедлен в $R"
done
restore
say "=== конец; ключи возвращены"
grep -E "замедлен в|подготовка|тест 86" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"
