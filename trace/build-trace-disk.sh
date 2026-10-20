#!/bin/bash
# Ставит на ОТДЕЛЬНЫЙ диск минимальную Ubuntu 22.04 (ядро 5.15) с драйвером NVIDIA 390 и X11 —
# только для записи mmiotrace драйвера NVIDIA. Основная система и её загрузчик НЕ трогаются.
# Диск выбирается строго по серийному номеру. ВСЁ СОДЕРЖИМОЕ ЭТОГО ДИСКА БУДЕТ СТЁРТО.
# Запуск: sudo ~/nouveau-fix/trace/build-trace-disk.sh
set -euo pipefail

SERIAL="<DISK_SERIAL>"          # Seagate ST120FN0, 111.8G (sdb на 20.10.2026)
MNT=/mnt/u2204-trace
MIRROR=http://archive.ubuntu.com/ubuntu
USER_NAME=alex
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Запусти через sudo"; exit 1; }
command -v debootstrap >/dev/null || { echo "Нет debootstrap: sudo apt install debootstrap"; exit 1; }

DEV="$(lsblk -dno NAME,SERIAL | awk -v s="$SERIAL" '$2==s{print "/dev/"$1}')"
[ -n "$DEV" ] && [ -b "$DEV" ] || { echo "Диск с серийным номером $SERIAL не найден"; exit 1; }
ROOTDEV="$(findmnt -no SOURCE /)"; ROOTDISK="/dev/$(lsblk -no PKNAME "$ROOTDEV")"
[ "$DEV" != "$ROOTDISK" ] || { echo "СТОП: $DEV — это диск основной системы"; exit 1; }
if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then echo "СТОП: разделы $DEV смонтированы:"; lsblk "$DEV"; exit 1; fi

echo "=== Будет СТЁРТ диск:"
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL "$DEV"
echo "Основная система на $ROOTDISK — не трогается."
read -r -p "Стереть $DEV и поставить Ubuntu 22.04 для записи? Напиши СТЕРЕТЬ: " ans
[ "$ans" = "СТЕРЕТЬ" ] || { echo "Отмена, ничего не сделано."; exit 0; }

echo "=== 1/6 Разметка $DEV (MBR, один раздел ext4)"
wipefs -a "$DEV"*
parted -s "$DEV" mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on
partprobe "$DEV"; sleep 2
PART="${DEV}1"
mkfs.ext4 -F -q -L u2204-trace "$PART"
mkdir -p "$MNT"; mount "$PART" "$MNT"

echo "=== 2/6 Базовая система Ubuntu 22.04 (несколько минут)"
debootstrap --arch amd64 --components=main,restricted,universe,multiverse jammy "$MNT" "$MIRROR"

echo "=== 3/6 Настройка"
UUID="$(blkid -s UUID -o value "$PART")"
cat > "$MNT/etc/apt/sources.list" <<EOF
deb $MIRROR jammy main restricted universe multiverse
deb $MIRROR jammy-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF
echo "UUID=$UUID / ext4 errors=remount-ro 0 1" > "$MNT/etc/fstab"
echo u2204-trace > "$MNT/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 u2204-trace\n' > "$MNT/etc/hosts"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
for d in dev dev/pts proc sys run; do mount --bind "/$d" "$MNT/$d"; done
trap 'for d in run sys proc dev/pts dev; do umount -l "$MNT/$d" 2>/dev/null || true; done' EXIT

echo "=== 4/6 Ядро 5.15, загрузчик, драйвер NVIDIA 390, X11 (10–20 минут)"
chroot "$MNT" /bin/bash -e <<'EOS'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update -q
apt-get install -y -q --no-install-recommends linux-image-generic linux-headers-generic grub-pc \
    sudo locales console-setup kbd systemd-sysv udev kmod pciutils less xz-utils zstd python3-minimal \
    network-manager
apt-get install -y -q nvidia-driver-390 nvidia-settings xserver-xorg-core xserver-xorg-input-libinput xinit xterm x11-xserver-utils \
    mesa-utils glmark2
locale-gen en_US.UTF-8 ru_RU.UTF-8 >/dev/null
EOS

echo "=== 5/6 Пользователь, автовход, запрет автозагрузки драйвера NVIDIA (грузим вручную под записью)"
chroot "$MNT" /bin/bash -e <<EOS
id $USER_NAME >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,video,audio $USER_NAME
passwd -d $USER_NAME
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USER_NAME; chmod 440 /etc/sudoers.d/90-$USER_NAME
mkdir -p /etc/systemd/system/getty@tty1.service.d
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %%I \$TERM\n' > /etc/systemd/system/getty@tty1.service.d/autologin.conf
printf 'blacklist nvidia\nblacklist nvidia_drm\nblacklist nvidia_modeset\nblacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/trace-lab.conf
update-initramfs -u -k all >/dev/null
mkdir -p /etc/X11
printf 'Section "Device"\n    Identifier "nv"\n    Driver "nvidia"\n    Option "Coolbits" "8"\nEndSection\n' > /etc/X11/xorg.conf
EOS
mkdir -p "$MNT/home/$USER_NAME/trace"
cp "$HERE/run-trace.sh" "$HERE/regdump.py" "$MNT/home/$USER_NAME/trace/"
chmod +x "$MNT/home/$USER_NAME/trace/run-trace.sh"
chroot "$MNT" chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME"

echo "=== 6/6 Загрузчик ТОЛЬКО на $DEV"
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/; s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/; s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' "$MNT/etc/default/grub"
echo 'GRUB_DISABLE_OS_PROBER=true' >> "$MNT/etc/default/grub"
chroot "$MNT" grub-install --target=i386-pc "$DEV"
chroot "$MNT" update-grub 2>&1 | tail -n 2

echo "=== Проверки"
K="$(ls "$MNT"/boot/config-* | head -n 1)"; echo "Ядро: $(basename "$K" | sed 's/config-//')"
grep -E '^CONFIG_MMIOTRACE=' "$K" || echo "!!! В ядре нет MMIOTRACE"
ls "$MNT"/lib/modules/*/updates/dkms/nvidia.ko* 2>/dev/null | sed 's/^/Драйвер NVIDIA собран: /' || echo "!!! Драйвер NVIDIA не собрался"
sync
umount -l "$MNT/run" "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev" 2>/dev/null || true
umount "$MNT"
trap - EXIT
echo "=== Готово. Перезагрузись, в меню загрузки BIOS выбери диск ST120FN0 (Seagate 120 ГБ)."
