#!/bin/bash
# Возвращает стандартный драйвер nouveau Ubuntu для указанного ядра (по умолчанию — текущего).
set -euo pipefail
KVER="${1:-$(uname -r)}"
DEST="/lib/modules/$KVER/updates"
echo "Убираю наши сборки nouveau для ядра $KVER (нужен пароль)..."
for d in nouveau-fix nouveau-engobj-idle nouveau-fence-fix nouveau-fermi-reclock; do
    [ -e "$DEST/$d" ] && sudo rm -rf -- "$DEST/$d"
done
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"
echo "Для ядра $KVER выбран драйвер: $(modinfo -k "$KVER" -n nouveau)"
echo "Перезагрузись, чтобы он заработал."
