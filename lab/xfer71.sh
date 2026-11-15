#!/bin/bash
# ТЕСТ 71 (15.11): кто держит передачу данных между компьютером и картой — XBAR2CLK, SYS2CLK, HUB2CLK или сама PCIe.
# Гипотеза автора: кросс-бару хватает низкой частоты, чтобы перекладывать данные с PCIe в видеопамять; поднимать его нужно
# для ядра (GPC ↔ L2), поэтому NVIDIA поднимает его последним. Опыт по доменам 02.11 мерил загрузку только косвенно (glmark2
# buffer), здесь — прямой замер ГБ/с (tools/xfer-bench.py): up — компьютер → видеопамять, down — обратно, copy — видеопамять →
# видеопамять на карте без PCIe. Плюс одна сцена glmark2 (refract), где в 02.11 XBAR2CLK тормозил ядро, — для сверки.
# Уровень 0f с памятью 2004 МГц и частотами узлов вручную, как в lab/domains.sh MEM=1. Эталон — все пять узлов 810, PCIe gen2.
# В варианте меняется ОДНО: один узел до частоты уровня 03 или PCIe gen1. Три круга, эталон в начале каждого круга и в конце.
#   bash ~/Home/nouveau-fix/lab/xfer71.sh [кругов=3]     — в терминале рабочего стола, не по ssh; не во время других тестов
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
ROUNDS="${1:-3}"
[ -e "$PRM/lab_gpc_khz" ] || { echo "Нет lab_gpc_khz — нужен лабораторный модуль"; exit 1; }
pgrep -f "ladder70|seq68|hangtest|domains.sh" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "Нет glmark2"; exit 1; }
BENCH="$HERE/../tools/xfer-bench.py"; [ -f "$BENCH" ] || { echo "Нет $BENCH"; exit 1; }
LNK=/sys/class/drm/card0/device/current_link_speed
OUT=~/Home/nouveau-fix/results/test71-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
NAMES=(gpc rop hub07 hub06 hub01)
#        имя | GPC ROP hub07 hub06 hub01 (МГц) | lab_pcie
VARS=(
  "XBAR2CLK 270|810 810 270 810 810|1"
  "SYS2CLK 270|810 810 810 270 810|1"
  "HUB2CLK 540|810 810 810 810 540|1"
  "LTC2CLK 270|810 270 810 810 810|1"
  "GPC2CLK 270|270 810 810 810 810|1"
  "PCIe gen1|810 810 810 810 810|0"
)
BASEV="эталон|810 810 810 810 810|1"
declare -A ORIG
for k in lab_gov lab_mem lab_pcie lab_volt_first lab_core lab_volt_min_uv; do [ -e $PRM/$k ] && ORIG[$k]="$(cat $PRM/$k)"; done
reset07() {
  for n in "${NAMES[@]}"; do w lab_${n}_khz 0; done
  w lab_eng_mask $((65147 | 4 | 128 | 256)); sudo sh -c "echo 03 > $PS"; sleep 2
  w lab_eng_mask 65147; sudo sh -c "echo 07 > $PS"; sleep 2
}
restore() { reset07; for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — возвращаю 07 и ключи"; restore; exit 1' INT TERM
{ echo "Тест 71 $(date '+%F %T'), $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s), кругов $ROUNDS"
  for f in lab_mem lab_mem_replay lab_pcie lab_core lab_vbios_src lab_mux_guard lab_therm_wait_nv; do echo "  $f = $(cat $PRM/$f 2>/dev/null)"; done; } | tee "$OUT"
# как в lab/domains.sh MEM=1: регулятор выключен, память меняется, напряжение первым
[ -e "$PRM/lab_gov" ] && w lab_gov 0
w lab_mem 1; w lab_volt_first 1; w lab_core 1; w lab_volt_min_uv 0
one() {   # $1 = круг, $2 = "имя|частоты|pcie"
  local name="${2%%|*}" rest="${2#*|}"; local fr="${rest%%|*}" pcie="${rest##*|}"; read -r -a F <<< "$fr"
  say "=== круг $1, $name: GPC ${F[0]}, LTC ${F[1]}, XBAR ${F[2]}, SYS ${F[3]}, HUB ${F[4]} МГц, lab_pcie $pcie"
  for n in "${NAMES[@]}"; do w lab_${n}_khz 0; done
  w lab_eng_mask $((65147 | 4 | 128 | 256)); sudo sh -c "echo 07 > $PS"; sleep 2
  w lab_pcie "$pcie"
  for i in 0 1 2 3 4; do w lab_${NAMES[$i]}_khz $((F[i] * 1000)); done
  sudo sh -c "echo 0f > $PS"; sleep 3
  say "   pstate: $(sudo grep '^AC' "$PS"); PCIe $(cat $LNK)"
  if journalctl -k -b 0 --no-pager --since "-20s" | grep -qE 'LAB mux|FAULT|Xid|DATA_ERROR|LAB replay.*ret -'; then say "   !!! ошибка в журнале — вариант пропущен"; return; fi
  local N0; N0=$(journalctl -k -b 0 --no-pager | grep -cE 'LAB pstate [0-9]: flags')
  python3 -I "$BENCH" 64 1.5 3 2>&1 | grep -E '^XFER' | sed 's/^/   /' | tee -a "$OUT"
  "$G" --off-screen -s 1600x900 -b refract:duration=6 2>&1 | grep -E '^\[' | sed 's/^/   /' | tee -a "$OUT"
  local N1; N1=$(journalctl -k -b 0 --no-pager | grep -cE 'LAB pstate [0-9]: flags')
  [ "$N1" = "$N0" ] || say "   !!! во время замера уровень менялся $((N1 - N0)) раз — вариант недостоверен"
}
say "прогрев (не учитывается)"
python3 -I "$BENCH" 64 0.5 1 >/dev/null 2>&1; "$G" --off-screen -s 1600x900 -b refract:duration=2 >/dev/null 2>&1
for r in $(seq 1 "$ROUNDS"); do
  one "$r" "$BASEV"
  for v in "${VARS[@]}"; do one "$r" "$v"; done
done
one end "$BASEV"
restore
say "=== возвращено: $(sudo grep '^AC' "$PS"); PCIe $(cat $LNK)"
echo; echo "СВОДКА: доля от среднего двух соседних эталонов (до и после круга), по кругам; в конце — медиана" | tee -a "$OUT"
python3 -I - "$OUT" <<'PY' | tee "$OUT.sum" | tee -a "$OUT"
import re, sys, statistics as st
recs, cur = [], None
for l in open(sys.argv[1], encoding='utf-8'):
    m = re.search(r'=== круг (\S+), (.+?): GPC', l)
    if m: cur = {'name': m.group(2), 'v': {}}; recs.append(cur); continue
    if cur is None: continue
    if '!!!' in l: cur['bad'] = True
    m = re.search(r'XFER (up|down|copy): ([\d.]+)', l)
    if m: cur['v'][m.group(1)] = float(m.group(2))
    m = re.search(r'\[refract\].*FPS: (\d+)', l)
    if m: cur['v']['refract'] = float(m.group(1))
keys = ['up', 'down', 'copy', 'refract']
base_idx = [i for i, r in enumerate(recs) if r['name'] == 'эталон' and not r.get('bad')]
print('эталоны (ГБ/с; refract — кадры/с):')
for i in base_idx: print('   ' + '  '.join(f"{k} {recs[i]['v'].get(k, 0):.3g}" for k in keys))
res = {}
for i, r in enumerate(recs):
    if r['name'] == 'эталон' or r.get('bad'): continue
    b = [j for j in base_idx if j < i][-1:] + [j for j in base_idx if j > i][:1]
    for k in keys:
        bv = [recs[j]['v'][k] for j in b if k in recs[j]['v']]
        if k in r['v'] and bv: res.setdefault(r['name'], {}).setdefault(k, []).append(r['v'][k] / st.mean(bv))
print('вариант'.ljust(16) + ''.join(k.rjust(24) for k in keys))
for n, d in res.items():
    print(n.ljust(16) + ''.join((' '.join(f'{x:.2f}' for x in d.get(k, [])) + f' | {st.median(d[k]):.2f}' if d.get(k) else '-').rjust(24) for k in keys))
PY
echo "Результат: $OUT"
