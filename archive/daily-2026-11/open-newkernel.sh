#!/bin/bash
# Открывает окно терминала и запускает ~/Home/nouveau-fix/newkernel.sh. Сам находит, какой терминал установлен
# (в новых Ubuntu это Ptyxis, раньше — gnome-terminal).
RUN="$HOME/Home/nouveau-fix/newkernel.sh; echo; read -r -p 'Готово. Нажми Enter, чтобы закрыть окно.' _"
if command -v ptyxis >/dev/null; then exec ptyxis --new-window -- bash -c "$RUN"
elif command -v gnome-terminal >/dev/null; then exec gnome-terminal -- bash -c "$RUN"
elif command -v kgx >/dev/null; then exec kgx -- bash -c "$RUN"
elif command -v x-terminal-emulator >/dev/null; then exec x-terminal-emulator -e bash -c "$RUN"
else notify-send -u critical "Не нашёл терминал" "Открой терминал сам и выполни: ~/Home/nouveau-fix/newkernel.sh"
fi
