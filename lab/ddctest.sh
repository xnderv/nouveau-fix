#!/bin/bash
# ПРИБОРНАЯ ПРОВЕРКА ФЛАГА ITC через служебный канал монитора (DDC/CI): читаем ВСЕ настройки монитора
# с флагом выключенным, включённым и снова выключенным (контроль), и показываем, что поменялось.
# Если монитор при ITC=1 сам что-то переключает (режим изображения, резкость и т. п.) — это будет видно.
# Только читает настройки монитора; флаг переключает через itctest.sh; в конце флаг ставится как был.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
D="$KIT/results/ddc-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"
command -v ddcutil >/dev/null || { echo "--- СТОП: нет ddcutil"; exit 1; }
[ -e /sys/module/nouveau/parameters/lab_hdmi_itc ] || { echo "--- СТОП: нет lab_hdmi_itc (нужен драйвер с 0005)"; exit 1; }
sudo -v || exit 1
WAS="$(cat /sys/module/nouveau/parameters/lab_hdmi_itc)"
sudo modprobe i2c-dev
echo "=== Монитор по DDC/CI:"; sudo ddcutil detect 2>&1 | tee "$D/detect.txt" | sed -n '1,12p'
grab() { echo "--- читаю все настройки монитора ($1), ~20–40 с..."; sudo ddcutil getvcp ALL > "$D/$1.txt" 2>&1; echo "    прочитано строк: $(wc -l < "$D/$1.txt")"; }
bash "$HERE/itctest.sh" off >/dev/null; sleep 3; grab 1-itc-off
bash "$HERE/itctest.sh" on  >/dev/null; sleep 3; grab 2-itc-on
bash "$HERE/itctest.sh" off >/dev/null; sleep 3; grab 3-itc-off-again
echo "=== Что изменилось при включении флага (выкл → вкл):"
diff "$D/1-itc-off.txt" "$D/2-itc-on.txt" && echo "    ничего"
echo "=== Контроль (выкл → выкл, сами по себе плавающие значения):"
diff "$D/1-itc-off.txt" "$D/3-itc-off-again.txt" && echo "    ничего"
[ "$WAS" = 1 ] && bash "$HERE/itctest.sh" on >/dev/null
echo "=== Флаг оставлен как был: lab_hdmi_itc = $(cat /sys/module/nouveau/parameters/lab_hdmi_itc). Записи: $D"
