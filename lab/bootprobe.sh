#!/bin/bash
# ПРОБА ЗАГРУЗКИ, этап А (16.11): «уровень плохости» этой загрузки. Модуль build-1116d (ключ lab_pmu_slow) или новее.
#  1) время реального включения замедления GPC /6 по счётчику, сценарием PMU (без процессора и PCIe): 5 смен уровня × 5;
#  2) короткая лестница: ожидание GPC 2000 и 1500 нс от входа (/6, хаб 4000), быстрый hangtest по N подъёмов — есть ли
#     застревания переключателя выше ~1,5 мкс (нижний предел скобки с процессора).
# Пакет ядра — как в тесте 70 (полный набор NVIDIA), память не трогается. Всё возвращается в конце.
#   bash ~/Home/nouveau-fix/lab/bootprobe.sh [N=100]     — в терминале рабочего стола, не по ssh; ~10 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-100}"
[ -e "$PRM/lab_pmu_slow" ] || { echo "Нет lab_pmu_slow — нужен модуль build-1116d"; exit 1; }
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/bootprobe-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_therm_fixed_ns lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor lab_pmu_slow lab_gov"
declare -A ORIG
for kv in $BASE; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in $STEP; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
say "проба загрузки: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s), N=$N"
journalctl -k -b 0 --no-pager | grep "LAB boot snap #1" | sed -E 's/.*(LAB boot snap)/   \1/' >> "$OUT"

say "=== 1. включение замедления GPC /6 по счётчику, сценарии PMU"
w lab_gov 0; w lab_therm_gpc_factor 0xa
T0=$(date "+%F %T")
w lab_pmu_slow 5
for l in 0f 07 03 0f 07; do sudo sh -c "echo $l > $PS"; sleep 2; done
w lab_pmu_slow 0
journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB PMU-замедление" | sed -E 's/.*(LAB )/   \1/' >> "$OUT"
grep "LAB PMU-замедление" "$OUT" | python3 -I -c '
import sys, re, statistics as s
g = {}
for l in sys.stdin:
    m = re.search(r"GPC (\d+) кГц.*через ≈ (\d+) нс", l)
    if m: g.setdefault(int(m.group(1)) // 1000, []).append(int(m.group(2)))
for k in sorted(g, reverse=True):
    v = g[k]; print("   GPCCLK %4d МГц: n %2d, медиана %d нс, разброс %d–%d" % (k, len(v), s.median(v), min(v), max(v)))' | tee -a "$OUT"

say "=== 2. лестница: GPC /6, ожидание от входа 2000 и 1500 нс, быстрый hangtest по $N подъёмов"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000
for W in 2000 1500; do
  w lab_therm_fixed_ns "$W"
  M0=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  T0=$(date "+%F %T")
  FAST=1 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  M1=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E1=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  NB=$(journalctl -k -b 0 --no-pager --since "$T0" | grep -c "LAB therm fixed idx 00")
  NF=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB therm fixed idx 00" | grep -c "НЕ поднялся")
  say "=== итог ступени $W нс: код $RC, застреваний $((M1 - M0)), ошибок GPU $((E1 - E0)), скобок GPC $NB, переключение раньше признака $NF"
  [ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; break; }
done
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "GPCCLK .* МГц: n|итог ступени|зависание" "$OUT" | tee "$OUT.sum"
echo "Результат: $OUT"
