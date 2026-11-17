#!/bin/bash
# ТЕСТ 84 (17.11), модуль build-1117c (ключи lab_pmu_slow_f3, lab_pmu_slow_f4). Какой регистр задаёт глубину замедления GPC.
# Часть 0б теста 83: поле A регистра 0x020160 не действует, бит 7 поле не выбирает, глубина = поле B — но 0x020180 там всегда
# равнялся B. Здесь опора — значения NVIDIA (A = B = 0x020180 = /6, бит 7 = 1, 0x0201a0 = 0x4040), каждый прогон отличается
# от опоры ОДНИМ, отличие помечено своей глубиной. Устоявшееся замедление (PMU, без переключателя, GPC на 07), счётчик тактов
# + признак 0x0201e0 (процессор, через 20 мкс после тех же записей). Безопасно: частоты узлов не меняются.
#   1 опора; 2 только 0x020180 = /2; 3 только B = /8; 4 только 0x020180 = 0; 5 только 0x0201a0 = 0
#   bash ~/Home/nouveau-fix/lab/fsrm84.sh     — в терминале рабочего стола; около минуты
set -uo pipefail
PRM=/sys/module/nouveau/parameters
for k in lab_pmu_slow lab_pmu_slow_val lab_pmu_slow_rel lab_pmu_slow_f3 lab_pmu_slow_f4; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117c"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr|big83|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test84-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
declare -A ORIG
for k in lab_gov lab_therm_gpc_factor lab_pmu_slow lab_pmu_slow_val lab_pmu_slow_rel lab_pmu_slow_f3 lab_pmu_slow_f4; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 84: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; w lab_therm_gpc_factor 0xa; sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"
w lab_pmu_slow_rel 2
# val | f3 | f4 | подпись   (0x000a008a = A /6, бит 7, B /6; коды: 0x2 = /2, 0xa = /6, 0xe = /8)
for v in "0x000a008a|-1|-1|1 опора (как NVIDIA): всё /6" \
         "0x000a008a|2|-1|2 только регистр 2 (0x020180) = /2" \
         "0x000a008e|10|-1|3 только поле B = /8" \
         "0x000a008a|0|-1|4 только регистр 2 = 0" \
         "0x000a008a|-1|0|5 только регистр 3 (0x0201a0) = 0"; do
  IFS='|' read -r val f3 f4 name <<< "$v"
  w lab_pmu_slow_val "$val"; w lab_pmu_slow_f3 "$f3"; w lab_pmu_slow_f4 "$f4"
  sudo sh -c "echo 03 > $PS"; sleep 2
  T0=$(date "+%F %T"); w lab_pmu_slow 3; sudo sh -c "echo 07 > $PS"; sleep 2; w lab_pmu_slow 0
  R=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB PMU-устоявшееся" | sed -E 's/.*в ([0-9.]+) раза; признак [^ ]+ = ([0-9a-f]+) \(делитель ([0-9]+), действует ([0-9])\).*/\1 (признак: код \3, действует \4)/' | tr '\n' ';')
  say "    $name: такт замедлен в $R"
done
restore
say "=== конец; ключи возвращены"
grep -E "замедлен в|подготовка|тест 84" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"
