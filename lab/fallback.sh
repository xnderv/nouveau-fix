#!/bin/bash
# АВТОМАТИЧЕСКИЙ ОТКАТ С ЛАБОРАТОРНОГО ДРАЙВЕРА (25.10). Если загрузка с лабораторным nouveau не подтвердилась (машина
# зависла и её перезапустили, ядро упало — kernel.panic=10 само перезагружает через 10 с, nouveau не поднял карту), следующая
# загрузка сама идёт со СТАБИЛЬНЫМ nouveau и дальше остаётся на нём, пока не вернёшь лабораторный (fallback.sh on).
#
# Как устроено:
#  - GRUB (/etc/grub.d/01_nouveau_lab) перед каждой загрузкой смотрит переменные в /boot/grub/grubenv:
#      nouveau_lab_off=1          → в ядро nouveau_lab=0 (стабильный);
#      nouveau_try=1 (прошлая загрузка не подтвердилась) → nouveau_lab=0 nouveau_lab_fallback=1 и ставит nouveau_lab_off=1;
#      иначе                      → nouveau_lab=1 и ставит nouveau_try=1 («пробую»).
#    Строка ядра получает это через $nouveau_sel в GRUB_CMDLINE_LINUX_DEFAULT.
#  - modprobe (/etc/modprobe.d/nouveau-select.conf → /usr/local/sbin/nouveau-select): лабораторный — только при
#    nouveau_lab=1 в строке ядра; иначе стабильная копия /usr/local/lib/nouveau-fallback/<ядро>/nouveau.ko (insmod, зависимости
#    модуля — modprobe). Нет nouveau_lab=1 (сломался GRUB-скрипт, режим восстановления) — тоже стабильный: отказ безопасный.
#  - initramfs (/etc/initramfs-tools/hooks/zz-nouveau-fix-no-nouveau): nouveau в него НЕ кладём — иначе модуль грузится ещё
#    до корневого раздела (MODULES=most, 25.10: 5,9 с против 6,5 с) в обход выбора. Заставка при загрузке — без nouveau.
#  - служба nouveau-lab-ok: через 60 с после графического входа, если загружен лабораторный и карта за ним (драйвер привязан),
#    пишет nouveau_try=0 — загрузка подтверждена. Зависания в тестах позже — уже не «неудачная загрузка».
# Команды (sudo спросит пароль):
#   bash ~/Home/nouveau-fix/lab/fallback.sh install    — поставить механизм (стабильная копия — из ~/Home/nouveau-build)
#   bash ~/Home/nouveau-fix/lab/fallback.sh status     — что выбрано сейчас и что будет при следующей загрузке
#   bash ~/Home/nouveau-fix/lab/fallback.sh test       — проверка: следующая загрузка будет как после сбоя (откат)
#   bash ~/Home/nouveau-fix/lab/fallback.sh on | off   — вернуть лабораторный / держать стабильный
#   bash ~/Home/nouveau-fix/lab/fallback.sh uninstall  — убрать механизм, /etc/default/grub — из копии
set -euo pipefail
KVER="$(uname -r)"
STABLE_SRC="$HOME/Home/nouveau-build/stable-$KVER-nouveau.ko"
STABLE_DIR="/usr/local/lib/nouveau-fallback/$KVER"
ENV=/boot/grub/grubenv
GRUBD=/etc/grub.d/01_nouveau_lab
SEL=/usr/local/sbin/nouveau-select
OKS=/usr/local/sbin/nouveau-lab-ok
MODCONF=/etc/modprobe.d/nouveau-select.conf
UNIT=/etc/systemd/system/nouveau-lab-ok.service
IHOOK=/etc/initramfs-tools/hooks/zz-nouveau-fix-no-nouveau
DEFGRUB=/etc/default/grub
DEFSAVE=/etc/default/grub.before-nouveau-fallback

genv() { grub-editenv "$ENV" list 2>/dev/null | grep -E "^$1=" | cut -d= -f2- || true; }

case "${1:-}" in
install)
    [ -r "$STABLE_SRC" ] || { echo "Нет стабильной копии $STABLE_SRC"; exit 1; }
    modinfo -F vermagic "$STABLE_SRC" | grep "^$KVER " >/dev/null || { echo "Стабильная копия собрана не под ядро $KVER"; exit 1; }
    if modinfo -p "$STABLE_SRC" | grep '^lab_' >/dev/null; then echo "$STABLE_SRC — это лабораторный модуль, а нужен стабильный"; exit 1; fi
    sudo -v
    sudo install -d "$STABLE_DIR"
    sudo install -m 644 "$STABLE_SRC" "$STABLE_DIR/nouveau.ko"
    echo "=== стабильная копия: $STABLE_DIR/nouveau.ko"

    sudo tee "$SEL" >/dev/null <<'EOF'
#!/bin/sh
# nouveau-fix (lab/fallback.sh): какой nouveau грузить. Лабораторный (обычный modprobe, updates/nouveau-fix) — только если
# GRUB передал nouveau_lab=1; иначе стабильная копия. Параметры nouveau.* из строки ядра передаём и стабильному.
K=$(uname -r); S=/usr/local/lib/nouveau-fallback/$K/nouveau.ko
if ! grep -qw 'nouveau_lab=1' /proc/cmdline && [ -r "$S" ]; then
    for m in $(modinfo -F depends "$S" | tr ',' ' '); do modprobe "$m"; done
    logger -t nouveau-select "стабильный nouveau ($S); строка ядра: $(cat /proc/cmdline)"
    exec insmod "$S" $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^nouveau\.//p')
fi
logger -t nouveau-select "лабораторный nouveau (nouveau_lab=1)"
exec modprobe --ignore-install nouveau "$@"
EOF
    sudo chmod 755 "$SEL"
    echo "install nouveau $SEL \$CMDLINE_OPTS" | sudo tee "$MODCONF" >/dev/null

    sudo tee "$OKS" >/dev/null <<'EOF'
#!/bin/sh
# nouveau-fix (lab/fallback.sh): подтверждение загрузки с лабораторным nouveau через 60 с после графического входа.
sleep 60
if grep -qw 'nouveau_lab_fallback=1' /proc/cmdline; then
    logger -t nouveau-lab-ok "ОТКАТ: прошлая загрузка с лабораторным nouveau не подтвердилась — сейчас стабильный; вернуть: lab/fallback.sh on"
    exit 0
fi
grep -qw 'nouveau_lab=1' /proc/cmdline || exit 0
if [ -e /sys/module/nouveau/parameters/lab_core ] && ls -d /sys/bus/pci/drivers/nouveau/0000:* >/dev/null 2>&1; then
    grub-editenv /boot/grub/grubenv set nouveau_try=0
    logger -t nouveau-lab-ok "загрузка с лабораторным nouveau подтверждена (nouveau_try=0)"
else
    logger -t nouveau-lab-ok "лабораторный nouveau не поднял карту — следующая загрузка будет со стабильным"
fi
EOF
    sudo chmod 755 "$OKS"
    sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=nouveau-fix: подтверждение загрузки с лабораторным nouveau (иначе следующая — со стабильным)
After=graphical.target

[Service]
Type=simple
ExecStart=$OKS

[Install]
WantedBy=graphical.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable nouveau-lab-ok.service

    sudo tee "$GRUBD" >/dev/null <<'EOF'
#!/bin/sh
# nouveau-fix (lab/fallback.sh): выбор nouveau перед загрузкой по счётчику в grubenv.
cat <<'GRUB'
# --- nouveau-fix: лабораторный / стабильный nouveau ---
load_env nouveau_try nouveau_lab_off
if [ "${nouveau_lab_off}" = "1" ]; then
  set nouveau_sel="nouveau_lab=0"
elif [ "${nouveau_try}" = "1" ]; then
  set nouveau_sel="nouveau_lab=0 nouveau_lab_fallback=1"
  set nouveau_lab_off=1
  save_env nouveau_lab_off
else
  set nouveau_sel="nouveau_lab=1"
  set nouveau_try=1
  save_env nouveau_try
fi
export nouveau_sel
GRUB
EOF
    sudo chmod 755 "$GRUBD"
    if ! grep -q 'nouveau_sel' "$DEFGRUB"; then
        [ -e "$DEFSAVE" ] || sudo cp -p "$DEFGRUB" "$DEFSAVE"
        sudo sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*)"/\1 \\$nouveau_sel"/' "$DEFGRUB"
    fi
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$DEFGRUB"
    sudo update-grub 2>&1 | tail -n 2
    sudo tee "$IHOOK" >/dev/null <<'HOOK'
#!/bin/sh
# nouveau-fix (lab/fallback.sh): nouveau не кладём в initramfs — его грузит с корневого раздела выбор
# /usr/local/sbin/nouveau-select (лабораторный или стабильный по строке ядра). depmod mkinitramfs делает после хуков.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac
[ -n "${DESTDIR}" ] || exit 0
find "${DESTDIR}/lib/modules" "${DESTDIR}/usr/lib/modules" -name 'nouveau.ko*' -delete 2>/dev/null
rm -f "${DESTDIR}/etc/modprobe.d/nouveau-select.conf" "${DESTDIR}/usr/lib/modprobe.d/nouveau-select.conf"
exit 0
HOOK
    sudo chmod 755 "$IHOOK"
    sudo update-initramfs -u -k "$KVER" 2>&1 | tail -n 1
    if sudo lsinitramfs "/boot/initrd.img-$KVER" | grep 'nouveau\.ko' >/dev/null; then
        echo "⚠ nouveau всё ещё в initramfs — откат не сработает, покажи этот вывод ассистенту"; exit 1
    fi
    echo "=== initramfs без nouveau"
    sudo grub-editenv "$ENV" set nouveau_try=0 nouveau_lab_off=0
    echo "=== в grub.cfg:"; sudo grep -nE 'nouveau_sel|nouveau-fix' /boot/grub/grub.cfg | head -n 8 || true
    echo "=== поставлено. Дальше: перезагрузка → bash $0 status (ждём nouveau_lab=1, через минуту nouveau_try=0)"
    ;;
status)
    echo "строка ядра: $(grep -oE 'nouveau_lab[a-z_]*=[0-9]' /proc/cmdline | tr '\n' ' ')"
    if [ -e /sys/module/nouveau/parameters/lab_core ]; then echo "загружен: ЛАБОРАТОРНЫЙ nouveau"
    elif [ -d /sys/module/nouveau ]; then echo "загружен: стабильный nouveau"; else echo "nouveau не загружен"; fi
    echo "grubenv: nouveau_try=$(genv nouveau_try) nouveau_lab_off=$(genv nouveau_lab_off)"
    if [ "$(genv nouveau_lab_off)" = 1 ]; then echo "следующая загрузка: стабильный (вернуть лабораторный: $0 on)"
    elif [ "$(genv nouveau_try)" = 1 ]; then echo "следующая загрузка: ОТКАТ на стабильный, если эту не подтвердить (служба подтверждает через минуту)"
    else echo "следующая загрузка: лабораторный"; fi
    journalctl -b 0 -t nouveau-select -t nouveau-lab-ok -o cat --no-pager 2>/dev/null | tail -n 3
    journalctl -b 0 -t nouveau-select -o cat --no-pager 2>/dev/null | grep -q . || echo "⚠ выбор nouveau-select в этой загрузке не срабатывал (модуль из initramfs?)"
    ;;
test)
    sudo grub-editenv "$ENV" set nouveau_try=1 nouveau_lab_off=0
    echo "Следующая загрузка будет как после сбоя: стабильный nouveau, nouveau_lab_fallback=1. Перезагрузись и запусти: bash $0 status"
    ;;
on)  sudo grub-editenv "$ENV" set nouveau_try=0 nouveau_lab_off=0; echo "Следующая загрузка — лабораторный." ;;
off) sudo grub-editenv "$ENV" set nouveau_lab_off=1; echo "Следующие загрузки — стабильный, пока не: $0 on" ;;
uninstall)
    sudo systemctl disable nouveau-lab-ok.service 2>/dev/null || true
    sudo rm -f "$UNIT" "$OKS" "$SEL" "$MODCONF" "$GRUBD" "$IHOOK"
    sudo update-initramfs -u -k "$KVER" 2>&1 | tail -n 1
    sudo systemctl daemon-reload
    [ -e "$DEFSAVE" ] && sudo cp -p "$DEFSAVE" "$DEFGRUB" && sudo rm -f "$DEFSAVE"
    sudo update-grub 2>&1 | tail -n 1
    sudo grub-editenv "$ENV" unset nouveau_try nouveau_lab_off
    echo "Механизм отката снят (стабильная копия осталась в $STABLE_DIR)."
    ;;
*) sed -n '2,25p' "$0"; exit 1 ;;
esac
