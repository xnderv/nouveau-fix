#!/bin/bash
# ОПЫТ 106 (20.11), модуль build-1120e: правило «никогда выше VBIOS» (+2 % допуск, как NVIDIA) и обходной источник HUB2CLK
# (код 2, подвыбор 7 → PLL XBAR2CLK, как NVIDIA на GF108) с самопроверкой счётчиком. На нашей GF114 обычная работа не должна
# измениться (в таблице нет таких случаев). Опыт:
#   1) переходы 03 → 0f → 07 → 03 → 07: в журнале не должно быть ни «беру снизу», ни «hub01-alt» — генератор как раньше;
#   2) ПРИНУДИТЕЛЬНАЯ попытка обходного пути на 07 (lab_hub01_alt_force=1): на GF114 провода нет (опыт 103) — самопроверка
#      обязана увидеть «ничего» и откатиться; HUB2CLK после отката — снова 810 МГц.
#   bash ~/Home/nouveau-fix/lab/alt106.sh     — в терминале рабочего стола; около 20 секунд
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_hub01_alt_force" ] || { echo "Нет lab_hub01_alt_force — нужен модуль build-1120e"; exit 1; }
OUT=~/Home/nouveau-fix/results/test106-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
G0=$(cat $PRM/lab_gov)
trap 'w lab_hub01_alt_force 0; w lab_gov "$G0"; say "прервано"; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "опыт 106: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0
T0=$(date "+%F %T")
for l in 03 0f 07 03 07; do sudo sh -c "echo $l > $PS"; sleep 2; done
say "--- 1. обычные переходы: строк «беру снизу» $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'беру снизу'), строк hub01-alt $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'hub01-alt'), ошибок $(journalctl -k -b 0 --no-pager --since "$T0" | grep -cE 'Xid|FAULT at|ТАЙМ-АУТ')"
T1=$(date "+%F %T")
w lab_hub01_alt_force 1; sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2
say "--- 2. принудительная попытка обходного пути:"
journalctl -k -b 0 --no-pager --since "$T1" | grep "hub01-alt" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
say "    признак отказа до перезагрузки lab_hub01_alt_bad = $(cat $PRM/lab_hub01_alt_bad); ошибок $(journalctl -k -b 0 --no-pager --since "$T1" | grep -cE 'Xid|FAULT at|ТАЙМ-АУТ')"
w lab_hub01_alt_force 0; w lab_gov "$G0"
say "=== конец; регулятор возвращён"
cp "$OUT" "$OUT.sum"
echo "Результат: $OUT"
