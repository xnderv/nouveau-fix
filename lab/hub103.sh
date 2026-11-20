#!/bin/bash
# ОПЫТ 103 (20.11), модуль build-1120a (ключ lab_hub01_probe). Что подаёт на HUB2CLK (hubk01, 0x137180) «источник 2» с
# подвыбором 0…7 (биты 24–26), без и с битом 8. Гипотеза (docs/2026-11-20/hub2clk-gf108.md): подвыбор 7 = выход PLL XBAR2CLK.
# На 07 модуль на ~0,5 мс ставит каждый вариант, меряет HUB2CLK счётчиком 0x1373b0 и возвращает как было. Пост-делитель
# HUB2CLK на 07 у нас ÷2, поэтому ждём: подвыбор 0 ~50 МГц, 1 ~138, 7 ~954 (PLL XBAR2CLK 1909 ÷ 2). Частоты остальных
# подвыборов покажут, какие ещё PLL можно подать на хаб (на 07 работают: GPC 1800, LTC и XBAR 1909, SYS2CLK 1645).
#   bash ~/Home/nouveau-fix/lab/hub103.sh     — в терминале рабочего стола; несколько секунд
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_hub01_probe" ] || { echo "Нет lab_hub01_probe — нужен модуль build-1120a"; exit 1; }
pgrep -f "hangtest|gov94|auto101|core1|pre99|disp102" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test103-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
G0=$(cat $PRM/lab_gov)
trap 'w lab_hub01_probe 0; w lab_gov "$G0"; say "прервано"; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "опыт 103: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
T0=$(date "+%F %T")
w lab_hub01_probe 1; sudo sh -c "echo 07 > $PS"; sleep 2
journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB hub01-проба" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
journalctl -k -b 0 --no-pager --since "$T0" | grep -iE "Xid|FAULT|error" | head -5 | tee -a "$OUT"
w lab_hub01_probe 0; w lab_gov "$G0"
say "=== конец; регулятор возвращён"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
