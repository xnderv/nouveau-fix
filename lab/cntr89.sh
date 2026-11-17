#!/bin/bash
# ТЕСТ 89 (17.11), модуль build-1117f. Опознать оставшиеся источники счётчиков. Тест 88: 0x1373b0 0 = SYS2CLK, 1 = HUB2CLK;
# 0x1373c0 0 = GPC2CLK, 1 = LTC2CLK, 2 = XBAR2CLK, 6 = делительный путь GPC; оба видят замедление. Неопознаны: 0x1373b0
# источники 2/3 (= расчёт copy и MSDCLK: 135/405/540), 4 (~100,9 МГц); 0x1373c0 источники 3–5 (405), 7 (270/810/810).
# После прохода «как есть» отдельные проходы, каждый отличается ОДНИМ и сразу возвращается:
#   пост-делитель copy вдвое глубже; основной делитель LTC вдвое глубже; источник делителя copy = 2 («100 МГц»);
#   делитель опоры PLL LTC вдвое глубже (только 03/07, пока LTC на делителе; PLL перезахватывается и возвращается).
#   bash ~/Home/nouveau-fix/lab/cntr89.sh     — в терминале рабочего стола; около полуминуты
set -uo pipefail
PRM=/sys/module/nouveau/parameters
for k in lab_cntr_sys lab_sys_r1 lab_cntr_split; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117f"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr|big83|fsrm8|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test89-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
declare -A ORIG
for k in lab_gov lab_cntr_sys lab_sys_r1 lab_cntr_split; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 89: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
T0=$(date "+%F %T")
w lab_cntr_sys 3; w lab_sys_r1 -1; w lab_cntr_split 120
for l in 07 0f 07 03; do sudo sh -c "echo $l > $PS"; sleep 2; done
w lab_cntr_sys 0; w lab_cntr_split 0
journalctl -k -b 0 --no-pager --since "$T0" | grep -E "LAB узлы по расчёту|LAB счётчик 1373|LAB   признак SYS2CLK|LAB   PLL LTC" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
restore
say "=== конец; ключи возвращены"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
