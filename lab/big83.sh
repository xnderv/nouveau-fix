#!/bin/bash
# ТЕСТ 83 (17.11), модуль build-1117b (глубина в оба поля, ключи lab_pmu_up_flag, lab_pmu_slow_val, lab_pmu_slow_rel=2). Большой прогон «на час» — части от безопасных к
# рискованным, каждая отличается от опорной ОДНИМ. Опорная: скобка GPC в PMU, тепловые биты после запроса, глубина /6 (как
# NVIDIA), подъём 8000, спуск 8000. Быстрый hangtest по N подъёмов на ступень. Стоп на зависании графики или на вечном
# застревании (дальше данные недействительны). Перед стартом: регулятор выключается ДО ключей, карта проводится 03 -> 07.
#   0. время включения замедления в этой загрузке (25 PMU-сценариев без переключателя)
#   0б. какое поле глубины действует при бите 7 = 1 и = 0 (устоявшееся замедление, счётчик; без переключателя) — версия автора
#   1. опорная 8000 / 8000
#   2. спуск: 4000, 2000, 1000, 500, «сразу» (подъём 8000)
#   3. спуск по флагу на карте, без запаса (подъём 8000)
#   4. глубина /2 и /8 в оба поля (8000 / 8000), затем снова /6
#   5. подъём по флагу на карте, без запаса (спуск 8000)
#   6. порог подъёма: 6000, 5000, 4000, 3500, 3000, 2500 (спуск 8000) — стоп на первом застревании подъёма
#   bash ~/Home/nouveau-fix/lab/big83.sh [N=100]     — в терминале рабочего стола, не по ssh; около часа
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-100}"
for k in lab_pmu_up_flag lab_pmu_dn_flag lab_pmu_up_ns lab_pmu_dn_ns lab_pmu_slow lab_pmu_slow_val lab_pmu_slow_rel; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117b"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_gov lab_pmu_slow lab_pmu_slow_val lab_pmu_slow_rel lab_pmu_ctrl1_first lab_pmu_bracket_ns lab_pmu_up_ns lab_pmu_dn_ns lab_pmu_up_flag lab_pmu_dn_flag lab_mux_recover lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor"
OUT=~/Home/nouveau-fix/results/test83-$(date +%Y%m%d-%H%M%S).txt
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
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
STOP=0
run() {   # $1 — подпись; ставит STOP=1 при зависании или вечном застревании
  local D0 U0 S0 E0 RC
  D0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); U0=$(cnt "ТАЙМ-АУТ делитель -> PLL"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
  FAST=1 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  say "=== итог: $1 — код $RC, застреваний спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
  LASTUP=$(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 ))
  [ "$RC" = 2 ] && { say "--- зависание графики — стоп"; STOP=1; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- вечное застревание — стоп (дальше данные недействительны)"; STOP=1; }
  return 0
}
base() { w lab_pmu_ctrl1_first 0; w lab_therm_gpc_factor 0xa; w lab_pmu_up_ns 8000; w lab_pmu_dn_ns 8000; w lab_pmu_up_flag 0; w lab_pmu_dn_flag 0; }
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 83: N=$N; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"

say "--- 0. включение замедления /6 в этой загрузке (PMU, без переключателя)"
w lab_therm_gpc_factor 0xa; T0=$(date "+%F %T"); w lab_pmu_slow 5
for l in 0f 07 03 0f 07; do sudo sh -c "echo $l > $PS"; sleep 2; done
w lab_pmu_slow 0
journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB PMU-замедление" | python3 -I -c '
import sys, re, statistics as s
g = {}
for l in sys.stdin:
    m = re.search(r"GPC (\d+) кГц.*через ≈ (\d+) нс", l)
    if m: g.setdefault(int(m.group(1)) // 1000, []).append(int(m.group(2)))
for k in sorted(g, reverse=True):
    v = g[k]; print("    GPCCLK %4d МГц: медиана %d нс, разброс %d–%d, n %d" % (k, s.median(v), min(v), max(v), len(v)))' | tee -a "$OUT"
sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2

say "--- 0б. какое поле глубины действует (GPC на 07, 405 МГц; A — биты 16–21, B — биты 0–5, бит 7)"
w lab_pmu_slow_rel 2
for v in "0|как обычно: A=/6 B=/6 бит7=1" "0x0002008e|A=/2 B=/8 бит7=1" "0x0002000e|A=/2 B=/8 бит7=0" "0x000e0082|A=/8 B=/2 бит7=1" "0x000e0002|A=/8 B=/2 бит7=0"; do
  val="${v%%|*}"; name="${v#*|}"
  w lab_pmu_slow_val "$val"; sudo sh -c "echo 03 > $PS"; sleep 2
  T0=$(date "+%F %T"); w lab_pmu_slow 3; sudo sh -c "echo 07 > $PS"; sleep 2; w lab_pmu_slow 0
  R=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB PMU-устоявшееся" | sed -E 's/.*в ([0-9.]+) раза.*/\1/' | tr '\n' ' ')
  say "    $name: такт замедлен в [$R] раза"
done
w lab_pmu_slow_val 0; w lab_pmu_slow_rel 0

for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000; w lab_pmu_bracket_ns 8000; w lab_mux_recover 0
base
say "--- 1. опорная: подъём 8000, спуск 8000"; run "опорная 8000/8000"
if [ $STOP = 0 ]; then
  say "--- 2. спуск короче (подъём 8000)"
  for W in 4000 2000 1000 500 1; do base; w lab_pmu_dn_ns "$W"; run "спуск $W"; [ $STOP = 1 ] && break; done
fi
if [ $STOP = 0 ]; then say "--- 3. спуск по флагу на карте, без запаса"; base; w lab_pmu_dn_flag 1; w lab_pmu_dn_ns 0; run "спуск по флагу, запас 0"; fi
if [ $STOP = 0 ]; then
  say "--- 4. глубина в оба поля (8000/8000)"
  for c in 0x2 0xe 0xa; do base; w lab_therm_gpc_factor "$c"; run "глубина код $c"; [ $STOP = 1 ] && break; done
fi
if [ $STOP = 0 ]; then say "--- 5. подъём по флагу на карте, без запаса"; base; w lab_pmu_up_flag 1; w lab_pmu_up_ns 0; run "подъём по флагу, запас 0"; fi
if [ $STOP = 0 ]; then
  say "--- 6. порог подъёма (спуск 8000)"
  for W in 6000 5000 4000 3500 3000 2500; do base; w lab_pmu_up_ns "$W"; run "подъём $W"; [ $STOP = 1 ] && break; [ "$LASTUP" -gt 0 ] && { say "--- подъём застрял на $W — стоп"; break; }; done
fi
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|^.{8} ---|GPCCLK .* МГц|подготовка|замедлен в" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
