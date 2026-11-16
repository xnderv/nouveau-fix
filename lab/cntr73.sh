#!/bin/bash
# ТЕСТ 73 (16.11; замена теста 72 — одно окно 7 мкс вместо 2 и 5): когда замедление в скобке GPC реально снижает такт — по счётчику тактов GPC (0x134124/0x134128,
# docs/2026-11-16/gpc-counter.md), и как это соотносится с признаком регистра 0x0201e0. Нужен модуль build-1116c (ключ lab_cntr_win).
# Пакет — полный набор ядра как у NVIDIA (тест 68), память не трогается, ожидание GPC фиксированное 8000 нс от входа (как NVIDIA),
# хаб 4000. Меняется ОДНО на клетку: глубина замедления GPC (/6 как у NVIDIA, /2, /8) при одном окне счётчика 7 мкс.
# На каждую клетку N подъёмов 07 -> 0f -> 07 под нагрузкой браузера; на каждую скобку GPC в журнале строка «LAB счётчик в скобке».
#   bash ~/Home/nouveau-fix/lab/cntr73.sh [N=50]     — в терминале рабочего стола, не по ssh
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-50}"
for k in lab_cntr_win lab_therm_fixed_ns lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor; do
  [ -e $PRM/$k ] || { echo "Нет $k — нужен модуль build-1116c"; exit 1; }
done
pgrep -f "ladder70|seq68|xfer71|cntr72|domains.sh" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
WINS=(189)   # 189+4 тактов кварца = 7,15 мкс: кончается до переключателя на 8 мкс, накрывает признак 2–4 мкс
DEPTHS=("0xa|/6" "0x2|/2" "0xe|/8")
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_therm_fixed_ns lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor lab_cntr_win"
OUT=~/Home/nouveau-fix/results/test73-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
declare -A ORIG
for kv in $BASE; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in $STEP; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
say "тест 73: N=$N на клетку, окна ${WINS[*]} тактов кварца × ${#DEPTHS[@]} глубины; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000; w lab_therm_fixed_ns 8000
STOP=0
for WN in "${WINS[@]}"; do
  for d in "${DEPTHS[@]}"; do
    code="${d%%|*}"; name="${d#*|}"
    w lab_therm_gpc_factor "$code"; w lab_cntr_win "$WN"
    say "=== клетка: GPC $name, окно $WN тактов кварца, ожидание 8000 нс"
    M0=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
    T0=$(date "+%F %T")
    bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
    M1=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E1=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
    ST=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB счётчик в скобке GPC" | python3 -I -c '
import sys, re, statistics as s
te, fl, notsl, now, n = [], [], 0, 0, 0
for l in sys.stdin:
    n += 1
    m = re.search(r"через ≈ (\d+) нс", l); te.append(int(m.group(1))) if m else None
    notsl += "НЕ снижен" in l; now += "снижен сразу" in l
    m = re.search(r"признак через (\d+) нс", l); fl.append(int(m.group(1))) if m else None
q = lambda v: "%d/%d/%d" % (min(v), s.median(v), max(v)) if v else "-"
print("скобок %d, такт снижен через мин/медиана/макс %s нс (не снижен в окне %d, сразу %d), признак %s нс" % (n, q(te), notsl, now, q(fl)))')
    say "=== итог клетки GPC $name окно $WN: код $RC, застреваний $((M1 - M0)), ошибок GPU $((E1 - E0)); $ST"
    [ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; STOP=1; break; }
  done
  [ "$STOP" = 1 ] && break
done
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "итог клетки|зависание" "$OUT" | tee "$OUT.sum"
echo "Результат: $OUT"
