#!/bin/bash
# ТЕСТ 70 (15.11, ночь): лестница порогов ожидания GPC при трёх глубинах замедления, одна загрузка.
# Вопрос автора: бывает ли сессия «хорошей» или порог есть всегда и зависит от глубины замедления. Пакет — полный набор ядра
# как у NVIDIA (тест 68), память не трогается. Меняется ОДНО: ожидание GPC в скобке, фиксированное от входа
# (lab_therm_fixed_ns), и глубина замедления GPC (lab_therm_gpc_factor: 2 = /2, 0xa = /6 как у NVIDIA на GF114, 0xe = /8).
# Ожидание хаба держится на NVIDIA-значении 4000 нс. Порядок: для каждой ступени ожидания сверху вниз — все три глубины подряд,
# чтобы глубины сравнивались в одно время. На каждую клетку N подъёмов 07 -> 0f -> 07 под нагрузкой браузера.
# Застревание переключателя (защита на месте) — данные, тест идёт дальше; зависание графики — тест останавливается.
#   bash ~/Home/nouveau-fix/lab/ladder70.sh [N=150] [начать со ступени, нс]     — в терминале рабочего стола, не по ssh
# 16.11: второй аргумент — продолжить лестницу с этой ступени ожидания (например 2500), более длинные пропускаются.
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-150}"; FROMW="${2:-}"
for k in lab_therm_fixed_ns lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor lab_therm_wait_nv; do
  [ -e $PRM/$k ] || { echo "Нет $k — нужен модуль от 13.11"; exit 1; }
done
WAITS=(8000 5000 3500 2500 2000 1500)
DEPTHS=("0xa|/6" "0x2|/2" "0xe|/8")
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_therm_fixed_ns lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor"
OUT=~/Home/nouveau-fix/results/test70-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
declare -A ORIG
for kv in $BASE; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in $STEP; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
say "тест 70: N=$N на клетку${FROMW:+, со ступени $FROMW нс}, ${#WAITS[@]} ступеней × ${#DEPTHS[@]} глубины; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000
STOP=0
for W in "${WAITS[@]}"; do
  [ -n "$FROMW" ] && [ "$W" -gt "$FROMW" ] && continue
  for d in "${DEPTHS[@]}"; do
    code="${d%%|*}"; name="${d#*|}"
    w lab_therm_gpc_factor "$code"; w lab_therm_fixed_ns "$W"
    say "=== клетка: GPC $name, ожидание $W нс (hub /2, 4000 нс)"
    M0=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
    T0=$(date "+%F %T")
    bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
    M1=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E1=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
    FL=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB therm fixed idx 00" | sed -E 's/.*признак через ([0-9]+) нс.*/\1/;t;d' | sort -n | awk '{a[NR]=$1} END{if(NR) printf "%d/%d/%d", a[1], a[int((NR+1)/2)], a[NR]; else printf "-"}')
    NF=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB therm fixed idx 00" | grep -c "НЕ поднялся")
    say "=== итог клетки GPC $name $W нс: код $RC, застреваний $((M1 - M0)), ошибок GPU $((E1 - E0)), признак мин/медиана/макс $FL нс, не поднялся до переключения $NF"
    [ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; STOP=1; break; }
  done
  [ "$STOP" = 1 ] && break
done
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "итог клетки|зависание" "$OUT" | tee "$OUT.sum"
echo "Результат: $OUT"
