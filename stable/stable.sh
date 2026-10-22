#!/bin/bash
# СТАБИЛЬНЫЙ ДРАЙВЕР nouveau для GTX 560 Ti (GF114): смена частот как у NVIDIA, регулятор с температурным
# тормозом, HDMI-исправления. Без переключателей, ставится через DKMS и сам пересобирается под каждое новое ядро.
#   stable.sh install   — поставить (пароль): DKMS собирает под текущее ядро, драйвер включается после перезагрузки
#   stable.sh status    — что загружено, режим, температура, шина, последние события
#   stable.sh build [ядро] — собрать под указанное/самое новое ядро заранее (обычно DKMS делает это сам)
#   stable.sh remove    — убрать (вернуться к штатному nouveau Ubuntu; пароль)
# Лабораторный драйвер ставится поверх командой lab/lab.sh install (он сам отключает стабильный для этого ядра);
# вернуться к стабильному — снова stable.sh install.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"
NAME=nouveau-gf114; VER=1.0; SRC="/usr/src/$NAME-$VER"
P=/sys/module/nouveau/parameters
case "${1:-}" in
install)
    for t in dkms make gcc patch; do command -v $t >/dev/null || { echo "--- Нет программы $t. Поставь: sudo apt install dkms build-essential patch git"; exit 1; }; done
    KVER="$(uname -r)"
    [ -e "/lib/modules/$KVER/build/Makefile" ] || { echo "--- Нет заголовков ядра: sudo apt install linux-headers-$KVER"; exit 1; }
    for p in 0001-nouveau-abi16-idle-channel-before-engobj-del 0003-nouveau-disp-hdmi-without-scdc-below-340mhz 0010-nouveau-gf114-reclock; do
        [ -e "$KIT/patches/$p.patch" ] || { echo "--- Нет файла patches/$p.patch"; exit 1; }
    done
    echo "=== Ставлю исходники в $SRC и регистрирую в DKMS (пароль)"
    sudo -v || exit 1
    if dkms status "$NAME/$VER" 2>/dev/null | grep -q .; then sudo dkms remove "$NAME/$VER" --all >/dev/null 2>&1 || true; fi
    sudo rm -rf "$SRC"; sudo mkdir -p "$SRC/patches"
    sudo install -m 644 "$HERE/dkms.conf" "$SRC/dkms.conf"
    sudo install -m 755 "$HERE/prepare.sh" "$SRC/prepare.sh"
    for p in 0001-nouveau-abi16-idle-channel-before-engobj-del 0003-nouveau-disp-hdmi-without-scdc-below-340mhz 0010-nouveau-gf114-reclock; do
        sudo install -m 644 "$KIT/patches/$p.patch" "$SRC/patches/$p.patch"
        [ -e "$KIT/patches/$p.patch.needs" ] && sudo install -m 644 "$KIT/patches/$p.patch.needs" "$SRC/patches/$p.patch.needs"
    done
    sudo dkms add "$NAME/$VER" || exit 1
    echo "=== Собираю под $KVER (несколько минут)..."
    if ! sudo dkms build "$NAME/$VER" -k "$KVER"; then
        echo "--- Сборка не удалась. Журнал: /var/lib/dkms/$NAME/$VER/build/make.log — пришли его. Ничего не установлено."; exit 3
    fi
    sudo dkms install "$NAME/$VER" -k "$KVER" --force || exit 3
    # убрать ручные сборки (стабильный-0001 и лабораторный), чтобы в updates/ был один nouveau.ko
    for d in nouveau-fix nouveau-engobj-idle nouveau-fence-fix nouveau-fermi-reclock; do
        [ -e "/lib/modules/$KVER/updates/$d" ] && sudo rm -rf "/lib/modules/$KVER/updates/$d"
    done
    # служба gpu-autoclock и её параметры больше не нужны: решает драйвер
    if systemctl list-unit-files gpu-autoclock.service >/dev/null 2>&1 && systemctl is-enabled gpu-autoclock.service >/dev/null 2>&1; then
        sudo systemctl disable --now gpu-autoclock.service >/dev/null 2>&1 || true
        echo "=== Служба gpu-autoclock выключена (в стабильном драйвере она не нужна)"
    fi
    [ -e /etc/modprobe.d/nouveau-itc.conf ] && { sudo rm -f /etc/modprobe.d/nouveau-itc.conf; echo "=== Убран /etc/modprobe.d/nouveau-itc.conf (флаг ITC теперь в коде)"; }
    # напоминание о новом ядре (если DKMS не смог собрать без сети)
    [ -e "$KIT/daily/kernel-remind.sh" ] && sudo install -m 0755 "$KIT/daily/kernel-remind.sh" /etc/kernel/postinst.d/zz-nouveau-fix-remind
    sudo depmod -a "$KVER"; sudo update-initramfs -u -k "$KVER"
    echo "=== Для ядра $KVER выбран драйвер: $(modinfo -k "$KVER" -n nouveau)"
    modinfo -k "$KVER" -p nouveau 2>/dev/null | grep -q gf114_gov && echo "=== Это стабильный драйвер GF114 ✅ Перезагрузись, затем: bash ~/nouveau-fix/stable/stable.sh status" \
        || echo "!!! Выбран не наш драйвер — пришли вывод"
    ;;
build)
    KVER="${2:-$(ls -1 /lib/modules | sort -V | tail -n 1)}"
    sudo dkms build "$NAME/$VER" -k "$KVER" && sudo dkms install "$NAME/$VER" -k "$KVER" --force && sudo update-initramfs -u -k "$KVER" \
        && echo "=== Готово для $KVER: $(modinfo -k "$KVER" -n nouveau)" ;;
status)
    echo "драйвер: $(modinfo -n nouveau 2>/dev/null) ($(uname -r))"
    echo "DKMS: $(dkms status "$NAME/$VER" 2>/dev/null | tr '\n' ' ')"
    if [ -e "$P/gf114_gov" ]; then
        echo "стабильный драйвер GF114 загружен ✅  регулятор: $([ "$(cat $P/gf114_gov)" = 1 ] && echo включён || echo ВЫКЛЮЧЕН)  плата: режим gf114_board=$(cat $P/gf114_board)"
        echo "загрузка (последний замер): графика $(( $(cat $P/gf114_load_gr) / 10 )) %, видео $(( $(cat $P/gf114_load_vid) / 10 )) %; температура по регулятору $(cat $P/gf114_temp) °C"
    else
        echo "стабильный драйвер GF114 НЕ загружен ($( [ -e $P/lab_gov ] && echo 'загружен лабораторный' || echo 'загружен штатный nouveau'))"
    fi
    H="$(for h in /sys/class/hwmon/hwmon*; do grep -q nouveau "$h/name" 2>/dev/null && echo "$h"; done | head -n1)"
    [ -n "$H" ] && echo "датчик: $(( $(cat $H/temp1_input) / 1000 )) °C, вентилятор $(cat $H/fan1_input 2>/dev/null) об/мин, обороты задания $(cat $H/pwm1) %"
    echo "режим: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n1' 2>/dev/null || echo '(нужен пароль для режима)')"
    DEV="$(for d in /sys/bus/pci/devices/*; do grep -q 0x10de "$d/vendor" 2>/dev/null && grep -q '^0x03' "$d/class" && basename "$d"; done | head -n1)"
    [ -n "$DEV" ] && echo "PCIe: $(cat /sys/bus/pci/devices/$DEV/current_link_speed 2>/dev/null)"
    echo "--- события драйвера с загрузки (GF114, ошибки):"
    journalctl -k -b 0 --no-pager | grep -E "GF114|nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf|no reply)" | tail -n 15 | sed -E 's/^.*kernel: //'
    ;;
remove)
    sudo dkms remove "$NAME/$VER" --all; sudo rm -rf "$SRC"; sudo depmod -a; sudo update-initramfs -u
    echo "Стабильный драйвер убран. После перезагрузки — штатный nouveau Ubuntu (без смены частот и без исправления гонки 0001)." ;;
*) sed -n '2,9p' "$0"; exit 1 ;;
esac
