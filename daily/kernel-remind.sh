#!/bin/sh
# Ставится в /etc/kernel/postinst.d/ — Ubuntu вызывает его при установке каждого нового ядра ($1 = версия).
# Ничего не собирает: только запись в журнал, отметка и уведомление на рабочий стол.
V="$1"
[ -n "$V" ] || exit 0
mkdir -p /var/lib/nouveau-fix && : > "/var/lib/nouveau-fix/pending-$V"
MSG="Пришло новое ядро $V. До перезагрузки выполни: ~/Home/nouveau-fix/newkernel.sh"
logger -t nouveau-fix "$MSG"
for B in /run/user/*/bus; do
    [ -S "$B" ] || continue
    U="$(stat -c %U "$B")"; I="$(stat -c %u "$B")"
    [ "$I" -ge 1000 ] || continue
    H="$(getent passwd "$U" | cut -d: -f6)"
    N="$H/Home/nouveau-fix/daily/notify-newkernel.sh"
    [ -x "$N" ] || continue
    # в фоне и отдельно от установки ядра: apt не ждёт, пока ты нажмёшь кнопку
    sudo -u "$U" env DBUS_SESSION_BUS_ADDRESS="unix:path=$B" XDG_RUNTIME_DIR="/run/user/$I" \
        setsid -f "$N" newkernel "$V" >/dev/null 2>&1 </dev/null || true
done
exit 0
