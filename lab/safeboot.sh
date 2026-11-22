#!/bin/bash
# БЕЗОПАСНАЯ ЗАГРУЗКА ТЕСТОВОЙ МАШИНЫ (22.11.2026). Вместо закрепления ядра и «стабильной» строки меню:
#   • по умолчанию GRUB грузит ПЕРВУЮ строку меню — самое новое ядро с ОБЫЧНЫМ nouveau дистрибутива: в обычном образе
#     initramfs и в /lib/modules нашего модуля нет. Ядро обновляется штатно (apt); машина всегда поднимается с SSH;
#   • наш модуль — только в отдельном образе /boot/initrd.img-<ядро>.lab и отдельной строке меню «LAB nouveau»; в неё
#     грузимся ОДИН раз (grub-reboot) перед опытами. Повисло — Reset/розетка, и машина снова в обычном варианте.
# Модуль собирается где угодно (на ноутбуке — быстрее) под ядро тестовой машины и копируется сюда.
#   bash lab/safeboot.sh status                 — какое ядро и какой nouveau сейчас, что по умолчанию, что в следующий раз
#   bash lab/safeboot.sh install МОДУЛЬ.ko [ЯДРО] — положить наш модуль (vermagic = ЯДРО, по умолчанию самое новое) в образ
#                                                   .lab и строку меню; обычный образ — без нашего модуля; GRUB по
#                                                   умолчанию — первая строка (самое новое ядро); старое «стабильное» —
#                                                   убрать (пароль, 2–4 мин: два образа dracut)
#   bash lab/safeboot.sh lab                    — следующая загрузка ОДИН раз в «LAB nouveau» и перезагрузка
#   bash lab/safeboot.sh off                    — убрать строку LAB и образ .lab (модуль остаётся в хранилище)
set -euo pipefail
NEWEST="$(ls -1 /lib/modules | sort -V | tail -n 1)"
STORE=/usr/local/lib/nouveau-fix
GRUBD=/etc/grub.d/42_nouveau_lab
DEFGRUB=/etc/default/grub
title() { echo "Ubuntu - LAB nouveau ($1, one boot)"; }
haslab() { modinfo -p "$1" 2>/dev/null | grep -q '^lab_vbios_src:'; }

# nouveau внутри образа: «lab» / «обычный» / «нет»
img_nouveau() {
    local img="$1" path tmp ext r
    path="$(sudo lsinitrd "$img" 2>/dev/null | grep -oE '[^ ]*/nouveau\.ko[^ ]*' | head -n1)" || true
    [ -n "$path" ] || { echo нет; return; }
    ext="${path##*nouveau.ko}"; tmp="$(mktemp -d)"
    sudo lsinitrd -f "$path" "$img" > "$tmp/nouveau.ko$ext" 2>/dev/null
    haslab "$tmp/nouveau.ko$ext" && r=lab || r=обычный
    rm -rf "$tmp"; echo "$r"
}

case "${1:-status}" in
status)
    echo "работает: ядро $(uname -r), nouveau $( [ -e /sys/module/nouveau/parameters/lab_vbios_src ] && echo "НАШ ($(cat /sys/module/nouveau/srcversion))" || { [ -d /sys/module/nouveau ] && echo обычный || echo 'не загружен'; } )"
    echo "GRUB: $(grep -E '^GRUB_DEFAULT=' $DEFGRUB); по умолчанию: $(sudo grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p' | sed 's/^$/—/'); в следующий раз: $(sudo grub-editenv list 2>/dev/null | sed -n 's/^next_entry=//p' | sed 's/^$/—/')"
    for k in $(ls -1 /lib/modules | sort -V); do
        printf '  %-20s обычный образ: %-8s  образ .lab: %s\n' "$k" \
            "$( [ -e /boot/initrd.img-$k ] && img_nouveau /boot/initrd.img-$k || echo '—')" \
            "$( [ -e /boot/initrd.img-$k.lab ] && echo "есть, nouveau $(img_nouveau /boot/initrd.img-$k.lab)" || echo нет)"
    done
    [ -e "$GRUBD" ] && echo "строка меню LAB: $(sed -n 's/^# ядро: //p' $GRUBD)" || echo "строка меню LAB: нет"
    ls /lib/modules/*/updates/nouveau-fix/nouveau.ko 2>/dev/null | sed 's/^/⚠ наш модуль лежит в обычном месте (попадёт в обычный образ): /' || true
    ;;
install)
    KO="${2:?укажи файл модуля}"; K="${3:-$NEWEST}"
    [ -d "/lib/modules/$K" ] || { echo "ядра $K нет"; exit 1; }
    modinfo -F vermagic "$KO" | grep -q "^$K " || { echo "модуль собран не под ядро $K ($(modinfo -F vermagic "$KO"))"; exit 1; }
    haslab "$KO" || { echo "$KO — не наш лабораторный модуль"; exit 1; }
    sudo -v
    SLOT="/lib/modules/$K/updates/nouveau-fix/nouveau.ko"; IMG="/boot/initrd.img-$K.lab"
    sudo install -D -m 644 "$KO" "$STORE/$K/nouveau.ko"
    echo "=== модуль $(modinfo -F srcversion "$KO") сохранён: $STORE/$K/nouveau.ko"
    # образ .lab: модуль временно на обычном месте; после — убрать при любом исходе
    trap 'sudo rm -f "'"$SLOT"'"; sudo depmod -a "'"$K"'"' EXIT
    sudo install -D -m 644 "$KO" "$SLOT"; sudo depmod -a "$K"
    echo "=== образ с нашим nouveau (dracut, 1–2 мин)"; sudo dracut --force "$IMG.new" "$K" 2>&1 | tail -n 1
    sudo rm -f "$SLOT"; sudo depmod -a "$K"; trap - EXIT
    [ "$(img_nouveau "$IMG.new")" = lab ] || { echo "⚠ в образе .lab нет нашего nouveau — стоп"; exit 1; }
    sudo mv -f "$IMG.new" "$IMG"
    echo "=== обычный образ без нашего модуля (dracut, 1–2 мин)"; sudo dracut --force "/boot/initrd.img-$K" "$K" 2>&1 | tail -n 1
    [ "$(img_nouveau "/boot/initrd.img-$K")" != lab ] || { echo "⚠ в обычном образе остался наш nouveau — стоп"; exit 1; }
    # старое: «стабильная» строка меню и её образы (lab/bootmenu.sh), закрепление ядра
    sudo rm -f /etc/grub.d/10_linux_nouveau_stable /boot/initrd.img-*.nouveau-stable
    sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$DEFGRUB"
    grep -qE '^GRUB_DISABLE_SUBMENU=y' "$DEFGRUB" || echo 'GRUB_DISABLE_SUBMENU=y' | sudo tee -a "$DEFGRUB" >/dev/null
    sudo rm -f "$GRUBD"; sudo update-grub >/dev/null 2>&1
    # строка LAB = копия обычного пункта этого ядра из grub.cfg с образом .lab
    ENTRY="$(sudo awk -v k="vmlinuz-$K" '/^menuentry /{buf=$0"\n"; inb=1; next} inb{buf=buf $0 "\n"} inb && /^}/{ if (index(buf,k) && buf !~ /recovery/) {printf "%s", buf; exit} inb=0 }' /boot/grub/grub.cfg)"
    [ -n "$ENTRY" ] || { echo "⚠ в grub.cfg нет пункта для ядра $K — стоп"; exit 1; }
    ENTRY="$(echo "$ENTRY" | sed -E "1s/^menuentry '[^']*'/menuentry '$(title "$K")'/; 1s/gnulinux-[^']*-([0-9a-f-]+)'/gnulinux-nouveau-lab-\1'/; s#(^\s*initrd\s+.*initrd\.img-$K)\s*\$#\1.lab#")"
    echo "$ENTRY" | grep -q "initrd.img-$K.lab" || { echo "⚠ не удалось подставить образ .lab — стоп"; exit 1; }
    { echo '#!/bin/sh'; echo "# nouveau-fix lab/safeboot.sh, $(date '+%F %T'); ядро: $K"
      echo "[ -e '$IMG' ] && [ -e '/boot/vmlinuz-$K' ] || exit 0"; echo "cat <<'GRUBENTRY'"; echo "$ENTRY"; echo "GRUBENTRY"; } | sudo tee "$GRUBD" >/dev/null
    sudo chmod 755 "$GRUBD"; sudo update-grub 2>&1 | tail -n 1
    sudo grub-set-default 0
    echo "=== меню:"; sudo grep -E "^menuentry " /boot/grub/grub.cfg | sed -E "s/^menuentry '([^']*)'.*/  \1/" | head -n 8
    echo "=== готово: по умолчанию — первая строка (самое новое ядро, обычный nouveau); наш — bash lab/safeboot.sh lab"
    ;;
lab)
    [ -e "$GRUBD" ] || { echo "строки LAB нет — сначала install"; exit 1; }
    K="$(sed -n 's/^# .*ядро: //p' $GRUBD)"
    sudo grep -qF "menuentry '$(title "$K")'" /boot/grub/grub.cfg || { echo "⚠ строки «$(title "$K")» нет в grub.cfg"; exit 1; }
    sudo grub-reboot "$(title "$K")"
    echo "следующая загрузка ОДИН раз: $(title "$K"); перезагружаю"; sudo reboot
    ;;
off)
    sudo rm -f "$GRUBD" /boot/initrd.img-*.lab; sudo update-grub 2>&1 | tail -n 1; echo "строка LAB и образы .lab убраны"
    ;;
*) sed -n '2,15p' "$0"; exit 1 ;;
esac
