#!/bin/bash
# Собирает для Ubuntu 10.04 (раздел u1004-trace) образ ядра 2.6.32-74-generic с ОДНИМ исправлением записи mmiotrace —
# коммит Linux 8b8f79b9 «x86, kmmio/mmiotrace: Fix double free of kmmio_fault_pages» (только arch/x86/mm/kmmio.c,
# trace/patches/kmmio-double-free-8b8f79b9.patch). Зачем — docs/2026-10-27/stand-2011-first-night.md, разделы 8–10:
# на родном 2.6.32 контроль 270.41.06 работает, а запись падает на этой ошибке; на 2.6.35 запись исправна, но 270.41.06
# виснет и без записи (и с nointremap).
# Исходники — пакет Ubuntu linux-source-2.6.32 той же версии, что стоит (2.6.32-74.142; ~67 МБ с old-releases, подпись
# архива проверяет apt 10.04); конфиг — /boot/config-2.6.32-74-generic; компилятор — gcc 4.4 самой 10.04 (в chroot).
# Собирается только образ ядра с той же версией 2.6.32-74-generic: родные модули, стартовый образ и драйвер NVIDIA,
# собранный под 2.6.32-74-generic, подходят к обоим образам. Результат — /boot/vmlinuz-2.6.32-74-generic-kmmiofix рядом
# с родным, родное ядро не трогается. Имя машины в образе — u1004-trace (сборка в отдельном пространстве имён UTS),
# имя основной машины туда не попадает.
# Дальше: sudo ~/Home/nouveau-fix/trace/lucid-boot-entries.sh (пункт меню), в 10.04 — nv2, перезагрузка, rec.
# Запуск в основной системе: sudo ~/Home/nouveau-fix/trace/lucid-kmmio-kernel.sh   (10–25 минут)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/patches/kmmio-double-free-8b8f79b9.patch"
KV=2.6.32-74-generic
DEBVER=2.6.32-74.142
B=/usr/src/kmmiofix                # каталог сборки внутри 10.04
OUT=/boot/vmlinuz-$KV-kmmiofix
for c in unshare patch tar bzip2; do command -v "$c" >/dev/null || { echo "Нет программы $c"; exit 1; }; done
[ -f "$PATCH" ] || { echo "Нет $PATCH"; exit 1; }
P2="$(blkid -L u1004-trace 2>/dev/null)" || { echo "Раздел u1004-trace не найден — подключи Seagate ST120FN0"; exit 1; }
lsblk -dno MODEL "/dev/$(lsblk -no PKNAME "$P2")" | grep -q ST120FN0 || { echo "СТОП: раздел не на диске ST120FN0"; exit 1; }
if findmnt -rn -S "$P2" >/dev/null; then echo "СТОП: $P2 смонтирован — отключи его"; exit 1; fi
MNT=/mnt/u1004-trace; mkdir -p "$MNT"
export LC_ALL=C LANG=C          # старые программы 2010 года падают на файлах локалей новой системы
umount_retry() { sync; for i in 1 2 3 4 5 6 7 8 9 10; do umount "$1" 2>/dev/null && return 0; sleep 2; done; echo "!!! $1 не отмонтировался"; return 1; }
cleanup() {
    rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/etc/resolv.conf"
    if [ -L "$MNT/sbin/initctl" ]; then rm -f "$MNT/sbin/initctl"; chroot "$MNT" dpkg-divert --local --rename --remove /sbin/initctl >/dev/null 2>&1 || true; fi
    for d in sys proc dev/pts dev; do umount -l "$MNT/$d" 2>/dev/null || true; done
    mountpoint -q "$MNT" && umount_retry "$MNT"
    true
}
mount "$P2" "$MNT"
trap cleanup EXIT
grep -q 'Ubuntu 10.04' "$MNT/etc/issue" || { echo "СТОП: на разделе не Ubuntu 10.04"; exit 1; }
[ -f "$MNT/boot/config-$KV" ] || { echo "СТОП: нет /boot/config-$KV в 10.04"; exit 1; }

cp /etc/resolv.conf "$MNT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"; chmod 755 "$MNT/usr/sbin/policy-rc.d"
for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done
CH2() { setarch x86_64 --uname-2.6 chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C DEBIAN_FRONTEND=noninteractive HOME=/root "$@"; }
# сборка — в своём пространстве имён UTS с именем u1004-trace: 2.6.32 вшивает в образ имя машины (hostname)
CHB() { unshare --uts /bin/sh -c 'hostname u1004-trace && exec "$@"' sh \
        setarch x86_64 --uname-2.6 chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C HOME=/root "$@"; }
CH2 dpkg-divert --local --rename --add /sbin/initctl >/dev/null
ln -sf /bin/true "$MNT/sbin/initctl"

echo "=== 1/4 Исходники ядра Ubuntu $DEBVER (linux-source-2.6.32)"
CH2 apt-get update -q
CH2 apt-get install -y -q --no-install-recommends linux-source-2.6.32
IMGVER="$(CH2 dpkg-query -W -f='${Version}' linux-image-$KV)"
SRCVER="$(CH2 dpkg-query -W -f='${Version}' linux-source-2.6.32)"
echo "   установленное ядро: $IMGVER; исходники: $SRCVER"
[ "$IMGVER" = "$DEBVER" ] && [ "$SRCVER" = "$DEBVER" ] || { echo "СТОП: версии не совпадают с $DEBVER"; exit 1; }

echo "=== 2/4 Распаковка и исправление 8b8f79b9 (только arch/x86/mm/kmmio.c)"
rm -rf "$MNT$B"; mkdir -p "$MNT$B"
tar -xjf "$MNT/usr/src/linux-source-2.6.32.tar.bz2" -C "$MNT$B"
S="$B/linux-source-2.6.32"
[ -d "$MNT$S" ] || { echo "СТОП: в архиве нет linux-source-2.6.32/"; ls "$MNT$B"; exit 1; }
patch -d "$MNT$S" -p1 < "$PATCH"
grep -c scheduled_for_release "$MNT$S/arch/x86/mm/kmmio.c" | sed 's/^/   scheduled_for_release в kmmio.c: /'
cp "$MNT/boot/config-$KV" "$MNT$S/.config"

echo "=== 3/4 Сборка образа ядра (gcc 10.04, $(nproc) потоков; 5–20 минут)"
MK="make -C $S EXTRAVERSION=-74 LOCALVERSION=-generic"
CHB $MK silentoldconfig < /dev/null > /dev/null
# в 2.6.32 «make kernelrelease» работает только после подготовки — генерируем файл версии и читаем его
CHB $MK include/config/kernel.release > /dev/null
REL="$(cat "$MNT$S/include/config/kernel.release")"
[ "$REL" = "$KV" ] || { echo "СТОП: версия сборки «$REL», а нужна $KV"; exit 1; }
cmp -s "$MNT/boot/config-$KV" "$MNT$S/.config" && echo "   конфиг совпадает с родным" || { echo "   !!! конфиг после silentoldconfig отличается:"; diff "$MNT/boot/config-$KV" "$MNT$S/.config" | head -20; }
CHB $MK -j"$(nproc)" bzImage 2>&1 | grep -E "error|Error|warning: .*kmmio|Kernel: arch" || true
[ -f "$MNT$S/arch/x86/boot/bzImage" ] || { echo "СТОП: образ не собрался"; exit 1; }

echo "=== 4/4 Установка рядом с родным: $OUT"
cp "$MNT$S/arch/x86/boot/bzImage" "$MNT$OUT"
cp "$MNT$S/System.map" "$MNT/boot/System.map-$KV-kmmiofix"
ls -l "$MNT/boot/vmlinuz-$KV" "$MNT$OUT" | sed 's/^/   /'
file -b "$MNT$OUT" | cut -c1-120 | sed 's/^/   /'
echo "=== Готово. Дальше: sudo ~/Home/nouveau-fix/trace/lucid-boot-entries.sh"
