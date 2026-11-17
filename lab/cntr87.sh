#!/bin/bash
# ТЕСТ 87 (17.11), модуль build-1117d (ключи lab_cntr_sys, lab_sys_r1). Счётчики тактов хабовой стороны и SYS2CLK.
# 1) Что считают 0x1373b0 и 0x1373c0 при поле источника 0…7 (у NVIDIA Pascal: 0x1373b0 — SYS2CLK, 0x1373c0 — XBAR2CLK;
#    на Fermi драйвер NVIDIA читает 0x1373c0 с источником 0). Сверка с расчётом драйвера на уровнях 03, 07, 0f.
# 2) Замедляет ли SYS2CLK пара «поле B /2 + бит 7» (0x020164 = 0x82 после снятия скобки, как у NVIDIA на GF114):
#    в том же замере — как есть, затем 0x020164 = 0, затем вернуть. Одно отличие. Только счётчики и одна запись
#    в регистр замедления SYS2CLK, частоты узлов не трогаются.
#   bash ~/Home/nouveau-fix/lab/cntr87.sh     — в терминале рабочего стола; около полуминуты
set -uo pipefail
PRM=/sys/module/nouveau/parameters
for k in lab_cntr_sys lab_sys_r1; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117d"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr|big83|fsrm8|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test87-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
declare -A ORIG
for k in lab_gov lab_cntr_sys lab_sys_r1; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 87: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
T0=$(date "+%F %T")
w lab_cntr_sys 3; w lab_sys_r1 0
for l in 07 0f 07 03; do sudo sh -c "echo $l > $PS"; sleep 2; done
w lab_cntr_sys 0; w lab_sys_r1 -1
journalctl -k -b 0 --no-pager --since "$T0" | grep -E "LAB узлы по расчёту|LAB счётчик 1373" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
restore
say "=== конец; ключи возвращены"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
