#!/bin/bash
# НОВОЕ ЯДРО: убедиться, что под него собран наш драйвер — ДО перезагрузки.
#   ~/Home/nouveau-fix/newkernel.sh                  — самое новое установленное ядро
#   ~/Home/nouveau-fix/newkernel.sh 7.0.0-40-generic — конкретное ядро
# Стабильный драйвер (DKMS) обычно собирается сам при установке ядра; этот скрипт проверяет и при необходимости
# досабирает. Для лабораторного драйвера — отдельно: KVER=<ядро> ~/Home/nouveau-fix/lab/lab.sh install
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="${1:-$(ls -1 /lib/modules | sort -V | tail -n 1)}"
echo "=== Ядро: $KVER (сейчас работает $(uname -r))"
[ -d "/lib/modules/$KVER" ] || { echo "Ядро $KVER не установлено."; exit 1; }
[ -e "/lib/modules/$KVER/build/Makefile" ] || { echo "Нет заголовков ядра $KVER. Поставь: sudo apt install linux-headers-$KVER"; exit 1; }
if [ -e "/lib/modules/$(uname -r)/updates/nouveau-fix/nouveau.ko" ] || [ -e /sys/module/nouveau/parameters/lab_core ]; then
    # 28.10: на этом ядре стоит ЛАБОРАТОРНЫЙ драйвер — собрать такой же под новое ядро (lab.sh сам закрепит его в GRUB)
    if [ -e "/lib/modules/$KVER/updates/nouveau-fix/nouveau.ko" ]; then
        echo "=== Лабораторный драйвер для $KVER уже собран ✅: $(modinfo -k "$KVER" -n nouveau)"
    else
        echo "=== Лабораторный драйвер под $KVER — собираю: KVER=$KVER lab/lab.sh install (пароль)"
        KVER="$KVER" bash "$HERE/lab/lab.sh" install || exit 1
    fi
elif command -v dkms >/dev/null && dkms status nouveau-gf114/1.0 2>/dev/null | grep -q .; then
    if dkms status nouveau-gf114/1.0 -k "$KVER" | grep -q installed; then
        echo "=== Стабильный драйвер для $KVER уже собран DKMS ✅: $(modinfo -k "$KVER" -n nouveau)"
    else
        echo "=== DKMS ещё не собрал стабильный драйвер для $KVER — собираю (пароль)"
        "$HERE/stable/stable.sh" build "$KVER"
    fi
else
    echo "=== Стабильный драйвер через DKMS не установлен. Поставить: bash ~/Home/nouveau-fix/stable/stable.sh install"
    echo "    (старый путь — стабильный-0001 + лабораторный: ~/Home/nouveau-fix/rebuild.sh и lab/lab.sh install)"
    exit 1
fi
sudo rm -f "/var/lib/nouveau-fix/pending-$KVER" 2>/dev/null || true
"$HERE/daily/grub-pin.sh" "$KVER" || echo "--- Закрепить ядро в GRUB не удалось: daily/grub-pin.sh status"
echo "Перезагрузись. После неё: daily/check-driver.sh (или stable/stable.sh status)"
