#!/bin/bash
# СВЕРКА СОСТОЯНИЯ НА СВОЕЙ КАРТЕ (25.11): снимки регистров памяти, шины XBAR, тактов и кэша L2 на каждом уровне под нашим
# модулем — чтобы сравнить с тем, что на тех же уровнях держит драйвер NVIDIA (lab/trace-memstate.py по записи NVIDIA).
# Так тестировщик нашёл причину порчи данных на GT 630M; на своей GF114 мы этого не делали ни разу.
# Только чтение регистров (lab/memstate-dump.py: лишь адреса, к которым NVIDIA на этой карте обращается сама); уровни ставятся
# обычными переходами драйвера. Регулятор на время снимков выключается и потом возвращается.
#   bash lab/memstate-levels.sh СПИСОК_АДРЕСОВ [КАТАЛОГ]      — по SSH, пароль sudo один раз; около 20 секунд
#   DOWN=1 bash lab/memstate-levels.sh …                      — уровни сверху вниз (см. ниже)
set -uo pipefail
KIT=~/Home/nouveau-fix; PRM=/sys/module/nouveau/parameters
A="${1:?список адресов — addrs.txt от lab/trace-memstate.py}"; D="${2:-$KIT/results/memstate-$(date +%Y%m%d-%H%M)}"
[ -r "$A" ] || { echo "нет списка адресов $A"; exit 1; }
[ -e "$PRM/lab_gov" ] || { echo "нужен лабораторный модуль"; exit 1; }
mkdir -p "$D"; sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n 1')"; [ -n "$PS" ] || { echo "нет debugfs pstate"; exit 1; }
G0="$(cat $PRM/lab_gov)"; T0="$(date '+%F %T')"
trap 'sudo sh -c "echo $G0 > $PRM/lab_gov"; echo "регулятор возвращён (lab_gov=$G0)"' EXIT
sudo sh -c "echo 0 > $PRM/lab_gov"
echo "модуль $(cat /sys/module/nouveau/srcversion), порядок lab_nv_xbarmem=$(cat $PRM/lab_nv_xbarmem 2>/dev/null)" | tee "$D/info.txt"
LV="$(sudo cat "$PS" | grep -oE '^[0-9a-f]{2}:' | tr -d ':')"
# DOWN=1 — снимать сверху вниз (сначала подъём на верхний уровень): средний и нижний уровни тогда достигнуты спуском, как в
# записи NVIDIA. Без него уровни идут снизу вверх, и сразу после загрузки нижний и средний ещё «не видели» верхнего.
[ "${DOWN:-0}" = 1 ] && LV="$(echo "$LV" | tac)"
for L in $LV; do
    sudo sh -c "echo $L > $PS"; sleep 3
    ac="$(sudo cat "$PS" | grep -m1 '^AC:' | sed 's/^AC: *//')"
    sudo python3 -I "$KIT/lab/memstate-dump.py" "$A" "$D/level-$L.txt" "уровень $L, $ac" | tee -a "$D/info.txt"
done
echo "ошибок шины в журнале ядра за время снимков: $(sudo journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'FAULT')" | tee -a "$D/info.txt"
sudo journalctl -k -b 0 --no-pager --since "$T0" | grep 'FAULT' | sed -E 's/^.*kernel: //' | sort | uniq -c | head -n 12 >> "$D/info.txt"
echo "готово: $D"
