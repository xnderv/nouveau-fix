#!/bin/bash
# ТЕСТ 91 (17.11), модуль build-1117h (ключ lab_e9e0_probe). Домен 7 VBIOS (регистр 0x00e9e0) — такт дисплея?
# Монитор host: 2560x1440@60, частота пикселей 241,5 МГц (EDID). Домен 7: 270 / 405 / 540 МГц на 03 / 07 / 0f.
# На уровнях 07 и 03 модуль ступенями опускает 0x00e9e0: 270 (/6), 202,5 (/8), 162 (/10) — по 100 мс — и читает липкий бит
# «был недогруз» каждого выхода дисплея (0x616308, 0x616b08, бит 4). Предсказание версии «такт дисплея»: 270 — чисто,
# 202,5 — недогруз. На первом недогрузе ступени прекращаются, всё возвращается. Монитор может мигнуть.
#   1-й проход — учёт недогруза как есть; 2-й — с включённым учётом (режим «повтор»), на случай если без него бит не считает.
#   bash ~/Home/nouveau-fix/lab/disp91.sh     — в терминале рабочего стола; около полуминуты
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_e9e0_probe" ] || { echo "Нет lab_e9e0_probe — нужен модуль build-1117h"; exit 1; }
pgrep -f "ladder70|seq68|xfer71|cntr[78]|srcclk7|bootprobe|pmubr|big83|fsrm8|core90|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test91-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
G0=$(cat $PRM/lab_gov); P0=$(cat $PRM/lab_e9e0_probe)
trap 'w lab_e9e0_probe 0; w lab_gov "$G0"; say "прервано"; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 91: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 07 > $PS"; sleep 2
T0=$(date "+%F %T")
for m in 1 2; do
  w lab_e9e0_probe "$m"
  for l in 03 07; do sudo sh -c "echo $l > $PS"; sleep 3; done
  w lab_e9e0_probe 0
done
journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB e9e0-проба" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
journalctl -k -b 0 --no-pager --since "$T0" | grep -iE "disp|Xid|FAULT|error" | grep -v "LAB e9e0" | head -5 | tee -a "$OUT"
w lab_e9e0_probe "$P0"; w lab_gov "$G0"
say "=== конец; ключи возвращены"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
