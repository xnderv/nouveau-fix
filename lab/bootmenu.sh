#!/bin/bash
# МЕНЮ ЗАГРУЗКИ НА ВРЕМЯ ТЕСТОВ (25.10). GRUB показывает меню 5 с:
#   1. Ubuntu                                   — по умолчанию, лабораторный nouveau (как сейчас)
#   2. Advanced options for Ubuntu              — штатный пункт GRUB
#   3. Ubuntu - STABLE nouveau (if the lab driver fails) — стабильный nouveau (копия от 19.10)
# Как устроено: nouveau поднимается из образа initramfs, который GRUB грузит вместе с ядром (MODULES=most). Строка 3 — то
# же ядро и та же строка ядра, но второй образ /boot/initrd.img-<ядро>.nouveau-stable со стабильным модулем внутри. Больше
# ничего не переключается: что выбрал в меню — то и загрузилось.
# Второй образ собирается так: стабильный модуль временно кладётся на место лабораторного, mkinitramfs → второй образ,
# лабораторный возвращается (при любой ошибке — тоже). Обычный образ при этом не трогается.
# Команды (sudo спросит пароль):
#   bash ~/Home/nouveau-fix/lab/bootmenu.sh install    — снять старый механизм отката (fallback.sh), собрать второй образ,
#                                                         показать меню 5 с, добавить строку 3
#   bash ~/Home/nouveau-fix/lab/bootmenu.sh status     — какие строки в меню, какие образы есть, какой драйвер загружен
#   bash ~/Home/nouveau-fix/lab/bootmenu.sh uninstall  — убрать строку 3 и второй образ, меню снова скрыто
# После обновления ядра: bash ~/Home/nouveau-fix/lab/bootmenu.sh install (строка 3 привязана к ядру, для которого собрана).
set -euo pipefail
KVER="$(uname -r)"
SLOT="/lib/modules/$KVER/updates/nouveau-fix/nouveau.ko"
STABLE_SRC="$HOME/Home/nouveau-build/stable-$KVER-nouveau.ko"
KEEP="/usr/local/lib/nouveau-fallback/$KVER"
IMG="/boot/initrd.img-$KVER.nouveau-stable"
GRUBD=/etc/grub.d/10_linux_nouveau_stable
DEFGRUB=/etc/default/grub
DEFSAVE=/etc/default/grub.before-nouveau-bootmenu
TITLE="Ubuntu - STABLE nouveau (if the lab driver fails)"

remove_old_fallback() {   # механизм fallback.sh (25.10, не сработал из-за initramfs) — снять полностью
    local any=0 f
    for f in /etc/grub.d/01_nouveau_lab /etc/modprobe.d/nouveau-select.conf /usr/local/sbin/nouveau-select \
             /usr/local/sbin/nouveau-lab-ok /etc/systemd/system/nouveau-lab-ok.service \
             /etc/initramfs-tools/hooks/zz-nouveau-fix-no-nouveau; do
        [ -e "$f" ] && { any=1; break; }
    done
    [ "$any" = 1 ] || return 0
    echo "=== снимаю старый механизм отката (fallback.sh)"
    sudo systemctl disable nouveau-lab-ok.service 2>/dev/null || true
    sudo rm -f /etc/grub.d/01_nouveau_lab /etc/modprobe.d/nouveau-select.conf /usr/local/sbin/nouveau-select \
               /usr/local/sbin/nouveau-lab-ok /etc/systemd/system/nouveau-lab-ok.service \
               /etc/initramfs-tools/hooks/zz-nouveau-fix-no-nouveau
    sudo systemctl daemon-reload
    if [ -e /etc/default/grub.before-nouveau-fallback ]; then
        sudo cp -p /etc/default/grub.before-nouveau-fallback "$DEFGRUB"
        sudo rm -f /etc/default/grub.before-nouveau-fallback
    fi
    sudo grub-editenv /boot/grub/grubenv unset nouveau_try nouveau_lab_off 2>/dev/null || true
}

build_stable_image() {
    local saved="$KEEP/nouveau-lab-saved.ko" tmp
    [ -r "$STABLE_SRC" ] || { echo "Нет стабильной копии $STABLE_SRC"; exit 1; }
    modinfo -F vermagic "$STABLE_SRC" | grep "^$KVER " >/dev/null || { echo "Стабильная копия собрана не под ядро $KVER"; exit 1; }
    if modinfo -p "$STABLE_SRC" | grep '^lab_' >/dev/null; then echo "$STABLE_SRC — лабораторный модуль, а нужен стабильный"; exit 1; fi
    [ -e "$SLOT" ] || { echo "Нет лабораторного модуля $SLOT (lab.sh install)"; exit 1; }
    sudo install -d "$KEEP"
    sudo install -m 644 "$STABLE_SRC" "$KEEP/nouveau.ko"
    sudo cp -p "$SLOT" "$saved"
    # вернуть лабораторный при любом выходе из этой функции, в том числе при ошибке
    trap 'sudo install -m 644 "'"$saved"'" "'"$SLOT"'"; sudo depmod -a "'"$KVER"'"; trap - EXIT' EXIT
    echo "=== собираю второй образ со стабильным nouveau (минуту-две)"
    sudo install -m 644 "$KEEP/nouveau.ko" "$SLOT"
    sudo depmod -a "$KVER"
    sudo mkinitramfs -o "$IMG.new" "$KVER"
    sudo install -m 644 "$saved" "$SLOT"
    sudo depmod -a "$KVER"
    trap - EXIT
    cmp -s "$saved" "$SLOT" || { echo "⚠ лабораторный модуль не вернулся на место — покажи ассистенту"; exit 1; }
    # проверка содержимого: во втором образе — стабильный nouveau (без lab_*)
    tmp="$(mktemp -d)"
    sudo unmkinitramfs "$IMG.new" "$tmp"
    local ko; ko="$(sudo find "$tmp" -name 'nouveau.ko*' | head -n1)"
    [ -n "$ko" ] || { sudo rm -rf "$tmp"; echo "⚠ во втором образе нет nouveau — покажи ассистенту"; exit 1; }
    if sudo modinfo -p "$ko" | grep '^lab_' >/dev/null; then sudo rm -rf "$tmp"; echo "⚠ во втором образе лабораторный nouveau — покажи ассистенту"; exit 1; fi
    sudo rm -rf "$tmp"
    sudo mv -f "$IMG.new" "$IMG"
    echo "=== второй образ: $IMG (стабильный nouveau внутри — проверено)"
}

write_menu_entry() {   # строка 3 = копия основного пункта Ubuntu из grub.cfg с другим initrd
    local entry
    entry="$(sudo awk '/^menuentry / && !f {f=1} f {print} f && /^}/ {exit}' /boot/grub/grub.cfg)"
    echo "$entry" | grep -q "vmlinuz-$KVER" || { echo "⚠ основной пункт меню не для ядра $KVER — покажи ассистенту"; exit 1; }
    echo "$entry" | grep -qE "^\s*initrd\s+.*initrd\.img-$KVER\s*$" || { echo "⚠ в основном пункте не найден initrd — покажи ассистенту"; exit 1; }
    entry="$(echo "$entry" | sed -E "1s/^menuentry '[^']*'/menuentry '$TITLE'/; 1s/gnulinux-simple-/gnulinux-nouveau-stable-/; s#(^\s*initrd\s+.*initrd\.img-$KVER)\s*\$#\1.nouveau-stable#")"
    {
        echo '#!/bin/sh'
        echo "# nouveau-fix (lab/bootmenu.sh, $(date '+%F %T')): строка меню со стабильным nouveau на время тестов."
        echo "# Тело — копия основного пункта Ubuntu для ядра $KVER с образом $IMG. Обновить: bash lab/bootmenu.sh install"
        echo "[ -e '$IMG' ] && [ -e '/boot/vmlinuz-$KVER' ] || exit 0"
        echo "cat <<'GRUBENTRY'"
        echo "$entry"
        echo "GRUBENTRY"
    } | sudo tee "$GRUBD" >/dev/null
    sudo chmod 755 "$GRUBD"
}

case "${1:-}" in
install)
    sudo -v
    remove_old_fallback
    if ! grep -q '^GRUB_TIMEOUT_STYLE=menu' "$DEFGRUB" || ! grep -q '^GRUB_TIMEOUT=5' "$DEFGRUB"; then
        [ -e "$DEFSAVE" ] || sudo cp -p "$DEFGRUB" "$DEFSAVE"
        sudo sed -i -E 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/; s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$DEFGRUB"
    fi
    grep -E '^GRUB_(TIMEOUT_STYLE|TIMEOUT|CMDLINE_LINUX_DEFAULT)=' "$DEFGRUB"
    build_stable_image
    sudo rm -f "$GRUBD"
    sudo update-grub >/dev/null 2>&1
    write_menu_entry
    sudo update-grub 2>&1 | tail -n 1
    echo "=== меню загрузки:"; sudo grep -E "^(menuentry|submenu) " /boot/grub/grub.cfg | sed -E "s/^(menuentry|submenu) '([^']*)'.*/  \2/"
    echo "=== готово. При следующей загрузке меню будет видно 5 с; третья строка — стабильный nouveau."
    ;;
status)
    echo "загружен сейчас: $( [ -e /sys/module/nouveau/parameters/lab_core ] && echo 'ЛАБОРАТОРНЫЙ nouveau' || { [ -d /sys/module/nouveau ] && echo 'стабильный nouveau' || echo 'nouveau не загружен'; } )"
    ls -l "/boot/initrd.img-$KVER" "$IMG" 2>&1 | sed 's/^/  /'
    [ -e "$GRUBD" ] && echo "строка 3 в меню: есть ($GRUBD)" || echo "строка 3 в меню: нет"
    grep -E '^GRUB_(TIMEOUT_STYLE|TIMEOUT)=' "$DEFGRUB"
    ;;
uninstall)
    sudo rm -f "$GRUBD" "$IMG"
    [ -e "$DEFSAVE" ] && sudo cp -p "$DEFSAVE" "$DEFGRUB" && sudo rm -f "$DEFSAVE"
    sudo update-grub 2>&1 | tail -n 1
    echo "Строка 3 и второй образ убраны, меню — как было."
    ;;
*) sed -n '2,17p' "$0"; exit 1 ;;
esac
