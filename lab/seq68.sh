#!/bin/bash
# ТЕСТ 68 (14.11): шаги последовательности ядра «как у NVIDIA» по одному, нарастающим итогом. Пакет «только ядро на
# генераторе» (lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1) + коды замедления по чипам + ожидание по модели
# в целых микросекундах (lab_therm_wait_nv=2). Каждый шаг добавляет ОДИН ключ к предыдущим и гоняет hangtest N подъёмов
# 07 -> 0f -> 07 под нагрузкой браузера. Шаг с тайм-аутом переключателя или ошибкой GPU отмечается, его ключ снимается,
# следующие идут без него. Память не трогается, поэтому «hubk07 рядом с памятью» и «PCIe в конце спуска» здесь не проверяются.
#   bash ~/Home/nouveau-fix/lab/seq68.sh [N=150] [с какого шага начать=0]   — в терминале рабочего стола, не по ssh
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-150}"; FROM="${2:-0}"
[ -e $PRM/lab_therm_wait_nv ] || { echo "Нет lab_therm_wait_nv — нужен модуль от 13.11"; exit 1; }
modinfo -p "/lib/modules/$(uname -r)/updates/nouveau-fix/nouveau.ko" 2>/dev/null | grep -q "whole-microsecond" || { echo "Установлен модуль без модели 13.11 (lab_therm_wait_nv=2)"; exit 1; }
STEPS=(
  "0|база: коды по чипам + ожидание 8/4 мкс по модели|"
  "1|порядок узлов как у NVIDIA (хабы первыми вверх, последними вниз)|lab_order=1"
  "2|ядро через 405 МГц перед PLL|lab_gpc_pre405=1"
  "3|пост-делитель хабов до переключателя|lab_nv_hubpost=1"
  "4|PLL не перезахватывать и не выключать|lab_pll_keep=1"
  "5|переходное состояние кросс-бара вокруг смены|lab_xbar=1"
  "6|пауза 195 мкс после смены напряжения|lab_volt_wait_us=195"
  "7|делитель 0x00e9e0 по уровню|lab_e9e0=1"
)
OUT=~/Home/nouveau-fix/results/test68-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
trap 'kill $KEEP 2>/dev/null' EXIT
say "тест 68: N=$N, с шага $FROM; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
# сохранить исходные значения ключей шагов, в конце вернуть
declare -A ORIG
for s in "${STEPS[@]}"; do kv="${s##*|}"; [ -n "$kv" ] && ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in lab_therm_code_nv lab_therm_wait_nv lab_mem lab_vbios_src lab_nv_div_late lab_mux_guard; do ORIG[$k]="$(cat $PRM/$k)"; done
w lab_mem 0; w lab_vbios_src 1; w lab_nv_div_late 1; w lab_mux_guard 1; w lab_therm_code_nv 1; w lab_therm_wait_nv 2
for s in "${STEPS[@]}"; do kv="${s##*|}"; [ -n "$kv" ] && w "${kv%%=*}" 0; done
KEPT=""
for s in "${STEPS[@]}"; do
  i="${s%%|*}"; rest="${s#*|}"; name="${rest%%|*}"; kv="${s##*|}"
  if [ -n "$kv" ] && [ "$i" -lt "$FROM" ]; then w "${kv%%=*}" "${kv#*=}"; KEPT="$KEPT $kv"; continue; fi
  [ "$i" -lt "$FROM" ] && continue
  [ -n "$kv" ] && w "${kv%%=*}" "${kv#*=}"
  say "=== шаг $i: $name${kv:+ ($kv)}; уже включено:${KEPT:- ничего}"
  M0=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed")
  bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  M1=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E1=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed")
  say "=== шаг $i итог: код $RC, тайм-аутов $((M1 - M0)), ошибок GPU $((E1 - E0)) на $N подъёмов"
  if [ "$RC" != 0 ] || [ "$M1" != "$M0" ] || [ "$E1" != "$E0" ]; then
    say "!!! шаг $i не чистый${kv:+ — ключ ${kv%%=*} снят, дальше без него}"
    [ -n "$kv" ] && w "${kv%%=*}" 0
    [ "$RC" = 2 ] && { say "зависание GR — останавливаюсь"; break; }
  else
    [ -n "$kv" ] && KEPT="$KEPT $kv"
  fi
done
for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done
say "=== конец; чистые шаги оставляли включёнными:${KEPT:- ничего}; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== шаг [0-9]+ итог|!!!" "$OUT" | tee -a "$OUT.sum"
echo "Результат: $OUT"
