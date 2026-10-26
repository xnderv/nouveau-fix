#!/bin/bash
# Ставит Ubuntu 10.04 (ядро 2.6.32, X.Org 1.7) на диск записи u2204-trace РЯДОМ с Ubuntu 22.04 — для записи первых
# драйверов NVIDIA с поддержкой GTX 560 Ti (270.26 и 270.41.06). Сам драйвер NVIDIA здесь не ставится (отдельный шаг).
#   1. копия каталога записей с диска в ~/Home/nouveau-archive/ и копия таблицы разделов;
#   2. раздел 22.04 ужимается до 50 ГБ (данные остаются), на остальном месте — новый раздел ext3 «u1004-trace»;
#   3. 10.04 собирается в нём через debootstrap из old-releases.ubuntu.com (всё скачивает основная система);
#   4. в меню загрузчика 22.04 на этом диске добавляется пункт для 10.04 (загрузчик 10.04 не ставится).
# Основная система и её загрузчик НЕ трогаются. В 10.04 сеть не настроена и драйвер сетевой карты запрещён.
# Диск находится по метке раздела u2204-trace и модели ST120FN0.
# Запуск: sudo ~/Home/nouveau-fix/trace/build-lucid-disk.sh
set -euo pipefail

MODEL=ST120FN0
P1_SIZE_SECT=104857600          # новый размер раздела 22.04: 50 ГиБ в секторах по 512 байт
P1_FS=48G                       # файловую систему сначала ужимаем с запасом, потом растягиваем на весь раздел
LABEL2=u1004-trace
MNT1=/mnt/u2204-trace
MNT2=/mnt/u1004-trace
MIRROR=http://old-releases.ubuntu.com/ubuntu
HERE="$(cd "$(dirname "$0")" && pwd)"
HOMEDIR="$(cd "$HERE/../.." && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Запусти через sudo"; exit 1; }
USER_NAME="${SUDO_USER:-}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "Запусти через sudo из своей учётной записи"; exit 1; }
for c in debootstrap sfdisk resize2fs e2fsck mkfs.ext3 setarch partprobe; do
    command -v "$c" >/dev/null || { echo "Нет программы $c"; exit 1; }
done

# --- Какой диск: раздел с меткой u2204-trace на диске ST120FN0, не диск основной системы, ничего не смонтировано
P1="$(blkid -L u2204-trace 2>/dev/null)" || { echo "Раздел с меткой u2204-trace не найден — подключи Seagate ST120FN0"; exit 1; }
DEV="/dev/$(lsblk -no PKNAME "$P1")"
lsblk -dno MODEL "$DEV" | grep -q "$MODEL" || { echo "СТОП: $P1 лежит не на диске $MODEL"; lsblk -o NAME,SIZE,MODEL "$DEV"; exit 1; }
ROOTDISK="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"
[ "$DEV" != "$ROOTDISK" ] || { echo "СТОП: $DEV — диск основной системы"; exit 1; }
if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then echo "СТОП: разделы $DEV смонтированы:"; lsblk "$DEV"; exit 1; fi
NPART="$(lsblk -nro TYPE "$DEV" | grep -c part || true)"
B="$(basename "$DEV")"
[ "$P1" = "${DEV}1" ] || { echo "СТОП: метка u2204-trace не на первом разделе $DEV"; lsblk "$DEV"; exit 1; }
P1_START="$(cat "/sys/block/$B/${B}1/start")"; DISK_SECT="$(cat "/sys/block/$B/size")"
[ "$P1_START" -eq 2048 ] || { echo "СТОП: раздел 1 начинается не с сектора 2048 ($P1_START)"; exit 1; }
P2_START=$((P1_START + P1_SIZE_SECT))
# Повторный запуск после сбоя: разделы уже поделены — пересобираем только раздел 10.04, 22.04 не трогаем
REBUILD=0
if [ "$NPART" -eq 2 ] && [ "$(blkid -s LABEL -o value "${DEV}2" 2>/dev/null)" = "$LABEL2" ] \
   && [ "$(cat "/sys/block/$B/${B}1/size")" -eq "$P1_SIZE_SECT" ]; then
    REBUILD=1
elif [ "$NPART" -eq 1 ]; then
    [ "$(cat "/sys/block/$B/${B}1/size")" -gt "$P1_SIZE_SECT" ] || { echo "СТОП: раздел 1 уже не больше 50 ГиБ"; exit 1; }
    [ $((DISK_SECT - P2_START)) -gt 41943040 ] || { echo "СТОП: под 10.04 остаётся меньше 20 ГиБ"; exit 1; }
else
    echo "СТОП: на $DEV неожиданные разделы:"; lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV"; exit 1
fi

echo "=== Диск записи:"
lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$DEV"
echo "Основная система на $ROOTDISK — не трогается."
if [ "$REBUILD" -eq 0 ]; then
    echo "Будет: копия записей с диска -> ~/Home/nouveau-archive/; раздел 22.04 ужимается до 50 ГиБ (данные остаются);"
    echo "       новый раздел ${DEV}2 ($LABEL2) — Ubuntu 10.04; в меню загрузки этого диска — второй пункт."
    WORD=УЖАТЬ
else
    echo "Раздел ${DEV}2 ($LABEL2) уже есть. Если база 10.04 на нём собрана полностью — продолжу с шага 6,"
    echo "иначе раздел будет стёрт и 10.04 собрана заново. Раздел 22.04 не трогается."
    WORD=ПЕРЕСОБРАТЬ
fi
read -r -p "Продолжить? Напиши $WORD: " ans
[ "$ans" = "$WORD" ] || { echo "Отмена, ничего не сделано."; exit 0; }
export LC_ALL=C LANG=C          # старые программы 2010 года падают на файлах локалей новой системы

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$HOMEDIR/stand-2011"
LOG="$HOMEDIR/stand-2011/build-lucid-$STAMP.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== Начало $(date '+%d.%m %H:%M:%S'), журнал: $LOG"

cleanup() {
    for m in "$MNT2/run" "$MNT2/sys" "$MNT2/proc" "$MNT2/dev/pts" "$MNT2/dev" "$MNT2" \
             "$MNT1/run" "$MNT1/sys" "$MNT1/proc" "$MNT1/dev/pts" "$MNT1/dev" "$MNT1"; do
        mountpoint -q "$m" && umount -l "$m" 2>/dev/null || true
    done
    chown -R "$USER_NAME": "$HOMEDIR/stand-2011" "$HOMEDIR"/nouveau-archive/trace-disk-backup-* 2>/dev/null || true
}
trap cleanup EXIT
# в 10.04 нет /run (появился в 11.10) — подключаем только то, что есть в системе
bind() { for d in dev dev/pts proc sys run; do if [ -d "$1/$d" ]; then mount --bind "/$d" "$1/$d"; fi; done; }
unbind() { for d in run sys proc dev/pts dev; do umount -l "$1/$d" 2>/dev/null || true; done; }
# сразу после копирования рабочий стол на секунды заглядывает в раздел («target is busy») — отмонтируем с повтором
umount_retry() {
    sync
    for i in 1 2 3 4 5 6 7 8 9 10; do umount "$1" 2>/dev/null && return 0; sleep 2; done
    echo "СТОП: $1 не отмонтируется:"; fuser -vm "$1" 2>&1 | head -n 8; return 1
}

if [ "$REBUILD" -eq 0 ]; then
echo "=== 1/7 Копия записей и таблицы разделов"
SAVE="$HOMEDIR/nouveau-archive/trace-disk-backup-$STAMP"
mkdir -p "$SAVE" "$MNT1"
sfdisk --dump "$DEV" > "$SAVE/partition-table.sfdisk"
mount -o ro "$P1" "$MNT1"
df -h "$MNT1" | sed 's/^/   /'
for d in "$MNT1"/home/*/trace; do
    if [ -d "$d" ]; then du -sh "$d" | sed 's/^/   записи: /'; cp -a "$d" "$SAVE/"; fi
done
umount_retry "$MNT1"
chown -R "$USER_NAME": "$SAVE"
echo "   сохранено в $SAVE"

echo "=== 2/7 Ужатие файловой системы 22.04 до $P1_FS"
e2fsck -f -y "$P1" || [ $? -le 1 ]
MINBLK="$(resize2fs -P "$P1" 2>/dev/null | sed -n 's/.*minimum size of the filesystem: *//p')"
BLK="$(dumpe2fs -h "$P1" 2>/dev/null | sed -n 's/^Block size: *//p')"
[ -n "$MINBLK" ] && [ -n "$BLK" ] || { echo "СТОП: не удалось узнать размер данных на 22.04"; exit 1; }
echo "   минимальный размер: $((MINBLK * BLK / 1024 / 1024 / 1024)) ГиБ"
[ $((MINBLK * BLK)) -lt $((40 * 1024 * 1024 * 1024)) ] || { echo "СТОП: данных на 22.04 больше 40 ГиБ, ужимать до 48 нельзя"; exit 1; }
resize2fs "$P1" "$P1_FS"

echo "=== 3/7 Разделы: 1 — 50 ГиБ, 2 — остаток диска"
echo "$P1_START,$P1_SIZE_SECT" | sfdisk --no-reread --no-tell-kernel -W never -N 1 "$DEV"
echo "$P2_START,,83" | sfdisk --no-reread --no-tell-kernel -W never --append "$DEV"
partprobe "$DEV"; udevadm settle; sleep 2
sfdisk -l "$DEV" | sed 's/^/   /'
[ "$(cat "/sys/block/$B/${B}1/size")" -eq "$P1_SIZE_SECT" ] || { echo "СТОП: раздел 1 не того размера"; exit 1; }
[ -b "${DEV}2" ] || { echo "СТОП: раздел ${DEV}2 не появился"; exit 1; }
e2fsck -f -y "$P1" || [ $? -le 1 ]
resize2fs "$P1"                                    # растянуть 48 ГиБ на весь раздел 50 ГиБ
if e2fsck -f -n "$P1" >/dev/null; then echo "   22.04: файловая система в порядке"; else echo "СТОП: e2fsck нашёл ошибки на 22.04"; exit 1; fi
fi
P2="${DEV}2"

# Продолжение после сбоя: база уже собрана (debootstrap закончил — его рабочего каталога нет) — шаги 4–5 пропускаем
BASE_OK=0
if [ "$REBUILD" -eq 1 ]; then
    mkdir -p "$MNT2"; mount "$P2" "$MNT2"
    if [ ! -d "$MNT2/debootstrap" ] && grep -q '^Package: ubuntu-minimal$' "$MNT2/var/lib/dpkg/status" 2>/dev/null; then
        BASE_OK=1; echo "=== База 10.04 уже собрана — продолжаю с шага 6"
    else
        umount_retry "$MNT2"
    fi
fi
if [ "$BASE_OK" -eq 0 ]; then
echo "=== 4/7 Раздел 10.04 (ext3 без новых свойств: старые ядро и e2fsck их не знают)"
mkfs.ext3 -F -q -L "$LABEL2" -O ^metadata_csum,^64bit,^orphan_file,^metadata_csum_seed "$P2"
FEAT="$(dumpe2fs -h "$P2" 2>/dev/null | sed -n 's/^Filesystem features: *//p')"
echo "   свойства: $FEAT"
for f in $FEAT; do
    case "$f" in has_journal|ext_attr|resize_inode|dir_index|filetype|sparse_super|large_file) ;;
        *) echo "СТОП: свойство $f может быть незнакомо 10.04"; exit 1 ;; esac
done
mkdir -p "$MNT2"; mount "$P2" "$MNT2"

echo "=== 5/7 Базовая система 10.04 (несколько минут)"
# setarch --uname-2.6: программы 2010 года видят версию ядра 2.6.x — некоторые старые скрипты не понимают 7.0
setarch x86_64 --uname-2.6 debootstrap --arch amd64 --no-merged-usr \
    --keyring=/usr/share/keyrings/ubuntu-archive-removed-keys.gpg \
    --components=main,restricted,universe lucid "$MNT2" "$MIRROR"
fi
UUID2="$(blkid -s UUID -o value "$P2")"

echo "=== 6/7 Ядро 2.6.32, компилятор, X.Org 1.7 (5–15 минут)"
cat > "$MNT2/etc/apt/sources.list" <<EOF
deb $MIRROR lucid main restricted universe
deb $MIRROR lucid-updates main restricted universe
deb $MIRROR lucid-security main restricted universe
EOF
echo "UUID=$UUID2 / ext3 errors=remount-ro 0 1" > "$MNT2/etc/fstab"
echo "$LABEL2" > "$MNT2/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$LABEL2" > "$MNT2/etc/hosts"
printf 'do_symlinks = yes\nlink_in_boot = no\ndo_bootloader = no\ndo_initrd = yes\n' > "$MNT2/etc/kernel-img.conf"
cp /etc/resolv.conf "$MNT2/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$MNT2/usr/sbin/policy-rc.d"; chmod 755 "$MNT2/usr/sbin/policy-rc.d"
bind "$MNT2"
CH2() { setarch x86_64 --uname-2.6 chroot "$MNT2" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C DEBIAN_FRONTEND=noninteractive HOME=/root "$@"; }
CH2 dpkg-divert --local --rename --add /sbin/initctl >/dev/null
ln -sf /bin/true "$MNT2/sbin/initctl"
CH2 apt-get update -q
CH2 apt-get install -y -q --no-install-recommends linux-image-generic linux-headers-generic build-essential \
    xserver-xorg-core xserver-xorg-input-evdev xinit xterm x11-xserver-utils mesa-utils libgtk2.0-0 \
    pciutils less mingetty python python3 console-setup sudo locales
CH2 locale-gen en_US.UTF-8 ru_RU.UTF-8 >/dev/null || echo "   (locale-gen с ошибкой — не критично)"

echo "=== 7/7 Пользователь, автовход, без сети, без nouveau; пункт в меню загрузки диска"
CH2 /bin/bash -e <<EOS
id $USER_NAME >/dev/null 2>&1 || useradd -m -s /bin/bash -G adm,sudo,video,audio $USER_NAME
passwd -d $USER_NAME >/dev/null
grep -q '^#includedir /etc/sudoers.d' /etc/sudoers || echo '#includedir /etc/sudoers.d' >> /etc/sudoers
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USER_NAME; chmod 440 /etc/sudoers.d/90-$USER_NAME
[ -f /etc/init/tty1.conf ] && sed -i 's|^exec /sbin/getty.*tty1\$|exec /sbin/mingetty --autologin $USER_NAME tty1|' /etc/init/tty1.conf
printf 'blacklist nouveau\noptions nouveau modeset=0\nblacklist r8169\nblacklist nvidia\n' > /etc/modprobe.d/stand-2011.conf
[ -f /etc/default/console-setup ] && sed -i 's/^CODESET=.*/CODESET="CyrSlav"/; s/^FONTFACE=.*/FONTFACE="Fixed"/; s/^FONTSIZE=.*/FONTSIZE="8x16"/' /etc/default/console-setup
update-initramfs -u -k all >/dev/null
EOS
rm -f "$MNT2/sbin/initctl"; CH2 dpkg-divert --local --rename --remove /sbin/initctl >/dev/null
rm -f "$MNT2/usr/sbin/policy-rc.d" "$MNT2/etc/resolv.conf"
KV="$(ls "$MNT2/lib/modules" | sort -V | tail -n 1)"
mkdir -p "$MNT2/home/$USER_NAME/trace"; CH2 chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME"
grep -q "mingetty --autologin" "$MNT2/etc/init/tty1.conf" || echo "   !!! автовход не настроен (tty1.conf)"

# Пункт меню — в загрузчике 22.04 на этом же диске (GRUB 2.06 читает ext3 и грузит ядро 2.6.32)
mkdir -p "$MNT1"; mount "$P1" "$MNT1"; bind "$MNT1"
cat > "$MNT1/etc/grub.d/41_lucid-stand" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'Ubuntu 10.04, kernel 2.6.32 (NVIDIA 270 stand)' {
	insmod part_msdos
	insmod ext2
	search --no-floppy --fs-uuid --set=root $UUID2
	linux /boot/vmlinuz-$KV root=UUID=$UUID2 ro
	initrd /boot/initrd.img-$KV
}
EOF
chmod 755 "$MNT1/etc/grub.d/41_lucid-stand"
chroot "$MNT1" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C HOME=/root update-grub 2>&1 | tail -n 3
grep -q "NVIDIA 270 stand" "$MNT1/boot/grub/grub.cfg" && echo "   пункт меню добавлен" || echo "   !!! пункта нет в grub.cfg"
unbind "$MNT1"; umount_retry "$MNT1"

echo "=== Проверки"
echo "   ядро 10.04: $KV"
grep -E '^CONFIG_MMIOTRACE=' "$MNT2/boot/config-$KV" | sed 's/^/   /' || echo "   !!! в ядре нет MMIOTRACE"
ls "$MNT2/boot/initrd.img-$KV" >/dev/null && echo "   стартовый образ есть" || echo "   !!! нет initrd"
ls -d "$MNT2/usr/src/linux-headers-$KV" >/dev/null && echo "   заголовки ядра есть" || echo "   !!! нет заголовков ядра"
CH2 gcc --version | sed -n '1s/^/   /p'
CH2 dpkg -l xserver-xorg-core | awk '/^ii/{print "   X.Org: "$3}'
df -h "$MNT2" | tail -n 1 | sed 's/^/   10.04: /'
sync
unbind "$MNT2"; umount_retry "$MNT2"
echo "=== Готово $(date '+%d.%m %H:%M:%S'). Дальше: перезагрузка, F12, ST120FN0, в меню — второй пункт (Ubuntu 10.04)."
