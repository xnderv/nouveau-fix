#!/bin/bash
# ПРОВЕРКА «НАШ ЛИ ДРАЙВЕР» (28.10): при входе в систему (автозапуск, модальное окно) и в начале наших скриптов.
#   daily/check-driver.sh            — напечатать состояние; код 0 — всё в порядке, 1 — есть проблема
#   daily/check-driver.sh --gui      — то же + окно zenity с кнопкой «Собрать драйвер сейчас», если что-то не так
#   daily/check-driver.sh --banner   — только предупреждение для начала наших скриптов (код всегда 0)
#   daily/check-driver.sh install-autostart | remove-autostart — включить/выключить окно при входе (без пароля)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$(uname -r)"; NEWEST="$(ls -1 /lib/modules | sort -V | tail -n 1)"
drv() { [ -e "/lib/modules/$1/updates/nouveau-fix/nouveau.ko" ] && { echo лабораторный; return; }; [ -e "/lib/modules/$1/updates/dkms/nouveau.ko" ] && { echo "стабильный (DKMS)"; return; }; echo ""; }
case "${1:-}" in
install-autostart)
    mkdir -p "$HOME/.config/autostart"
    sed "s|@HOME@|$HOME|g" "$HERE/nouveau-fix-check.desktop" > "$HOME/.config/autostart/nouveau-fix-check.desktop" && echo "проверка при входе включена: ~/.config/autostart/nouveau-fix-check.desktop"; exit 0 ;;
remove-autostart) rm -f "$HOME/.config/autostart/nouveau-fix-check.desktop"; echo "проверка при входе выключена"; exit 0 ;;
esac
PROBLEMS=()
LOADED="$(modinfo -n nouveau 2>/dev/null)"
if [ -e /sys/module/nouveau/parameters/lab_core ]; then LOADED_KIND="лабораторный"
elif [[ "$LOADED" == */updates/dkms/* ]]; then LOADED_KIND="стабильный (DKMS)"
else LOADED_KIND=""; fi
[ -n "$LOADED_KIND" ] || PROBLEMS+=("Сейчас работает ядро $RUN со ШТАТНЫМ nouveau: гонка в Chromium-программах (зависания), частоты не управляются.")
if [ "$NEWEST" != "$RUN" ] && [ -z "$(drv "$NEWEST")" ]; then
    SAVED="$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')"
    if [[ "$SAVED" == *"$RUN"* ]]; then PROBLEMS+=("Установлено новое ядро $NEWEST, драйвер под него не собран. GRUB закреплён на $RUN, так что перезагрузка пока безопасна.")
    else PROBLEMS+=("Установлено новое ядро $NEWEST, драйвер под него НЕ собран, и GRUB НЕ закреплён: следующая перезагрузка загрузит его со штатным nouveau."); fi
fi
for p in /var/lib/nouveau-fix/pending-*; do [ -e "$p" ] || continue; k="${p##*/pending-}"; [ -n "$(drv "$k")" ] && continue; [ "$k" = "$NEWEST" ] && continue; PROBLEMS+=("Ядро $k ждёт сборки драйвера."); done
if [ ${#PROBLEMS[@]} -eq 0 ]; then
    [ "${1:-}" = --banner ] || echo "драйвер: $LOADED_KIND, ядро $RUN (самое новое: $NEWEST) — в порядке"
    exit 0
fi
MSG="$(printf '%s\n' "${PROBLEMS[@]}")"
case "${1:-}" in
--banner) echo "!!! ДРАЙВЕР/ЯДРО: $MSG" | sed '2,$s/^/!!! /'; echo "!!! Что делать: ~/Home/nouveau-fix/newkernel.sh (сборка под новое ядро), daily/grub-pin.sh status"; exit 0 ;;
--gui)
    command -v zenity >/dev/null || { notify-send -a 'Драйвер видеокарты' -u critical -i video-display "GTX 560 Ti: нужен наш драйвер" "$MSG"; exit 1; }
    if zenity --question --title="Драйвер видеокарты GTX 560 Ti" --width=560 --icon=video-display --ok-label="Собрать драйвер сейчас" --cancel-label="Позже" \
         --text="$MSG

Кнопка откроет окно терминала со сборкой (спросит пароль). После сборки ядро закрепляется в GRUB, потом перезагрузка."; then
        exec "$HERE/open-newkernel.sh"
    fi
    exit 1 ;;
*) echo "$MSG"; echo "Что делать: ~/Home/nouveau-fix/newkernel.sh; состояние GRUB: daily/grub-pin.sh status"; exit 1 ;;
esac
