#!/bin/bash
# ЗАКРЕПИТЬ ЯДРО В GRUB (28.10): по умолчанию грузится только то ядро, под которое собран наш драйвер. Новое ядро после
# apt остаётся в меню («Advanced options»), но само не загрузится, пока его не закрепить этим же скриптом — обычно это
# делают newkernel.sh и lab/lab.sh install после удачной сборки. Повод: 28.10 `apt upgrade` ради Клода притянул ядро
# 7.0.0-42, GRUB_DEFAULT=0 загрузил его со штатным nouveau — два зависания Chromium (гонка без патча 0001).
#   daily/grub-pin.sh status      — что закреплено, какие ядра стоят и под какие собран драйвер (без пароля)
#   daily/grub-pin.sh <ядро>      — закрепить ядро (пароль): один раз GRUB_DEFAULT=saved + update-grub, затем grub-set-default
#   daily/grub-pin.sh current     — закрепить работающее ядро
#   daily/grub-pin.sh off         — снять закрепление (GRUB_DEFAULT=0: грузится самое новое, как в Ubuntu по умолчанию)
set -uo pipefail
drv() {  # какой наш драйвер собран под ядро $1 (пусто — никакого)
    [ -e "/lib/modules/$1/updates/nouveau-fix/nouveau.ko" ] && { echo "лабораторный"; return; }
    [ -e "/lib/modules/$1/updates/dkms/nouveau.ko" ] && { echo "стабильный (DKMS)"; return; }
    echo ""
}
case "${1:-status}" in
status)
    echo "работает: $(uname -r)"
    SAVED="$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')"
    echo "закреплено: ${SAVED:-— ($(grep -E '^GRUB_DEFAULT=' /etc/default/grub): грузится самое новое ядро)}"
    for k in $(ls -1 /lib/modules | sort -V); do d="$(drv "$k")"; printf '  %-22s %s\n' "$k" "${d:-БЕЗ НАШЕГО ДРАЙВЕРА (штатный nouveau: гонка в Chromium)}"; done
    ls /var/lib/nouveau-fix/pending-* 2>/dev/null | sed 's|.*/pending-|ждёт сборки драйвера: |'
    ;;
off)
    sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub && sudo update-grub && echo "закрепление снято: грузится самое новое ядро"
    ;;
*)
    K="$1"; [ "$K" = current ] && K="$(uname -r)"
    [ -d "/lib/modules/$K" ] || { echo "ядра $K нет в /lib/modules"; exit 1; }
    d="$(drv "$K")"
    [ -n "$d" ] || { echo "под $K наш драйвер не собран — закреплять нечего (сначала newkernel.sh или lab/lab.sh install)"; exit 1; }
    if ! grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub; then
        sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub && sudo update-grub || exit 1
    fi
    # идентификаторы пунктов берём из самого grub.cfg, а не угадываем по UUID
    ENTRY="$(sudo grep -oE "gnulinux-$K-advanced-[0-9A-Za-z-]+" /boot/grub/grub.cfg | head -n 1)"
    SUB="$(sudo grep -oE "gnulinux-advanced-[0-9A-Za-z-]+" /boot/grub/grub.cfg | head -n 1)"
    [ -n "$ENTRY" ] || { echo "в /boot/grub/grub.cfg нет пункта для $K (нужен update-grub?)"; exit 1; }
    ID="${SUB:+$SUB>}$ENTRY"
    sudo grub-set-default "$ID" && echo "закреплено: $K ($d) — $ID"
    sudo rm -f "/var/lib/nouveau-fix/pending-$K" 2>/dev/null || true   # драйвер собран и ядро закреплено — отметка «ждёт сборки» снята
    ;;
esac
