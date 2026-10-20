#!/bin/bash
# Установка / удаление службы автоматических режимов карты.
#   ~/nouveau-fix/daily/autoclock.sh install   — поставить и запустить (пароль)
#   ~/nouveau-fix/daily/autoclock.sh remove    — остановить и удалить; карта остаётся в текущем режиме до перезагрузки
#   ~/nouveau-fix/daily/autoclock.sh status    — состояние и последние переключения
#   ~/nouveau-fix/daily/autoclock.sh watch     — смотреть переключения вживую (Ctrl+C — выход)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
install)
    sudo install -m 0755 "$HERE/gpu-autoclock.py" /usr/local/sbin/gpu-autoclock.py
    sudo install -m 0644 "$HERE/gpu-autoclock.service" /etc/systemd/system/gpu-autoclock.service
    sudo systemctl daemon-reload
    sudo systemctl enable gpu-autoclock.service
    sudo systemctl restart gpu-autoclock.service
    sleep 3; systemctl --no-pager status gpu-autoclock.service | head -n 12 ;;
remove)
    sudo systemctl disable --now gpu-autoclock.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/gpu-autoclock.service /usr/local/sbin/gpu-autoclock.py
    sudo systemctl daemon-reload
    echo "Служба удалена. Карта в текущем режиме до перезагрузки." ;;
status)
    systemctl --no-pager status gpu-autoclock.service | head -n 5 || true
    journalctl -u gpu-autoclock.service -b 0 --no-pager | tail -n 20 ;;
watch)
    journalctl -u gpu-autoclock.service -f --no-pager ;;
*)
    sed -n '2,6p' "$0"; exit 1 ;;
esac
