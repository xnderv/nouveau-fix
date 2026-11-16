#!/bin/bash
# ТЕСТ 74 (16.11): от какого такта зависит задержка включения замедления GPC. Модуль build-1116d (ключ lab_pmu_slow).
# Уровень 0f с частотами узлов, заданными вручную (lab_*_khz), как в lab/domains.sh; память и PCIe не трогаются.
# В каждом варианте меняется ОДИН узел; после выхода на 0f драйвер 5 раз запускает в PMU сценарий «счётчик + запрос
# замедления /6 + 8 мкс + снять» (без переключателя) и пишет, когда такт GPC реально снизился. Варианты повторяются дважды.
#   bash ~/Home/nouveau-fix/lab/srcclk74.sh     — в терминале рабочего стола, не по ssh; ~2 минуты
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_pmu_slow" ] || { echo "Нет lab_pmu_slow — нужен модуль build-1116d"; exit 1; }
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test74-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
NAMES=(gpc rop hub07 hub06 hub01)
CONFIGS=(
  "эталон|810 810 810 810 810"
  "SYS2CLK 270|810 810 810 270 810"
  "HUB2CLK 540|810 810 810 810 540"
  "GPC2CLK 270|270 810 810 810 810"
  "XBAR2CLK 270|810 810 270 810 810"
  "эталон|810 810 810 810 810"
  "SYS2CLK 270|810 810 810 270 810"
  "HUB2CLK 540|810 810 810 810 540"
  "GPC2CLK 270|270 810 810 810 810"
  "XBAR2CLK 270|810 810 270 810 810"
)
GOV="$(cat $PRM/lab_gov)"; MEMK="$(cat $PRM/lab_mem)"; PCIE="$(cat $PRM/lab_pcie)"
reset07() {
  for n in "${NAMES[@]}"; do w lab_${n}_khz 0; done
  w lab_eng_mask $((65147 | 4 | 128 | 256)); sudo sh -c "echo 03 > $PS"; sleep 2
  w lab_eng_mask 65147; sudo sh -c "echo 07 > $PS"; sleep 2
}
restore() { w lab_pmu_slow 0; reset07; w lab_mem "$MEMK"; w lab_pcie "$PCIE"; w lab_gov "$GOV"; }
trap 'say "прервано — возвращаю"; restore; exit 1' INT TERM
say "тест 74: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; w lab_mem 0; w lab_pcie 0
for c in "${CONFIGS[@]}"; do
  name="${c%%|*}"; read -r -a F <<< "${c#*|}"
  say "=== $name: GPC ${F[0]}, LTC ${F[1]}, XBAR ${F[2]}, SYS ${F[3]}, HUB ${F[4]} МГц"
  w lab_pmu_slow 0
  for n in "${NAMES[@]}"; do w lab_${n}_khz 0; done
  w lab_eng_mask $((65147 | 4 | 128 | 256)); sudo sh -c "echo 07 > $PS"; sleep 2
  for i in 0 1 2 3 4; do w lab_${NAMES[$i]}_khz $((F[i] * 1000)); done
  T0=$(date "+%F %T")
  w lab_pmu_slow 5
  sudo sh -c "echo 0f > $PS"; sleep 2
  w lab_pmu_slow 0
  journalctl -k -b 0 --no-pager --since "$T0" | grep -E "LAB calc idx 0[01278] |LAB PMU-замедление" | sed -E 's/.*(LAB )/   \1/' | tee -a "$OUT"
  journalctl -k -b 0 --no-pager --since "$T0" | grep -qE 'LAB mux|FAULT|Xid|DATA_ERROR' && say "   !!! ошибка в журнале"
done
restore
say "=== возвращено: $(sudo grep '^AC' "$PS")"
echo; echo "СВОДКА (такт снижен через, нс; медиана по 5 сценариям)" | tee -a "$OUT"
python3 -I - "$OUT" <<'PY' | tee "$OUT.sum" | tee -a "$OUT"
import re, sys, statistics as st
cur, res = None, {}
for l in open(sys.argv[1], encoding='utf-8'):
    m = re.search(r'=== (.+?): GPC', l)
    if m: cur = m.group(1); res.setdefault(cur, []); continue
    m = re.search(r'LAB PMU-замедление .*GPC (\d+) кГц.*через ≈ (\d+) нс', l)
    if m and cur: res[cur].append((int(m.group(2)), int(m.group(1))))
for k, v in res.items():
    if v: print(f'{k:16} GPCCLK {v[0][1]//1000:4} МГц  медиана {st.median(x[0] for x in v):6.0f}  все: {[x[0] for x in v]}')
PY
echo "Результат: $OUT"
