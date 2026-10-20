#!/bin/bash
# ДОДЕЛКА установки u2204-trace после остановки на шаге 5 (update-initramfs не найден).
# Ничего не стирает. Работает только с разделом с меткой u2204-trace на диске с серийным <DISK_SERIAL>.
# Запуск: sudo ~/nouveau-fix/trace/build-finish.sh
set -euo pipefail
SERIAL="<DISK_SERIAL>"; MNT=/mnt/u2204-trace; USER_NAME=alex
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "Запусти через sudo"; exit 1; }

DEV="$(lsblk -dno NAME,SERIAL | awk -v s="$SERIAL" '$2==s{print "/dev/"$1}')"
PART="$(blkid -L u2204-trace || true)"
[ -n "$DEV" ] && [ -n "$PART" ] && [ "${PART%[0-9]}" = "$DEV" ] || { echo "СТОП: раздел u2204-trace не на диске $SERIAL ($PART / $DEV)"; exit 1; }
echo "=== Раздел $PART на диске $DEV"
mkdir -p "$MNT"
findmnt -n "$MNT" >/dev/null || mount "$PART" "$MNT"
for d in dev dev/pts proc sys run; do findmnt -n "$MNT/$d" >/dev/null || mount --bind "/$d" "$MNT/$d"; done
trap 'for d in run sys proc dev/pts dev; do umount -l "$MNT/$d" 2>/dev/null || true; done' EXIT
CH() { chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C DEBIAN_FRONTEND=noninteractive HOME=/root "$@"; }

echo "=== 1/5 Что уже есть"
CH dpkg -l linux-image-generic nvidia-driver-390 xserver-xorg-core initramfs-tools python3-minimal 2>/dev/null | awk '/^[a-z][a-z] /{print "   "$1, $2, $3}' || true
id "$USER_NAME" >/dev/null 2>&1 || true
ls -l "$MNT/etc/modprobe.d/trace-lab.conf" "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" "$MNT/etc/sudoers.d/90-$USER_NAME" 2>&1 | sed 's/^/   /'

echo "=== 2/5 Недостающие пакеты (initramfs-tools, python3-minimal)"
CH apt-get install -y -q initramfs-tools python3-minimal 2>&1 | tail -n 3
for kv in $(ls "$MNT"/lib/modules); do
    if [ -e "$MNT/boot/initrd.img-$kv" ]; then CH update-initramfs -u -k "$kv" 2>&1 | tail -n 2
    else CH update-initramfs -c -k "$kv" 2>&1 | tail -n 2; fi
done
ls -l "$MNT"/boot/initrd.img-* "$MNT"/boot/vmlinuz-* | sed 's/^/   /'
ls "$MNT"/boot/initrd.img-* >/dev/null 2>&1 || { echo "СТОП: стартовый образ не собрался"; exit 1; }

echo "=== 3/5 X11 и файлы для записи"
mkdir -p "$MNT/etc/X11"
printf 'Section "Device"\n    Identifier "nv"\n    Driver "nvidia"\n    Option "Coolbits" "8"\nEndSection\n' > "$MNT/etc/X11/xorg.conf"
mkdir -p "$MNT/home/$USER_NAME/trace"
cp "$HERE/run-trace.sh" "$HERE/regdump.py" "$MNT/home/$USER_NAME/trace/"
chmod +x "$MNT/home/$USER_NAME/trace/run-trace.sh"
CH chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME"
md5sum "$MNT/home/$USER_NAME/trace/"* | sed 's/^/   /'

echo "=== 4/5 Загрузчик ТОЛЬКО на $DEV"
# GRUB 2.06 из Ubuntu 22.04 не понимает новые свойства ext4 (orphan_file, metadata_csum_seed),
# которые включает mkfs из Ubuntu 26.04 — отсюда «unknown filesystem». Снимаем их с раздела.
FEAT="$(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Filesystem features: *//p')"
echo "   свойства ext4: $FEAT"
OFF=""; for f in orphan_file metadata_csum_seed; do grep -qw "$f" <<<"$FEAT" && OFF="$OFF,^$f"; done
if [ -n "$OFF" ]; then
    echo "   снимаю: ${OFF#,}"
    for d in run sys proc dev/pts dev; do umount -l "$MNT/$d" 2>/dev/null || true; done
    sync; umount "$MNT"
    e2fsck -fy "$PART" >/dev/null 2>&1 || true
    tune2fs -O "${OFF#,}" "$PART"
    e2fsck -fy "$PART" >/dev/null 2>&1 || true
    mount "$PART" "$MNT"
    for d in dev dev/pts proc sys run; do mount --bind "/$d" "$MNT/$d"; done
    echo "   свойства теперь: $(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Filesystem features: *//p')"
fi
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/; s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/; s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' "$MNT/etc/default/grub"
grep -q '^GRUB_DISABLE_OS_PROBER=true' "$MNT/etc/default/grub" || echo 'GRUB_DISABLE_OS_PROBER=true' >> "$MNT/etc/default/grub"
CH grub-install --target=i386-pc "$DEV"
CH update-grub 2>&1 | tail -n 3

echo "=== 5/5 Проверки"
K="$(ls "$MNT"/boot/config-* | head -n 1)"; echo "   Ядро: $(basename "$K" | sed 's/config-//')"
grep -E '^CONFIG_MMIOTRACE=' "$K" | sed 's/^/   /' || echo "   !!! В ядре нет MMIOTRACE"
ls "$MNT"/lib/modules/*/updates/dkms/nvidia.ko* 2>/dev/null | sed 's/^/   Драйвер NVIDIA собран: /' || echo "   !!! Драйвер NVIDIA не собрался"
CH python3 -c 'print("   Python работает")' || echo "   !!! Нет Python"
sync
for d in run sys proc dev/pts dev; do umount -l "$MNT/$d" 2>/dev/null || true; done
umount "$MNT"
trap - EXIT
echo "=== Готово. Перезагрузись, в меню загрузки BIOS выбери ST120FN0 (Seagate 120 ГБ)."
