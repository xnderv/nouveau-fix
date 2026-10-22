#!/bin/bash
# НОВОЕ ЯДРО: убедиться, что под него собран наш драйвер — ДО перезагрузки.
#   ~/nouveau-fix/newkernel.sh                  — самое новое установленное ядро
#   ~/nouveau-fix/newkernel.sh 7.0.0-40-generic — конкретное ядро
# Стабильный драйвер (DKMS) обычно собирается сам при установке ядра; этот скрипт проверяет и при необходимости
# досабирает. Для лабораторного драйвера — отдельно: KVER=<ядро> ~/nouveau-fix/lab/lab.sh install
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="${1:-$(ls -1 /lib/modules | sort -V | tail -n 1)}"
echo "=== Ядро: $KVER (сейчас работает $(uname -r))"
[ -d "/lib/modules/$KVER" ] || { echo "Ядро $KVER не установлено."; exit 1; }
[ -e "/lib/modules/$KVER/build/Makefile" ] || { echo "Нет заголовков ядра $KVER. Поставь: sudo apt install linux-headers-$KVER"; exit 1; }
if command -v dkms >/dev/null && dkms status nouveau-gf114/1.0 2>/dev/null | grep -q .; then
    if dkms status nouveau-gf114/1.0 -k "$KVER" | grep -q installed; then
        echo "=== Стабильный драйвер для $KVER уже собран DKMS ✅: $(modinfo -k "$KVER" -n nouveau)"
    else
        echo "=== DKMS ещё не собрал стабильный драйвер для $KVER — собираю (пароль)"
        "$HERE/stable/stable.sh" build "$KVER"
    fi
else
    echo "=== Стабильный драйвер через DKMS не установлен. Поставить: bash ~/nouveau-fix/stable/stable.sh install"
    echo "    (старый путь — стабильный-0001 + лабораторный: ~/nouveau-fix/rebuild.sh и lab/lab.sh install)"
    exit 1
fi
sudo rm -f "/var/lib/nouveau-fix/pending-$KVER" 2>/dev/null || true
echo "Перезагрузись. После неё: bash ~/nouveau-fix/stable/stable.sh status"
