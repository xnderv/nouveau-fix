#!/bin/bash
# ОПЫТ «ФЛАГ ITC» (патч 0005), одна переменная: бит ITC в пакете AVI InfoFrame, который карта шлёт монитору.
# NVIDIA 390 на этой карте ставит ITC=1 (запись 20.10), nouveau — 0. После перезагрузки флаг ВЫКЛЮЧЕН (как раньше).
#   itctest.sh on    — включить флаг: экран погаснет на ~3 с и включится (так пакет отправляется заново),
#                      затем проверка регистрами, что монитор действительно получает ITC=1
#   itctest.sh off   — выключить флаг так же
#   itctest.sh show  — только показать, что сейчас уходит в монитор
# Флаг живёт до перезагрузки. Режимы карты, частоты и остальное не трогаются.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P=/sys/module/nouveau/parameters/lab_hdmi_itc
[ -e "$P" ] || { echo "--- СТОП: в драйвере нет lab_hdmi_itc — нужен драйвер с патчем 0005 (lab.sh install) и перезагрузка"; exit 1; }
show() { sudo python3 "$HERE/hdmiregs.py" | grep -E 'SOR|ITC|HDMI' ; }
blink() {
    # гасим и включаем экран через GNOME (Mutter): драйвер выключает выход и при включении шлёт пакет AVI заново
    if gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
         --method org.freedesktop.DBus.Properties.Set org.gnome.Mutter.DisplayConfig PowerSaveMode '<int32 3>' >/dev/null 2>&1; then
        sleep 3
        gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
          --method org.freedesktop.DBus.Properties.Set org.gnome.Mutter.DisplayConfig PowerSaveMode '<int32 0>' >/dev/null 2>&1
        sleep 3; return 0
    fi
    echo "  (не получилось погасить экран через GNOME — пошевели мышью, если экран тёмный)"; return 1
}
case "${1:-}" in
on|off)
    V=$([ "$1" = on ] && echo 1 || echo 0)
    sudo -v || exit 1
    echo "=== Флаг ITC: $([ $V = 1 ] && echo ВКЛЮЧАЮ || echo выключаю). Экран погаснет на ~3 с."
    sudo sh -c "echo $V > $P"
    blink
    echo "--- что сейчас уходит в монитор:"
    show
    if sudo python3 "$HERE/hdmiregs.py" | grep -q "ITC): $([ $V = 1 ] && echo ДА || echo нет)"; then
        echo "=== Монитор получает ITC=$([ $V = 1 ] && echo 1 || echo 0) ✅ Теперь сравни текст."
    else
        echo "=== Пакет ещё старый. Смени в настройках экрана частоту обновления туда и обратно (или выйди из сеанса и войди) и проверь: bash ~/Home/nouveau-fix/lab/itctest.sh show"
    fi ;;
show) echo "lab_hdmi_itc = $(cat $P)"; show ;;
*) sed -n '2,8p' "$0"; exit 1 ;;
esac
