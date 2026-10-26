#!/bin/bash
# Обмен файлами с Ubuntu 10.04 на диске записи (раздел u1004-trace), из основной системы. В 10.04 сети нет — всё носим так.
#   put — положить в ~/trace/ системы 10.04: сценарий записи, снимок регистров, установку драйвера, шаги, установщики
#         NVIDIA 270.x из ~/Home/stand-2011/nvidia/ (каждый сверяется с SHA256-local.txt, записанным при скачивании);
#   get — забрать (только чтение раздела) записи out-*, журналы установки драйвера и системные журналы 10.04
#         в ~/Home/stand-2011/results/; запись mmiotrace сжимается в копии, на диске 10.04 ничего не меняется.
# Запуск: sudo ~/Home/nouveau-fix/trace/lucid-disk.sh put    (или get)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAND="$(cd "$HERE/../.." && pwd)/stand-2011"
USER_NAME="${SUDO_USER:-}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "Запусти через sudo из своей учётной записи"; exit 1; }
MODE="${1:-}"; [ "$MODE" = put ] || [ "$MODE" = get ] || { echo "Укажи put или get"; exit 1; }
P2="$(blkid -L u1004-trace 2>/dev/null)" || { echo "Раздел u1004-trace не найден — подключи Seagate ST120FN0"; exit 1; }
MNT=/mnt/u1004-trace; mkdir -p "$MNT"
mountpoint -q "$MNT" && { echo "$MNT уже смонтирован — отмонтируй: sudo umount $MNT"; exit 1; }
findmnt -rn -S "$P2" >/dev/null && { echo "$P2 смонтирован (файловый менеджер?) — отключи его и запусти снова"; exit 1; }
if [ "$MODE" = put ]; then mount "$P2" "$MNT"; else mount -o ro "$P2" "$MNT"; fi
# сразу после копирования рабочий стол на секунды заглядывает в раздел («target is busy») — отмонтируем с повтором
trap 'sync; for i in 1 2 3 4 5 6 7 8 9 10; do umount "$MNT" 2>/dev/null && { echo "=== Раздел 10.04 отмонтирован"; break; }; sleep 2; done; mountpoint -q "$MNT" && echo "!!! Раздел не отмонтировался: sudo umount $MNT"' EXIT
D="$(ls -d "$MNT"/home/*/trace 2>/dev/null | head -n 1)"
[ -n "$D" ] || { echo "На разделе нет каталога home/*/trace"; exit 1; }
OWNER="$(stat -c %u:%g "$D")"

if [ "$MODE" = put ]; then
    install -m 0755 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$HERE/run-trace-lucid.sh" "$HERE/install-nvidia-lucid.sh" "$D/"
    # без автозапуска меню: как в первый удачный раз — обычная командная строка (меню 26.10 21:16 убрано)
    rm -f "$(dirname "$D")/.bash_profile" "$D/stand-menu-lucid.sh"
    # короткие команды для набора руками в 10.04: nv1 / nv2 — установить 270.26 / 270.41.06, rec — запись
    printf '#!/bin/sh\nexec sudo %s/install-nvidia-lucid.sh 270.26\n' "${D#$MNT}" > "$MNT/usr/local/bin/nv1"
    printf '#!/bin/sh\nexec sudo %s/install-nvidia-lucid.sh 270.41.06\n' "${D#$MNT}" > "$MNT/usr/local/bin/nv2"
    printf '#!/bin/sh\nexec sudo %s/run-trace-lucid.sh\n' "${D#$MNT}" > "$MNT/usr/local/bin/rec"
    printf '#!/bin/sh\nexec sudo %s/run-trace-lucid.sh only\n' "${D#$MNT}" > "$MNT/usr/local/bin/rec1"
    chmod 755 "$MNT/usr/local/bin/nv1" "$MNT/usr/local/bin/nv2" "$MNT/usr/local/bin/rec" "$MNT/usr/local/bin/rec1"
    echo "=== Короткие команды в 10.04:"
    for c in nv1 nv2 rec rec1; do echo "   $c -> $(sed -n 2p "$MNT/usr/local/bin/$c")"; done
    install -m 0644 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$HERE/regdump-lucid.py" "$HERE/ШАГИ-10.04.txt" "$D/"
    install -d -o "${OWNER%%:*}" -g "${OWNER##*:}" "$D/nvidia"
    (cd "$STAND/nvidia" && sha256sum -c SHA256-local.txt) | sed 's/^/   /'
    for f in "$STAND"/nvidia/NVIDIA-Linux-x86_64-*.run; do
        cmp -s "$f" "$D/nvidia/$(basename "$f")" || install -m 0644 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$f" "$D/nvidia/"
    done
    echo "=== На диске 10.04 ($D):"
    ls -l "$D" "$D/nvidia" | sed 's/^/   /'
    for f in run-trace-lucid.sh install-nvidia-lucid.sh regdump-lucid.py; do
        if cmp -s "$HERE/$f" "$D/$f"; then echo "   $f — совпадает с репозиторием"; else echo "   !!! $f не совпадает"; fi
    done
    P1="$(blkid -L u2204-trace 2>/dev/null || true)"; M1=/mnt/u2204-trace
    if [ -n "$P1" ] && ! findmnt -rn -S "$P1" >/dev/null && mkdir -p "$M1" && mount -o ro "$P1" "$M1"; then
        echo "=== Меню загрузки диска (по порядку):"
        grep -E "^(menuentry|submenu) " "$M1/boot/grub/grub.cfg" | sed "s/^\(menuentry\|submenu\) '\([^']*\)'.*/   \2/" | nl -w4
        sync; for i in 1 2 3 4 5; do umount "$M1" 2>/dev/null && break; sleep 2; done
    fi
    echo "=== Готово. Дальше: перезагрузка, F12, ST120FN0, в меню — Ubuntu 10.04; шаги — в ~/trace/ШАГИ-10.04.txt"
else
    SAVE="$STAND/results"; mkdir -p "$SAVE"
    for o in "$D"/out-*; do
        [ -d "$o" ] || continue
        n="$(basename "$o")"
        if [ -d "$SAVE/$n" ]; then echo "   $n — уже забрана"; continue; fi
        cp -a "$o" "$SAVE/$n"
        [ -f "$SAVE/$n/mmiotrace.txt" ] && xz -T0 -6 "$SAVE/$n/mmiotrace.txt"
        echo "   забрана: $n"
    done
    L="$SAVE/lucid-logs-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$L"
    cp -a "$D"/install-*.log "$L/" 2>/dev/null || true
    ls -laR "$D" > "$L/trace-dir-listing.txt" 2>&1 || true
    cp -a "$MNT/etc/default/console-setup" "$L/" 2>/dev/null || true
    cp -a "$MNT/root/.bash_history" "$L/root.bash_history" 2>/dev/null || true
    cp -a "$(dirname "$D")/.bash_history" "$L/user.bash_history" 2>/dev/null || true
    for f in syslog kern.log dmesg Xorg.0.log Xorg.0.log.old nvidia-installer.log boot.log; do
        cp -a "$MNT/var/log/$f" "$L/" 2>/dev/null || true
    done
    chown -R "$USER_NAME": "$SAVE"
    echo "=== Забрано в $SAVE:"
    ls -l "$SAVE" "$L" | sed 's/^/   /'
fi
