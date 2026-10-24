#!/bin/bash
# Обновить сценарий записи на уже собранном диске системы u2204-trace (Seagate ST120FN0, метка u2204-trace):
# скопировать run-trace.sh (версия 3) и regdump4.py. Старые скрипты с диска сначала сохраняются в
# ~/Home/nouveau-archive/trace-disk-scripts/ (на диске может лежать первая версия run-trace.sh).
# Диск должен быть подключён. Запуск в основной системе: sudo ~/Home/nouveau-fix/trace/update-trace-disk.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="$(blkid -L u2204-trace 2>/dev/null)" || { echo "Диск записи (метка u2204-trace) не найден — подключи Seagate ST120FN0"; exit 1; }
MNT=/mnt/u2204-trace; mkdir -p "$MNT"
mountpoint -q "$MNT" && { echo "$MNT уже смонтирован — отмонтируй: sudo umount $MNT"; exit 1; }
mount "$DEV" "$MNT"
trap 'sync; umount "$MNT"' EXIT
D="$(ls -d "$MNT"/home/*/trace 2>/dev/null | head -n 1)"
[ -n "$D" ] || { echo "На диске нет каталога home/*/trace"; exit 1; }
SAVE="$(dirname "$HERE")/../nouveau-archive/trace-disk-scripts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SAVE"
echo "=== Что лежит на диске сейчас ($D):"
ls -la "$D"
cp -p "$D"/*.sh "$D"/*.py "$SAVE/" 2>/dev/null || true
chown -R "$(stat -c %U "$HERE")": "$SAVE"
echo "=== Старые скрипты сохранены: $SAVE"
OWNER="$(stat -c %u:%g "$D")"
install -m 0755 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$HERE/run-trace.sh" "$HERE/regdump4.py" "$D/"
echo "=== Скопировано на диск:"
md5sum "$D/run-trace.sh" "$D/regdump4.py" "$HERE/run-trace.sh" "$HERE/regdump4.py" | sed 's/^/   /'
grep -m1 "версия сценария" "$D/run-trace.sh" | sed 's/^/   /'
echo "=== Готово. Дальше: перезагрузка, F12, диск ST120FN0, там: sudo ~/trace/run-trace.sh"
