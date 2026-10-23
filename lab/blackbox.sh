#!/bin/bash
# «ЧЁРНЫЙ ЯЩИК» (см. blackbox.py): служба, пишущая состояние карты раз в секунду на диск с fsync (переживает Reset).
#   blackbox.sh install — поставить и запустить (пароль); также поднимает уровень консоли ядра, чтобы строки
#                         драйвера (nvkm_info) попадали в console-ramoops, а не только ошибки
#   blackbox.sh show [N] — последние N (60) строк ящика, снимки по зависанию hang-*.txt, консоль ядра из ramoops
#   blackbox.sh remove  — убрать
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"
UNIT=/etc/systemd/system/gpu-blackbox.service; BIN=/usr/local/sbin/gpu-blackbox.py
case "${1:-}" in
install)
    grep -q ramoops.mem_address /proc/cmdline || echo "⚠ ramoops не включён (lab/trap.sh on) — консоль ядра после Reset не сохранится, ящик на диске будет"
    sudo install -m 0755 "$HERE/blackbox.py" "$BIN"
    sudo tee "$UNIT" >/dev/null <<EOU
[Unit]
Description=GPU black box: card state once a second into ramoops pmsg (~/Home/nouveau-fix/lab/blackbox.sh)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOU
    # уровень консоли 7: nvkm_info драйвера попадает в console-ramoops (при quiet туда идут только ошибки)
    echo 'kernel.printk = 7 4 1 7' | sudo tee /etc/sysctl.d/90-gpu-blackbox.conf >/dev/null
    sudo sysctl -q -p /etc/sysctl.d/90-gpu-blackbox.conf
    sudo systemctl daemon-reload && sudo systemctl enable gpu-blackbox.service && sudo systemctl restart gpu-blackbox.service
    sleep 2; systemctl --no-pager status gpu-blackbox.service | sed -n 1,3p
    echo "=== Чёрный ящик пишет в /var/log/gpu-blackbox/current.txt. После зависания и Reset: bash ~/Home/nouveau-fix/lab/blackbox.sh show"
    ;;
show)
    echo "=== ящик (диск), последние ${2:-60} строк:"; sudo tail -n "${2:-60}" /var/log/gpu-blackbox/current.txt 2>/dev/null | cut -c1-230
    for f in $(sudo ls -1t /var/log/gpu-blackbox/hang-*.txt 2>/dev/null | head -3); do echo "=== снимок по зависанию $f:"; sudo cat "$f" | cut -c1-230; done
    for d in /sys/fs/pstore /var/lib/systemd/pstore; do
        for f in $(sudo ls -1 "$d" 2>/dev/null | grep -E "pmsg|console"); do
            echo "=== $d/$f ($(sudo wc -l < "$d/$f") строк) — последние 40:"; sudo tail -n 40 "$d/$f" | cut -c1-220
        done
    done
    [ -z "$(sudo ls -A /sys/fs/pstore /var/lib/systemd/pstore 2>/dev/null)" ] && echo "В pstore пусто: либо не было зависания с прошлой перезагрузки, либо память не сохранилась после Reset"
    ;;
remove)
    sudo systemctl disable --now gpu-blackbox.service 2>/dev/null; sudo rm -f "$UNIT" "$BIN" /etc/sysctl.d/90-gpu-blackbox.conf
    sudo sysctl -q -w kernel.printk="4 4 1 7"; sudo systemctl daemon-reload; echo "Чёрный ящик убран" ;;
*) sed -n '2,6p' "$0"; exit 1 ;;
esac
