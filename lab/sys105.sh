#!/bin/bash
# ОПЫТ 105 (20.11), модуль build-1120c (ключ lab_sys2_probe). РАБОЧИЙ источник SYS2CLK — ПО ОДНОМУ «живому» варианту за запуск,
# внутри скобки замедления SYS2CLK (как NVIDIA переключает этот узел). Этап 3 опыта 104 (все варианты подряд, без скобки) повесил
# машину. Порядок — от мягкого к резкому (на 03 SYS2CLK = 270 МГц, в скобке вдвое меньше):
#   1 бит 8 → SPPLL1 (~269)   2 код 2/подвыбор 1 (280,3)   3 кварц 108   4 код 2/подвыбор 0 (100,9)   5 кварц 27
# Следующий вариант — только после разбора предыдущего. Если машина встанет — перезапуск розеткой; номер варианта виден в
# журнале прошлой загрузки (строка «НАЧИНАЮ вариант», пишется до смены).
#   bash ~/Home/nouveau-fix/lab/sys105.sh 1     — в терминале рабочего стола; несколько секунд
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_sys2_probe" ] || { echo "Нет lab_sys2_probe — нужен модуль build-1120c"; exit 1; }
K="${1:-}"; [[ "$K" =~ ^[1-5]$ ]] || { echo "вариант 1…5"; exit 1; }
OUT=~/Home/nouveau-fix/results/test105-v$K-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
G0=$(cat $PRM/lab_gov)
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "опыт 105, вариант $K: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 07 > $PS"; sleep 2
T0=$(date "+%F %T")
w lab_sys2_probe "$K"; sudo sh -c "echo 03 > $PS"; sleep 2
journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB sys2-проба" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
journalctl -k -b 0 --no-pager --since "$T0" | grep -iE "Xid|FAULT at|timeout" | head -5 | tee -a "$OUT"
w lab_sys2_probe 0; w lab_gov "$G0"
say "=== конец; регулятор возвращён"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
