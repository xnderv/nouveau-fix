#!/bin/bash
# ЛАБОРАТОРИЯ: опыты с частотами карты. НЕ для повседневной работы.
#   lab.sh install   — собрать и поставить экспериментальный драйвер (исправление гонки +
#                      разрешение смены частот + подробные сообщения "LAB ..." в журнале).
#                      Стабильный драйвер сохраняется в резервную копию.
#   lab.sh pstate 07 — переключить карту в режим 07 (или 0f, 03). Действует до перезагрузки.
#                      Результат пишется в ~/nouveau-fix/results/ и сразу сбрасывается на диск.
#   lab.sh restore   — вернуть стабильный драйвер из резервной копии (потом перезагрузка).
# Частота сама НЕ поднимается: после перезагрузки карта всегда на исходных 50 МГц.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(dirname "$HERE")"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
SLOT="/lib/modules/$KVER/updates/nouveau-fix/nouveau.ko"
BACKUP="$HOME/nouveau-build/stable-$KVER-nouveau.ko"
WORK="$HOME/nouveau-build/lab-$KVER"

case "${1:-}" in
install)
    command -v git >/dev/null || { echo "Нет git: sudo apt install git"; exit 1; }
    [ -e "$KBUILD/Makefile" ] || { echo "Нет заголовков ядра: sudo apt install linux-headers-$KVER"; exit 1; }
    UPV="$(make -s -C "$KBUILD" kernelversion 2>/dev/null | tail -n 1 || true)"
    if ! [[ "$UPV" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        MF="/usr/src/linux-headers-${KVER%-generic}/Makefile"; [ -r "$MF" ] || MF="$KBUILD/Makefile"
        UPV="$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{if(v!="") print v"."p"."s}' "$MF")"
    fi
    TAG="v${UPV%.0}"
    echo "=== Ядро $KVER, основа Linux $UPV"
    rm -rf "$WORK"; mkdir -p "$WORK"
    git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$TAG" https://github.com/gregkh/linux.git "$WORK/src"
    git -C "$WORK/src" sparse-checkout set drivers/gpu/drm/nouveau
    git -C "$WORK/src" checkout -q
    cp -r "$WORK/src/drivers/gpu/drm/nouveau" "$WORK/nouveau"; rm -rf "$WORK/src"
    cd "$WORK/nouveau"
    git apply -p1 "$KIT/patches/0001-nouveau-abi16-idle-channel-before-engobj-del.patch"
    git apply -p1 "$HERE/0002-LAB-fermi-reclock-instrumented.patch"
    echo "=== Исправление гонки + лабораторный патч наложены. Собираю (несколько минут)..."
    if ! make -C "$KBUILD" M="$WORK/nouveau" -j"$(nproc)" modules > "$WORK/build.log" 2>&1; then
        echo "Сборка НЕ удалась, ничего не установлено. Лог: $WORK/build.log"; tail -n 20 "$WORK/build.log"; exit 3
    fi
    if [ ! -e "$BACKUP" ]; then
        [ -e "$SLOT" ] || { echo "Нет стабильного драйвера в $SLOT. Сначала запусти ~/nouveau-fix/rebuild.sh"; exit 1; }
        cp "$SLOT" "$BACKUP"
        echo "=== Стабильный драйвер сохранён: $BACKUP"
    fi
    read -r -p "Поставить ЛАБОРАТОРНЫЙ драйвер вместо стабильного? Пароль. [y/N] " ans
    case "$ans" in y|Y|д|Д) ;; *) echo "Не ставлю."; exit 0 ;; esac
    sudo install -m 644 "$WORK/nouveau/nouveau.ko" "$SLOT"
    sudo depmod -a "$KVER"; sudo update-initramfs -u -k "$KVER"
    echo "=== Готово. Перезагрузись. Вернуть стабильный: ~/nouveau-fix/lab/lab.sh restore"
    ;;
pstate)
    P="${2:-}"; [[ "$P" =~ ^(03|07|0f)$ ]] || { echo "Укажи режим: 03, 07 или 0f"; exit 1; }
    mkdir -p "$KIT/results"
    OUT="$KIT/results/pstate-$P-$(date +%Y%m%d-%H%M%S).txt"
    echo "Переключаю карту в режим $P. Если экран встанет: Alt+PrtSc, затем S, U, B."
    sudo sh -c "f=\$(ls /sys/kernel/debug/dri/*/pstate | head -n1); echo $P > \"\$f\"; cat \"\$f\" > '$OUT'; sync"
    cat "$OUT"
    ;;
restore)
    [ -e "$BACKUP" ] || { echo "Нет резервной копии $BACKUP. Стабильный драйвер можно пересобрать: ~/nouveau-fix/rebuild.sh"; exit 1; }
    sudo install -m 644 "$BACKUP" "$SLOT"
    sudo depmod -a "$KVER"; sudo update-initramfs -u -k "$KVER"
    echo "=== Стабильный драйвер возвращён. Перезагрузись и проверь: ~/nouveau-fix/check.sh"
    ;;
*)
    sed -n '2,10p' "$0"; exit 1 ;;
esac
