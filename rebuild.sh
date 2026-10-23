#!/bin/bash
# Пересобирает драйвер nouveau с нашим исправлением под указанное ядро и ставит его.
# Запуск:  ~/Home/nouveau-fix/rebuild.sh            — для самого нового установленного ядра
#          ~/Home/nouveau-fix/rebuild.sh 7.0.0-40-generic — для конкретного ядра
# Сборка идёт без прав администратора; пароль спрашивается только на шаге установки,
# и только после твоего «y».
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/patches/0001-nouveau-abi16-idle-channel-before-engobj-del.patch"
KVER="${1:-$(ls -1 /lib/modules | sort -V | tail -n 1)}"
KBUILD="/lib/modules/$KVER/build"
WORK="$HOME/Home/nouveau-build/fix-$KVER"
LOG="$WORK/build.log"

say() { printf '\n=== %s\n' "$*"; }

say "Ядро: $KVER"
if [ ! -e "$KBUILD/Makefile" ]; then
    echo "Нет заголовков ядра $KVER. Поставь их командой:"
    echo "  sudo apt install linux-headers-$KVER"
    exit 1
fi
command -v git >/dev/null || { echo "Нет программы git. Поставь: sudo apt install git"; exit 1; }
command -v make >/dev/null || { echo "Нет программы make. Поставь: sudo apt install build-essential"; exit 1; }

# Версия Linux, на которой основано ядро Ubuntu (например 7.0.14).
UPV="$(make -s -C "$KBUILD" kernelversion 2>/dev/null | tail -n 1 || true)"
if ! [[ "$UPV" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    MF="/usr/src/linux-headers-${KVER%-generic}/Makefile"
    [ -r "$MF" ] || MF="$KBUILD/Makefile"
    UPV="$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{if(v!="") print v"."p"."s}' "$MF")"
fi
case "$UPV" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    [0-9]*.[0-9]*) ;;
    *) echo "Не удалось определить версию Linux для $KVER (получено: '$UPV')"; exit 1 ;;
esac
TAG="v${UPV%.0}"   # тег v7.1 вместо v7.1.0
say "Основа ядра: Linux $UPV (тег $TAG)"

rm -rf "$WORK"
mkdir -p "$WORK"

say "Скачиваю исходники nouveau ($TAG)..."
git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$TAG" \
    https://github.com/gregkh/linux.git "$WORK/src"
git -C "$WORK/src" sparse-checkout set drivers/gpu/drm/nouveau
git -C "$WORK/src" checkout -q
cp -r "$WORK/src/drivers/gpu/drm/nouveau" "$WORK/nouveau"
rm -rf "$WORK/src"

say "Накладываю исправление..."
cd "$WORK/nouveau"
if git apply --check -p1 "$PATCH" 2>/dev/null; then
    git apply -p1 "$PATCH"
    echo "Исправление наложено."
elif git apply -R --check -p1 "$PATCH" 2>/dev/null; then
    echo "Похоже, исправление УЖЕ ЕСТЬ в этой версии Linux — пересобирать не нужно."
    echo "Стандартный драйвер Ubuntu для $KVER уже содержит его. Проверь после перезагрузки: ~/Home/nouveau-fix/check.sh"
    exit 0
else
    echo "Исправление НЕ накладывается: код драйвера в Linux $UPV изменился."
    echo "Ничего не установлено. Покажи этот вывод ассистенту — патч нужно обновить."
    exit 2
fi

say "Собираю модуль (несколько минут, лог: $LOG)..."
if ! make -C "$KBUILD" M="$WORK/nouveau" -j"$(nproc)" modules > "$LOG" 2>&1; then
    echo "Сборка НЕ удалась. Ничего не установлено. Последние строки лога:"
    tail -n 20 "$LOG"
    exit 3
fi
modinfo "$WORK/nouveau/nouveau.ko" | grep -E '^(filename|vermagic)'
grep -q "vermagic: *$KVER " <(modinfo "$WORK/nouveau/nouveau.ko") || {
    echo "Собранный модуль не совпадает с ядром $KVER. Ничего не установлено."; exit 3; }

say "Сборка готова."
read -r -p "Установить исправленный драйвер для ядра $KVER? Понадобится пароль. [y/N] " ans
case "$ans" in y|Y|д|Д) ;; *) echo "Не устанавливаю. Модуль лежит в $WORK/nouveau/nouveau.ko"; exit 0 ;; esac

DEST="/lib/modules/$KVER/updates"
# Убираем прежние наши сборки для этого ядра, чтобы не было двух nouveau.ko.
for d in nouveau-fix nouveau-engobj-idle nouveau-fence-fix nouveau-fermi-reclock; do
    [ -e "$DEST/$d" ] && sudo rm -rf -- "$DEST/$d"
done
sudo install -D -m 644 "$WORK/nouveau/nouveau.ko" "$DEST/nouveau-fix/nouveau.ko"
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"

say "Готово. Для ядра $KVER выбран драйвер:"
modinfo -k "$KVER" -n nouveau
echo "Перезагрузись, затем запусти: ~/Home/nouveau-fix/check.sh"
