#!/bin/bash
# ОПЫТ ПО ДОМЕНАМ (02.11): что тактирует каждый узел ядра. Уровень 0f с частотами узлов, заданными вручную (lab_*_khz),
# память и PCIe не трогаются (память остаётся на 324 МГц уровня 07). Эталон — все пять узлов 810 МГц (как уровень 07);
# в каждом варианте понижается ОДИН узел до частоты, которую NVIDIA сама ставит этому узлу на уровне 03
# (ROP/hubk07/hubk06 — 270, hubk01 — 540; GPC — 270). Под каждым вариантом — одни и те же сцены glmark2 вне экрана;
# по падению кадров видно, какую работу тактирует узел. Имена NVIDIA (атлас 01.11): GPC = GPC2CLK, ROP = LTC2CLK,
# hubk07 = XBAR2CLK, hubk06 = SYS2CLK, hubk01 = HUB2CLK.
#   bash ~/Home/nouveau-fix/lab/domains.sh            (в сеансе рабочего стола; sudo спросит пароль один раз)
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_gpc_khz" ] || { echo "Нет lab_gpc_khz — нужен лабораторный модуль"; exit 1; }
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "Нет glmark2"; exit 1; }
# MEM=1 (02.11): память на уровне 0f идёт на 2004 МГц (смена памяти повтором скриптов NVIDIA, lab_mem_replay); между
# вариантами — уровень 07 (память 324) вместо 03. Без MEM — память не трогается, как раньше.
MEM="${MEM:-0}"; BASE=03; [ "$MEM" = 1 ] && BASE=07
OUT=~/Home/nouveau-fix/results/domains$([ "$MEM" = 1 ] && echo -mem)-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
NAMES=(gpc rop hub07 hub06 hub01)
CONFIGS=(
  "эталон|810 810 810 810 810"
  "GPC 270|270 810 810 810 810"
  "ROP (LTC2CLK) 270|810 270 810 810 810"
  "hubk07 (XBAR2CLK) 270|810 810 270 810 810"
  "hubk06 (SYS2CLK) 270|810 810 810 270 810"
  "hubk01 (HUB2CLK) 540|810 810 810 810 540"
  "эталон повтор|810 810 810 810 810"
)
SCENES=(
  -b texture:duration=6
  -b shading:shading=phong:duration=6
  -b loop:fragment-steps=20:duration=6
  -b effect2d:kernel=0,1,0\;1,-4,1\;0,1,0\;:duration=6
  -b clear:duration=6
  -b desktop:duration=6
  -b refract:duration=6
  -b buffer:update-method=map:interleave=false:duration=6
  -b buffer:update-method=subdata:interleave=false:duration=6
)
w() { sudo sh -c "echo $2 > $PRM/$1"; }
reset07() {   # вернуть 07 по таблице: свои частоты сбросить, hub перестроить через 03
  for n in "${NAMES[@]}"; do w lab_${n}_khz 0; done
  w lab_eng_mask $((65147 | 4 | 128 | 256)); sudo sh -c "echo 03 > $PS"; sleep 2
  w lab_eng_mask 65147; sudo sh -c "echo 07 > $PS"; sleep 2
}
GOV="$(cat $PRM/lab_gov 2>/dev/null || echo 0)"
restore() { reset07; [ -e "$PRM/lab_gov" ] && w lab_gov "$GOV"; }
trap 'say "прервано — возвращаю 07"; restore; exit 1' INT TERM
# 02.11, после первого прогона: встроенный регулятор уровней (lab_gov) сам менял уровень посреди опыта — на время опыта он выключен
{ echo "Опыт по доменам $(date '+%F %T'), $(uname -r), модуль $(cat /sys/module/nouveau/srcversion)"
  echo "  MEM=$MEM (база между вариантами — $BASE)"
  for f in lab_mem lab_mem_replay lab_mem_order lab_pcie lab_core lab_vbios_src lab_mux_guard lab_gpc_seq lab_therm lab_therm_wait_us; do echo "  $f = $(cat $PRM/$f)"; done; } | tee "$OUT"
# Как в lab.sh at: только ядро, напряжение первым, память и PCIe не трогаем.
[ -e "$PRM/lab_gov" ] && w lab_gov 0
w lab_mem "$MEM"; w lab_pcie 0; w lab_volt_first 1; w lab_core 1; w lab_volt_min_uv 0
say "прогрев glmark2 (не учитывается; в первом прогоне первый запуск был на 20–30 % медленнее остальных)"
"$G" --off-screen -s 1600x900 "${SCENES[@]//duration=6/duration=2}" >/dev/null 2>&1
declare -A FPS
for c in "${CONFIGS[@]}"; do
  name="${c%%|*}"; read -r -a F <<< "${c#*|}"
  say "=== $name: GPC ${F[0]}, ROP ${F[1]}, hubk07 ${F[2]}, hubk06 ${F[3]}, hubk01 ${F[4]} МГц"
  for n in "${NAMES[@]}"; do w lab_${n}_khz 0; done
  w lab_eng_mask $((65147 | 4 | 128 | 256)); sudo sh -c "echo $BASE > $PS"; sleep 2
  for i in 0 1 2 3 4; do w lab_${NAMES[$i]}_khz $((F[i] * 1000)); done
  sudo sh -c "echo 0f > $PS"; sleep 3
  say "   pstate: $(sudo grep '^AC' "$PS")"
  journalctl -k -b 0 --no-pager | grep -E 'LAB calc idx 0[01278] ' | tail -n 5 | sed -E 's/.*(LAB calc idx [0-9a-f]+).*got ([0-9]+).*/   \1 got \2/' | tee -a "$OUT"
  if journalctl -k -b 0 --no-pager --since "-20s" | grep -qE 'LAB mux|FAULT|Xid|DATA_ERROR|LAB replay.*ret -'; then say "   !!! ошибка в журнале — вариант пропущен"; continue; fi
  N0=$(journalctl -k -b 0 --no-pager | grep -cE 'LAB pstate [0-9]: flags')
  "$G" --off-screen -s 1600x900 "${SCENES[@]}" 2>&1 | tee -a "$OUT" | grep -E '^\[' | while read -r l; do echo "   $l"; done
  N1=$(journalctl -k -b 0 --no-pager | grep -cE 'LAB pstate [0-9]: flags')
  [ "$N1" = "$N0" ] && say "   уровень во время замера не менялся" || say "   !!! во время замера уровень менялся $((N1 - N0)) раз — вариант недостоверен"
done
restore
say "=== возвращено: $(sudo grep '^AC' "$PS")"
echo; echo "СВОДКА (кадры/с; в скобках — доля от эталона)" | tee -a "$OUT"
python3 - "$OUT" <<'PY' | tee -a "$OUT"
import re, sys
cur, data, order = None, {}, []
for l in open(sys.argv[1], encoding='utf-8'):
    m = re.search(r'=== (.+?): GPC', l)
    if m: cur = m.group(1); data[cur] = {}; continue
    m = re.match(r'\s*\[(\w+)\] (.*?): FPS: (\d+)', l)
    if m and cur:
        k = (m.group(1) + (' ' + re.search(r'update-method=(\w+)', m.group(2)).group(1) if 'update-method' in m.group(2) else '')); data[cur][k] = int(m.group(3))
        if k not in order: order.append(k)
base = data.get('эталон', {})
names = list(data)
print('сцена'.ljust(48) + ''.join(n[:14].rjust(16) for n in names))
for k in order:
    row = k.ljust(48)
    for n in names:
        v = data[n].get(k)
        row += (f'{v} ({v / base[k]:.2f})' if v and base.get(k) else '-').rjust(16)
    print(row)
PY
echo "Результат: $OUT"
