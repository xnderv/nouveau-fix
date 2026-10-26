#!/bin/bash
# Ставит драйвер NVIDIA 270.x в Ubuntu 10.04 (раздел u1004-trace) для записи. Установщики лежат в ~/trace/nvidia/
# (их кладёт туда lucid-disk.sh put из основной системы; сети в 10.04 нет). Прежний драйвер NVIDIA установщик удаляет сам.
# Лицензию NVIDIA показывает установщик — принимаешь её ты. Драйвер при старте системы НЕ загружается (запрет в
# /etc/modprobe.d/stand-2011.conf) — его грузит сценарий записи.
# Версию modinfo не знает (в модуле 2011 года нет MODULE_VERSION) — сверяем по строке «Kernel Module 270.xx» в nvidia.ko.
# Установщик в конце пробно загружает модуль, поэтому после установки — перезагрузка, и запись начинается на чистой карте.
# На экран — латиница (кириллица в консоли 10.04 может не отображаться).
# Запуск: nv1 / nv2  (или sudo ~/trace/install-nvidia-lucid.sh 270.26)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
show() { echo ">>> $*"; }
nvver() {
  local f; f="$(find "/lib/modules/$(uname -r)" -name nvidia.ko 2>/dev/null | head -n 1 || true)"
  [ -n "$f" ] && grep -ao 'Kernel Module  *[0-9][0-9.]*' "$f" | head -n 1 | awk '{print $NF}' || true
}
V="${1:-}"
RUN="$HERE/nvidia/NVIDIA-Linux-x86_64-$V.run"
[ -n "$V" ] && [ -f "$RUN" ] || { show "STOP: no installer for version '$V' in ~/trace/nvidia"; exit 1; }
grep -q 'Ubuntu 10.04' /etc/issue || { show "STOP: this is not Ubuntu 10.04"; exit 1; }
lsmod | grep -q '^nvidia ' && { show "STOP: nvidia module is loaded. Reboot first (sudo reboot, F12 -> ST120FN0)."; exit 1; }
lsmod | grep -q '^nouveau ' && { show "STOP: nouveau is loaded - should not be. Tell Claude."; exit 1; }

want="$(sed -n 's/^MD5=//p' "$RUN" | head -n 1)"; got="$(tail -n +6 "$RUN" | md5sum | cut -b-32)"
[ "$want" = "$got" ] || { show "STOP: installer file is damaged"; exit 1; }
show "Installer $V checked (MD5 OK)."
echo
show "The NVIDIA installer will ask. Answer:"
show "   License                              -> Accept   (your decision)"
show "   Existing driver will be uninstalled  -> Yes"
show "   32-bit compatibility libraries       -> No"
show "   Run nvidia-xconfig                   -> No"
read -r -p ">>> Press Enter to start the installer " _
echo "установка $V" > /tmp/stand-card-used
cd /tmp
if ! sh "$RUN" --no-network --no-precompiled-interface; then
  cp /var/log/nvidia-installer.log "$HERE/install-$V-failed.log" 2>/dev/null || true
  show "STOP: the installer failed. Log saved: ~/trace/install-$V-failed.log"; exit 1
fi
cp /var/log/nvidia-installer.log "$HERE/install-$V.log" 2>/dev/null || true

# Установщик в конце проверяет модуль загрузкой — выгружаем.
if lsmod | grep -q '^nvidia '; then rmmod nvidia || true; fi
NV="$(nvver)"
[ "$NV" = "$V" ] || { show "STOP: installed module is '$NV', expected $V"; exit 1; }
# Тот же xorg.conf, что в записи 390 (try7) — для сравнения один к одному.
printf 'Section "Device"\n    Identifier "nv"\n    Driver "nvidia"\n    Option "Coolbits" "8"\nEndSection\n' > /etc/X11/xorg.conf
grep -q '^blacklist nvidia' /etc/modprobe.d/stand-2011.conf || echo 'blacklist nvidia' >> /etc/modprobe.d/stand-2011.conf
{ echo "### libGL после установки $V"; ldconfig -p | grep 'libGL.so.1 ' || true; ls -l /usr/lib/libGL.so.1 || true; } >> "$HERE/install-$V.log" 2>&1
chown -R --reference="$HERE" "$HERE"
show "DONE: NVIDIA driver $NV installed."
show "Next: sudo reboot, F12 -> ST120FN0, then type: rec"
