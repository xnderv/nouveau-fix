#!/bin/bash
# ТЕСТ 81 (16.11 вечер), модуль build-1116g. Разделяет две причины вечного застревания из теста 80 (часть 2 отличалась от части 1
# порядком тепловых битов И паузой подъёма): (а) только пауза подъёма 2000; (б) только тепловые биты до запроса. Было в тесте 80: Продолжение теста 78 (8000…2000 — 0 застреваний): (1) ниже, тепловые биты после
# запроса — 1500, 1000, 500, 0 нс; (2) в конце в той же загрузке тепловые биты ДО запроса (lab_pmu_ctrl1_first=1) на 2000 нс —
# как в тесте 76, где спуск застрял насовсем. Ранее (тест 78): Скобка GPC в PMU, порядок записей как в скобке с процессора (CTRL_1 после
# запроса — исправлено 16.11), отличие только в часах ожидания. Подъём всегда 8000 нс, как у NVIDIA, меняется ОДНО — пауза
# на спуске (запрос -> переключатель PLL -> делитель): 8000, 4000, 3000, 2500, 2000 нс, быстрый hangtest по N подъёмов.
# Как только спуск застрял и не вышел (журнал «ОСТАЛСЯ НА PLL»), ступени прекращаются и идут пробы вытащить переключатель —
# по одному способу (lab_mux_recover 1, 2, 4), по 5 подъёмов каждый, пауза спуска 8000. Застревание — данные; зависание графики — стоп.
#   bash ~/Home/nouveau-fix/lab/pmubr81.sh [N=100]     — в терминале рабочего стола, не по ssh
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-100}"
for k in lab_pmu_up_ns lab_pmu_dn_ns lab_mux_recover lab_pmu_ctrl1_first; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1116g"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr7[6789]|pmubr80|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
WAITS=(1500 1000 500 1)   # 1 нс = «сразу» (0 — значит «как lab_pmu_bracket_ns»)
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_pmu_ctrl1_first lab_pmu_bracket_ns lab_pmu_up_ns lab_pmu_dn_ns lab_pmu_dn_flag lab_mux_recover lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor"
OUT=~/Home/nouveau-fix/results/test81-$(date +%Y%m%d-%H%M%S).txt
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
say "тест 81: N=$N, пауза спуска ${WAITS[*]} нс, подъём 8000; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000; w lab_therm_gpc_factor 0xa
w lab_pmu_bracket_ns 8000; w lab_pmu_up_ns 8000; w lab_pmu_dn_flag 0; w lab_mux_recover 0; w lab_pmu_ctrl1_first 0
STUCK=0
say "--- (а) тепловые биты ПОСЛЕ запроса, подъём 2000, спуск 2000 — отличие от теста 80/1 только пауза подъёма"
w lab_pmu_ctrl1_first 0; w lab_pmu_up_ns 2000; w lab_pmu_dn_ns 2000
S0=$(cnt "ОСТАЛСЯ НА PLL")
run "(а) биты после, подъём 2000, спуск 2000" "$N"; RC=$?
[ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; restore; exit 2; }
if [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ]; then
  say "--- (а) застрял насовсем — (б) в этой загрузке не проверить, нужна перезагрузка"
else
  say "--- (б) тепловые биты ДО запроса, подъём 8000, спуск 2000 — отличие от теста 80/1 только порядок битов"
  w lab_pmu_ctrl1_first 1; w lab_pmu_up_ns 8000; w lab_pmu_dn_ns 2000
  S0=$(cnt "ОСТАЛСЯ НА PLL")
  run "(б) биты до, подъём 8000, спуск 2000" "$N"; RC=$?
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && say "--- (б) застрял насовсем"
fi
w lab_pmu_ctrl1_first 0; w lab_pmu_up_ns 8000
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|застрял|зависание|^.{8} --- " "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
