#!/bin/bash
# ОПЫТ 104 (20.11), модуль build-1120b (ключ lab_src_probe). Карта полей регистров источника: каждое поле перебирается, частота
# меряется счётчиками тактов, значение сразу возвращается (~0,5 мс на вариант). Варианты: код 0 с кварцем 27/108 (биты 16–17),
# код 1, код 2 с подвыбором 0…7 (биты 24–26), код 3 с переключённым битом 8, 12, 31.
#   bash src104.sh safe   — этап 1 (на 0f: запасной делительный путь GPC и LTC) + этап 2 (на 07: опоры PLL GPC/LTC/XBAR,
#                           источники HUB2CLK и copy) — узлы, которые в этот момент не работают или почти не нагружены;
#   bash src104.sh xbar   — этап 3: РАБОЧИЙ источник XBAR2CLK на 03 — возможны мигание экрана и зависание графики;
#   bash src104.sh sys2   — этап 4: РАБОЧИЙ источник SYS2CLK на 03 — самый рискованный, возможна остановка машины.
# Запускать по порядку, следующий — только если предыдущий прошёл спокойно. В терминале рабочего стола; несколько секунд.
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_src_probe" ] || { echo "Нет lab_src_probe — нужен модуль build-1120b"; exit 1; }
STAGE="${1:-safe}"
pgrep -f "hangtest|gov94|auto101|core1|pre99|disp102|hub103" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test104-$STAGE-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
G0=$(cat $PRM/lab_gov)
trap 'w lab_src_probe 0; w lab_gov "$G0"; say "прервано"; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "опыт 104 ($STAGE): $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0
T0=$(date "+%F %T")
case "$STAGE" in
safe)
  sudo sh -c "echo 03 > $PS"; sleep 2
  w lab_src_probe 1; sudo sh -c "echo 0f > $PS"; sleep 2      # этап 1 — на 0f (PLL GPC/LTC работают и останутся)
  w lab_src_probe 2; sudo sh -c "echo 07 > $PS"; sleep 2 ;;   # этап 2 — на 07
xbar)
  sudo sh -c "echo 07 > $PS"; sleep 2; say "сейчас XBAR2CLK — экран может мигнуть"
  w lab_src_probe 4; sudo sh -c "echo 03 > $PS"; sleep 3 ;;
sys2)
  sudo sh -c "echo 07 > $PS"; sleep 2; say "сейчас SYS2CLK — если машина встанет, перезагрузка по ssh"
  w lab_src_probe 8; sudo sh -c "echo 03 > $PS"; sleep 3 ;;
*) echo "этап: safe | xbar | sys2"; exit 1 ;;
esac
journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB src-проба" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
journalctl -k -b 0 --no-pager --since "$T0" | grep -iE "Xid|FAULT|error|timeout" | grep -v "LAB src" | head -5 | tee -a "$OUT"
w lab_src_probe 0; w lab_gov "$G0"
say "=== конец; регулятор возвращён"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
