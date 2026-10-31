#!/bin/bash
# ОПЫТ Е19 (30.10): решает ли ядро, будет ли сессия плохой. На 7.0.0-38 плохих было 3 из 4, на 7.0.0-42 — 0 из 5.
# Ставим официальное ядро 7.0.0-38 рядом с 42 и грузим на нём ТОТ ЖЕ модуль, что работает на 42: сборка Е18,
# srcversion 6A9EF87E28DF96B49307503. Исходники восстановлены 30.10 (дерево 42 + base.c и ramgf100.c из коммита e846f2c)
# и проверены сборкой под 42 — отпечаток совпал; лежат в ~/Home/nouveau-build/e19-6A9EF87E (sources.md5 — их сумма).
# Меняется одно: ядро. Программы (браузер, Claude, Cursor) остаются новыми.
#   bash lab/e19.sh check     — что стоит, что закреплено, какой модуль где (без пароля)
#   bash lab/e19.sh kernel    — поставить ядро 38 из архива Ubuntu (пароль; ~150 МБ)
#   bash lab/e19.sh build     — собрать модуль под 38 и сверить отпечаток (без пароля, ~3 мин)
#   bash lab/e19.sh install   — поставить модуль в ядро 38 и закрепить 38 в GRUB (пароль)
#   bash lab/e19.sh test      — в загрузке 38: контроль 300 подъёмов; хорошая сессия — 200 с ожиданием 8 мкс (~20 мин),
#                               плохая — порог ожидания делением пополам 1,5–8 мкс (30.10, ~40–60 мин)
#   bash lab/e19.sh back      — закрепить 7.0.0-42 обратно (пароль)
#   bash lab/e19.sh tally     — итоги контроля по загрузкам и ядрам
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"
K38=7.0.0-38-generic; K42=7.0.0-42-generic
WANT=6A9EF87E28DF96B49307503
SRC="$HOME/Home/nouveau-build/e19-6A9EF87E"
WORK="$SRC/build-$K38"
SLOT="/lib/modules/$K38/updates/nouveau-fix/nouveau.ko"

case "${1:-check}" in
check)
    echo "работает: ядро $(uname -r), модуль $(cat /sys/module/nouveau/srcversion 2>/dev/null || echo '—')"
    for k in $K38 $K42; do
        if [ -d "/lib/modules/$k/kernel" ]; then
            m="/lib/modules/$k/updates/nouveau-fix/nouveau.ko"
            echo "  $k: ядро стоит; заголовки $([ -e /lib/modules/$k/build/Makefile ] && echo есть || echo НЕТ); модуль $([ -e "$m" ] && modinfo -F srcversion "$m" || echo НЕТ)"
        else
            echo "  $k: ядра нет"
        fi
    done
    echo "нужный модуль: $WANT"
    "$KIT/daily/grub-pin.sh" status 2>/dev/null | sed -n '2p' || true
    ;;
kernel)
    sudo apt install linux-image-$K38 linux-modules-$K38 linux-headers-$K38
    ;;
build)
    [ -e "/lib/modules/$K38/build/Makefile" ] || { echo "Нет заголовков $K38: bash lab/e19.sh kernel"; exit 1; }
    (cd "$SRC/nouveau" && md5sum --quiet -c "$SRC/sources.md5") || { echo "СТОП: исходники Е18 изменились"; exit 2; }
    rm -rf "$WORK"; cp -r "$SRC/nouveau" "$WORK"
    echo "=== собираю модуль Е18 под $K38 (несколько минут)"
    nice -n 10 make -C "/lib/modules/$K38/build" M="$WORK" -j"$(nproc)" modules > "$SRC/build-$K38.log" 2>&1 \
        || { echo "Сборка не удалась: $SRC/build-$K38.log"; tail -n 20 "$SRC/build-$K38.log"; exit 3; }
    grep -q "vermagic: *$K38 " <(modinfo "$WORK/nouveau.ko") || { echo "СТОП: модуль собран не под $K38"; exit 3; }
    got="$(modinfo -F srcversion "$WORK/nouveau.ko")"
    [ "$got" = "$WANT" ] || { echo "СТОП: отпечаток $got, а нужен $WANT — модуль не тот же"; exit 3; }
    echo "=== собран: $WORK/nouveau.ko, отпечаток $got — тот же модуль, что работает на 42"
    ;;
install)
    [ -e "$WORK/nouveau.ko" ] && [ "$(modinfo -F srcversion "$WORK/nouveau.ko")" = "$WANT" ] || { echo "Сначала: bash lab/e19.sh build"; exit 1; }
    sudo install -D -m 644 "$WORK/nouveau.ko" "$SLOT"
    sudo depmod -a "$K38"; sudo update-initramfs -u -k "$K38"
    sudo rm -f "/var/lib/nouveau-fix/pending-$K38" 2>/dev/null || true
    "$KIT/daily/grub-pin.sh" "$K38"
    echo "=== модуль Е18 стоит в $K38, ядро 38 закреплено. Перезагрузись; после опыта: bash lab/e19.sh back"
    ;;
test)
    [ "$(uname -r)" = "$K38" ] || echo "--- внимание: работает $(uname -r), а не $K38 — это будет контроль на $(uname -r)"
    got="$(cat /sys/module/nouveau/srcversion 2>/dev/null || true)"
    [ "$got" = "$WANT" ] || { echo "СТОП: загружен модуль $got, а нужен $WANT"; exit 2; }
    POWEROFF=0 TEST=62 SCANAUTO=1 SCANSTEPS=8000 SCANFLOOR=0 bash "$HERE/night.sh"
    ;;
back)
    "$KIT/daily/grub-pin.sh" "$K42"
    echo "=== закреплено $K42. Убрать ядро 38 совсем (по желанию): sudo apt purge linux-image-$K38 linux-modules-$K38 linux-headers-$K38"
    ;;
tally)
    grep -E "ядро 7\.0\.0-(38|42)" "$KIT/results/test62-sessions.txt" | sed -E 's/ загрузка [0-9a-f]+//'
    ;;
*)
    sed -n '2,14p' "$0"; exit 1 ;;
esac
