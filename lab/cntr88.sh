#!/bin/bash
# ТЕСТ 88 (17.11), модуль build-1117e (ключ lab_cntr_split). Тест 87: счётчик 0x1373b0 источник 0 = SYS2CLK, 1 = HUB2CLK;
# 0x1373c0 источник 0 = GPC2CLK, 1 и 2 = LTC2CLK и XBAR2CLK (частоты равны — не разделены). После прохода «как есть»
# три отдельных прохода, каждый отличается ОДНИМ и сразу возвращается:
#   1) пост-делитель XBAR2CLK вдвое глубже (только на 03/07, где узел на делителе) — какой из источников 1/2 упадёт вдвое;
#   2) команда замедления SYS2CLK /2 — видит ли счётчик замедление (контроль к тесту 87: 0x82 не менял счёт);
#   3) команда замедления GPC /2 — то же для 0x1373c0 источник 0.
#   bash ~/Home/nouveau-fix/lab/cntr88.sh     — в терминале рабочего стола; около полуминуты
set -uo pipefail
PRM=/sys/module/nouveau/parameters
for k in lab_cntr_sys lab_sys_r1 lab_cntr_split; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117e"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr|big83|fsrm8|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test88-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
declare -A ORIG
for k in lab_gov lab_cntr_sys lab_sys_r1 lab_cntr_split; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 88: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
T0=$(date "+%F %T")
w lab_cntr_sys 3; w lab_sys_r1 -1; w lab_cntr_split 7
for l in 07 0f 07 03; do sudo sh -c "echo $l > $PS"; sleep 2; done
w lab_cntr_sys 0; w lab_cntr_split 0
journalctl -k -b 0 --no-pager --since "$T0" | grep -E "LAB узлы по расчёту|LAB счётчик 1373|LAB   признак SYS2CLK" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
restore
say "=== конец; ключи возвращены"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
