#!/bin/bash
# ЛОВУШКА ДЛЯ ЗАВИСАНИЙ (только на время опытов с частотами).
#   trap.sh on     — включить: участок памяти 16 МБ (0x41e000000) отводится под «чёрный ящик» (ramoops),
#                    при полном зависании ядро делает аварийную остановку и пишет туда журнал,
#                    через 10 с перезагружается само. Нужна перезагрузка.
#   trap.sh off    — выключить, всё вернуть как было. Нужна перезагрузка.
#   trap.sh status — включена ли, и что поймано после прошлых зависаний.
# Ничего не удаляет и не трогает /etc/default/grub — только свой файл в /etc/default/grub.d/.
set -euo pipefail

CFG=/etc/default/grub.d/99-nouveau-lab-trap.cfg
MOD=/etc/modules-load.d/nouveau-lab-ramoops.conf
ADDR=0x41e000000      # последние 16 МБ обычной памяти (карта памяти от 20.10: RAM до 0x41effffff)
SIZE=0x1000000

case "${1:-}" in
on)
    grep -q '^CONFIG_PSTORE_RAM=' "/boot/config-$(uname -r)" || { echo "Ядро без ramoops — ловушка невозможна."; exit 1; }
    sudo tee "$CFG" >/dev/null <<EOF
# nouveau lab: ловушка зависаний. Выключить: ~/nouveau-fix/lab/trap.sh off
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT memmap=16M\\\\\\\$$ADDR ramoops.mem_address=$ADDR ramoops.mem_size=$SIZE ramoops.record_size=0x200000 ramoops.pmsg_size=0x400000 ramoops.console_size=0x200000 nmi_watchdog=panic,1 softlockup_panic=1 panic=10 crash_kexec_post_notifiers"
EOF
    echo ramoops | sudo tee "$MOD" >/dev/null
    sudo update-grub 2>&1 | tail -n 2
    echo "=== Строка загрузки после перезагрузки будет такой:"
    sudo grep -m1 'linux.*vmlinuz' /boot/grub/grub.cfg | grep -o 'memmap=[^ ]*\|ramoops.mem_address=[^ ]*\|nmi_watchdog=[^ ]*'
    echo "=== Ловушка включится после перезагрузки."
    ;;
off)
    sudo rm -f -- "$CFG" "$MOD"
    sudo update-grub 2>&1 | tail -n 2
    echo "=== Ловушка выключена (после перезагрузки)."
    ;;
status)
    if grep -q 'ramoops.mem_address' /proc/cmdline; then echo "Ловушка: ВКЛЮЧЕНА в этой загрузке"; else echo "Ловушка: выключена в этой загрузке"; fi
    lsmod | grep -q '^ramoops' && echo "Модуль ramoops: загружен" || echo "Модуль ramoops: НЕ загружен"
    [ -e /dev/pmsg0 ] && echo "Канал /dev/pmsg0: есть (lab.sh try пишет туда журнал на лету)" || echo "Канал /dev/pmsg0: нет"
    echo "--- Поймано (журналы прошлых аварий):"
    sudo ls -la /sys/fs/pstore /var/lib/systemd/pstore 2>/dev/null || true
    ;;
*)
    sed -n '2,8p' "$0"; exit 1 ;;
esac
