#!/bin/bash
# Ставит в Ubuntu 10.04 (раздел u1004-trace) ядро 2.6.35-32 из обновлений самой 10.04 (бэкпорт ядра Ubuntu 10.10) рядом
# с родным 2.6.32. Зачем (docs/2026-10-27/stand-2011-first-night.md, раздел 3): запись mmiotrace на 2.6.32 четыре раза
# вешала систему на запуске X; в 2.6.32 нет исправления 8b8f79b9 «kmmio/mmiotrace: Fix double free of kmmio_fault_pages»
# (июнь 2010), в 2.6.35-32 оно есть; запись (CONFIG_MMIOTRACE) и вытеснение те же.
# Заодно стенд возвращается к условиям попытки 26.10 21:59 (без NVreg_EnableMSI) — ядро остаётся единственным отличием.
# Пакеты (~46 МБ) качает основная система с old-releases.ubuntu.com через apt самой 10.04 (он же проверяет подпись
# архива); в работающей 10.04 сети по-прежнему нет. Драйвер NVIDIA под новое ядро собирается потом в 10.04 (nv2).
# Дальше: sudo ~/Home/nouveau-fix/trace/lucid-boot-entries.sh (пункт меню), в 10.04 — nv2, перезагрузка, rec1.
# Запуск в основной системе: sudo ~/Home/nouveau-fix/trace/lucid-kernel.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
KV=2.6.35-32-generic
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

echo "=== Ядра в 10.04 сейчас: $(ls "$MNT/lib/modules" | tr '\n' ' ')"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"; chmod 755 "$MNT/usr/sbin/policy-rc.d"
for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done
CH2() { setarch x86_64 --uname-2.6 chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C DEBIAN_FRONTEND=noninteractive HOME=/root "$@"; }
CH2 dpkg-divert --local --rename --add /sbin/initctl >/dev/null
ln -sf /bin/true "$MNT/sbin/initctl"

echo "=== Ядро $KV с заголовками (из lucid-updates)"
CH2 apt-get update -q
CH2 apt-get install -y -q --no-install-recommends "linux-image-$KV" "linux-headers-$KV"

echo "=== Без NVreg_EnableMSI — как в попытке 26.10 21:59"
sed -i '/NVreg_EnableMSI/d' "$MNT/etc/modprobe.d/stand-2011.conf"
sed 's/^/   /' "$MNT/etc/modprobe.d/stand-2011.conf"

echo "=== Проверки"
ls -l "$MNT/boot/vmlinuz-$KV" "$MNT/boot/initrd.img-$KV" | sed 's/^/   /'
grep -E '^CONFIG_MMIOTRACE=|^CONFIG_PREEMPT_VOLUNTARY=' "$MNT/boot/config-$KV" | sed 's/^/   /'
ls -d "$MNT/usr/src/linux-headers-$KV" | sed 's/^/   заголовки: /'
echo "=== Ядра в 10.04 теперь: $(ls "$MNT/lib/modules" | tr '\n' ' ')"
echo "=== Готово. Дальше: sudo ~/Home/nouveau-fix/trace/lucid-boot-entries.sh"
