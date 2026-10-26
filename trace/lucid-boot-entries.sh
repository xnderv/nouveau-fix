#!/bin/bash
# Пункт меню загрузки диска записи для Ubuntu 10.04 (ядро 2.6.32). Проба 26.10 ~21:00: GRUB 2.06 из 22.04 командой
# linux (32-битный вход в ядро) даёт чёрный экран и сразу сброс в BIOS; командой linux16 (16-битный вход, как у загрузчиков
# 2010 года) 10.04 грузится. Пункты 10.04 — только linux16; новейший по умолчанию, чтобы после F12 -> ST120FN0 ничего
# не выбирать (22.04 — стрелкой вверх). Параметры ядра — ровно как в первой удачной загрузке (earlyprintk=vga,keep
# ignore_loglevel panic=0): во второй, без earlyprintk, заставка plymouth упала («killed by USR2») и экран застыл после
# проверки диска. panic=0 — при панике не перезагружаться, а стоять. Меню показывается 5 с.
# 26.10 22:15 был пункт с maxcpus=1 (запись всё равно встала); 27.10 — по пункту на каждое ядро в 10.04 (2.6.32-74 и,
# после lucid-kernel.sh, 2.6.35-32), все процессоры, по умолчанию — новейшее.
# Пишется только в раздел 22.04 (/etc/grub.d, /etc/default/grub, grub.cfg);
# раздел 10.04 только читается. Запуск в основной системе: sudo ~/Home/nouveau-fix/trace/lucid-boot-entries.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
P1="$(blkid -L u2204-trace 2>/dev/null)" || { echo "Раздел u2204-trace не найден"; exit 1; }
P2="$(blkid -L u1004-trace 2>/dev/null)" || { echo "Раздел u1004-trace не найден"; exit 1; }
[ "$(lsblk -no PKNAME "$P1")" = "$(lsblk -no PKNAME "$P2")" ] || { echo "СТОП: разделы на разных дисках"; exit 1; }
lsblk -dno MODEL "/dev/$(lsblk -no PKNAME "$P1")" | grep -q ST120FN0 || { echo "СТОП: это не диск ST120FN0"; exit 1; }
for p in "$P1" "$P2"; do if findmnt -rn -S "$p" >/dev/null; then echo "СТОП: $p смонтирован — отключи его"; exit 1; fi; done
M1=/mnt/u2204-trace; M2=/mnt/u1004-trace; mkdir -p "$M1" "$M2"
umount_retry() { sync; for i in 1 2 3 4 5 6 7 8 9 10; do umount "$1" 2>/dev/null && return 0; sleep 2; done; echo "!!! $1 не отмонтировался"; return 1; }
trap 'for m in "$M1/run" "$M1/sys" "$M1/proc" "$M1/dev/pts" "$M1/dev"; do umount -l "$m" 2>/dev/null || true; done
      mountpoint -q "$M1" && umount_retry "$M1"; mountpoint -q "$M2" && umount_retry "$M2"; true' EXIT

echo "=== Ядра 10.04 (раздел только читается)"
mount -o ro "$P2" "$M2"
KVS="$(ls "$M2/lib/modules" | sort -V -r)"
for KV in $KVS; do
    ls -l "$M2/boot/vmlinuz-$KV" "$M2/boot/initrd.img-$KV" | sed 's/^/   /'
    file -b "$M2/boot/vmlinuz-$KV" | cut -c1-90 | sed 's/^/   /'
done
UUID2="$(blkid -s UUID -o value "$P2")"
umount_retry "$M2"

echo "=== Пункты меню в загрузчике 22.04 (по одному на ядро, новейшее — по умолчанию)"
mount "$P1" "$M1"
for d in dev dev/pts proc sys run; do mount --bind "/$d" "$M1/$d"; done
{
    printf '#!/bin/sh\nexec tail -n +3 $0\n'
    for KV in $KVS; do
        printf "menuentry 'Ubuntu 10.04, kernel %s (NVIDIA 270 stand)' {\n" "$KV"
        printf '\tinsmod part_msdos\n\tinsmod ext2\n'
        printf '\tsearch --no-floppy --fs-uuid --set=root %s\n' "$UUID2"
        printf '\tset gfxpayload=text\n'
        printf '\tlinux16 /boot/vmlinuz-%s root=UUID=%s ro earlyprintk=vga,keep ignore_loglevel panic=0\n' "$KV" "$UUID2"
        printf '\tinitrd16 /boot/initrd.img-%s\n}\n' "$KV"
    done
} > "$M1/etc/grub.d/41_lucid-stand"
DEF="Ubuntu 10.04, kernel $(echo "$KVS" | head -n 1) (NVIDIA 270 stand)"
chmod 755 "$M1/etc/grub.d/41_lucid-stand"
sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/; s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"$DEF\"/" "$M1/etc/default/grub"
grep -E '^GRUB_(DEFAULT|TIMEOUT)=' "$M1/etc/default/grub" | sed 's/^/   /'
chroot "$M1" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C HOME=/root update-grub 2>&1 | tail -n 2
echo "=== Меню загрузки диска (по порядку):"
grep -E "^(menuentry|submenu) " "$M1/boot/grub/grub.cfg" | sed "s/^\(menuentry\|submenu\) '\([^']*\)'.*/   \2/" | nl -w4
grep -n "linux16\|set default" "$M1/boot/grub/grub.cfg" | sed 's/^/   /'
echo "=== Готово. F12 -> ST120FN0: через 5 с сама грузится 10.04 (22.04 — стрелкой вверх)."
