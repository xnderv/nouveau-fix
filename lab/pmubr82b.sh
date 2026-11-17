#!/bin/bash
# ТЕСТ 82б (17.11): продолжение теста 82, прерванного на 4000 ради теста 85 (8000, 6000, 5000 — чисто, загрузка 11:09). Сначала снова 8000 как опора этой загрузки, затем 4000…2500.
# ТЕСТ 82 (17.11), модуль build-1116g: ПОРОГ ПОДЪЁМА. Спуск всегда 8000 (безопасно), тепловые биты после запроса; меняется
# ОДНО — пауза подъёма (запрос -> переключатель делитель -> PLL): 8000, 6000, 5000, 4000, 3500, 3000, 2500 нс, по N подъёмов.
# Тест 81а: 2000 — застревание на подъёме, через 48 подъёмов зависание. Останов на первой ступени с застреванием подъёма.
# Перед стартом: регулятор выключается ДО ключа памяти, карта проводится 03 -> 07 с памятью (гонка 16.11 20:10). Было (тест 78): Скобка GPC в PMU, порядок записей как в скобке с процессора (CTRL_1 после
# запроса — исправлено 16.11), отличие только в часах ожидания. Подъём всегда 8000 нс, как у NVIDIA, меняется ОДНО — пауза
# на спуске (запрос -> переключатель PLL -> делитель): 8000, 4000, 3000, 2500, 2000 нс, быстрый hangtest по N подъёмов.
# Как только спуск застрял и не вышел (журнал «ОСТАЛСЯ НА PLL»), ступени прекращаются и идут пробы вытащить переключатель —
# по одному способу (lab_mux_recover 1, 2, 4), по 5 подъёмов каждый, пауза спуска 8000. Застревание — данные; зависание графики — стоп.
#   bash ~/Home/nouveau-fix/lab/pmubr82b.sh [N=100]     — в терминале рабочего стола, не по ssh
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-100}"
for k in lab_pmu_up_ns lab_pmu_dn_ns lab_mux_recover lab_pmu_ctrl1_first; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1116g"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr7[6789]|pmubr8[01]|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
WAITS=(8000 4000 3500 3000 2500)
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_gov lab_pmu_ctrl1_first lab_pmu_bracket_ns lab_pmu_up_ns lab_pmu_dn_ns lab_pmu_dn_flag lab_mux_recover lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor"
OUT=~/Home/nouveau-fix/results/test82b-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
declare -A ORIG
for kv in $BASE; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in $STEP; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
run() {   # $1 — подпись, $2 — подъёмов
  local M0 E0 S0 G0 RC
  M0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); S0=$(cnt "ОСТАЛСЯ НА PLL"); G0=$(cnt "ушёл на делитель"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  FAST=1 bash "$HERE/hangtest.sh" "$2" >> "$OUT" 2>&1; RC=$?
  say "=== итог: $1 — код $RC, тайм-аутов $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - M0 )), вытащено повтором $(( $(cnt "ушёл на делитель") - G0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush") - E0 ))"
  return $RC
}
say "тест 82: N=$N, пауза подъёма ${WAITS[*]} нс, спуск 8000; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000; w lab_therm_gpc_factor 0xa
w lab_pmu_bracket_ns 8000; w lab_pmu_up_ns 8000; w lab_pmu_dn_flag 0; w lab_mux_recover 0; w lab_pmu_ctrl1_first 0
STUCK=0
w lab_pmu_dn_ns 8000
for W in "${WAITS[@]}"; do
  w lab_pmu_up_ns "$W"
  S0=$(cnt "ОСТАЛСЯ НА PLL"); U0=$(cnt "ТАЙМ-АУТ делитель -> PLL")
  run "подъём $W нс" "$N"; RC=$?
  U1=$(cnt "ТАЙМ-АУТ делитель -> PLL"); say "   застреваний на подъёме: $((U1 - U0))"
  [ "$U1" -gt "$U0" ] && { say "--- на паузе подъёма $W нс подъём застрял — останов"; break; }
  [ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; restore; exit 2; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- на паузе подъёма $W нс спуск застрял и не вышел — останов"; break; }
done
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|застрял|зависание|застреваний на подъёме|подготовка" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
