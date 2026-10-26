#!/bin/bash
# Ставит драйвер NVIDIA 270.x в Ubuntu 10.04 (раздел u1004-trace) для записи. Установщики лежат в ~/trace/nvidia/
# (их кладёт туда lucid-disk.sh put из основной системы; сети в 10.04 нет). Прежний драйвер NVIDIA установщик удаляет сам.
# Лицензию NVIDIA показывает установщик — принимаешь её ты. Драйвер при старте системы НЕ загружается (запрет в
# /etc/modprobe.d/stand-2011.conf) — его грузит сценарий записи.
# Запуск: sudo ~/trace/install-nvidia-lucid.sh 270.26     (или 270.41.06)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
V="${1:-}"
RUN="$HERE/nvidia/NVIDIA-Linux-x86_64-$V.run"
[ -n "$V" ] && [ -f "$RUN" ] || { echo "Укажи версию. Есть: $(cd "$HERE/nvidia" && ls *.run | sed 's/NVIDIA-Linux-x86_64-//; s/\.run//' | tr '\n' ' ')"; exit 1; }
grep -q 'Ubuntu 10.04' /etc/issue || { echo "СТОП: это не Ubuntu 10.04"; exit 1; }
lsmod | grep -q '^nvidia ' && { echo "СТОП: драйвер nvidia загружен — перезагрузись (sudo reboot) и запусти снова"; exit 1; }
lsmod | grep -q '^nouveau ' && { echo "СТОП: загружен nouveau — так быть не должно, напиши мне"; exit 1; }

echo "=== Проверка установщика $V (встроенная сумма MD5)"
want="$(sed -n 's/^MD5=//p' "$RUN" | head -n 1)"; got="$(tail -n +6 "$RUN" | md5sum | cut -b-32)"
[ "$want" = "$got" ] || { echo "СТОП: установщик повреждён ($got вместо $want)"; exit 1; }
echo "   в порядке"

echo "=== Установка NVIDIA $V. На вопросы установщика:"
echo "    лицензия — Accept (решаешь ты); 32-битные библиотеки — No; запустить nvidia-xconfig — No."
echo "    Если спросит про удаление прежнего драйвера NVIDIA — Yes."
read -r -p "Enter — начать установку " _
cd /tmp
sh "$RUN" --no-network --no-precompiled-interface || { echo "СТОП: установщик закончил с ошибкой. Журнал: /var/log/nvidia-installer.log"; cp /var/log/nvidia-installer.log "$HERE/install-$V-failed.log" 2>/dev/null; exit 1; }
cp /var/log/nvidia-installer.log "$HERE/install-$V.log" 2>/dev/null || true

# Установщик в конце проверяет модуль загрузкой — выгружаем, чтобы сценарий записи начинал с чистой карты.
lsmod | grep -q '^nvidia ' && rmmod nvidia || true
NV="$(modinfo -F version nvidia 2>/dev/null || true)"
[ "$NV" = "$V" ] || { echo "СТОП: установлен модуль «$NV», а ставили $V"; exit 1; }
# Тот же xorg.conf, что в записи 390 (try7) — для сравнения один к одному.
printf 'Section "Device"\n    Identifier "nv"\n    Driver "nvidia"\n    Option "Coolbits" "8"\nEndSection\n' > /etc/X11/xorg.conf
grep -q '^blacklist nvidia' /etc/modprobe.d/stand-2011.conf || echo 'blacklist nvidia' >> /etc/modprobe.d/stand-2011.conf
echo "=== Библиотеки OpenGL в поиске (сценарий записи берёт /usr/lib — NVIDIA):"
ldconfig -p | grep 'libGL.so.1 ' | sed 's/^/   /' || true
ls -l /usr/lib/libGL.so.1 | sed 's/^/   /' || true
chown -R --reference="$HERE" "$HERE"
echo "=== Готово: драйвер NVIDIA $NV установлен. Дальше запись: sudo ~/trace/run-trace-lucid.sh"
