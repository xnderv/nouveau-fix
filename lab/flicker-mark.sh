#!/bin/bash
# Отметка «МИГНУЛО»: время с миллисекундами в ~/Home/nouveau-fix/results/flicker-marks.txt (+ короткий звук-щелчок, если есть).
# Вешается на сочетание клавиш:  flicker-mark.sh key-on   /  убрать:  flicker-mark.sh key-off
F="$HOME/Home/nouveau-fix/results/flicker-marks.txt"
KEY='<Control><Alt>m'
BASE=org.gnome.settings-daemon.plugins.media-keys
PATHK=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/flicker-mark/
case "${1:-}" in
key-on)
    python3 - "$PATHK" <<'PY'
import ast, subprocess, sys
p = sys.argv[1]
cur = subprocess.run(['gsettings', 'get', 'org.gnome.settings-daemon.plugins.media-keys', 'custom-keybindings'],
                     capture_output=True, text=True).stdout.strip()
lst = [] if cur.startswith('@as') else ast.literal_eval(cur)
if p not in lst:
    lst.append(p)
subprocess.run(['gsettings', 'set', 'org.gnome.settings-daemon.plugins.media-keys', 'custom-keybindings', str(lst)], check=True)
print('Список сочетаний:', lst)
PY
    S="$BASE.custom-keybinding:$PATHK"
    gsettings set "$S" name 'Отметка: мигнуло'
    gsettings set "$S" command "$HOME/Home/nouveau-fix/lab/flicker-mark.sh"
    gsettings set "$S" binding "$KEY"
    echo "Готово: Ctrl+Alt+M пишет отметку в $F" ;;
key-off)
    python3 - "$PATHK" <<'PY'
import ast, subprocess, sys
p = sys.argv[1]
cur = subprocess.run(['gsettings', 'get', 'org.gnome.settings-daemon.plugins.media-keys', 'custom-keybindings'],
                     capture_output=True, text=True).stdout.strip()
lst = [] if cur.startswith('@as') else ast.literal_eval(cur)
lst = [x for x in lst if x != p]
subprocess.run(['gsettings', 'set', 'org.gnome.settings-daemon.plugins.media-keys', 'custom-keybindings', str(lst)], check=True)
print('Сочетание убрано. Список:', lst)
PY
    ;;
*)
    mkdir -p "$(dirname "$F")"
    T="$(date '+%H:%M:%S.%3N')"; echo "$T МИГНУЛО $(date +%s.%3N)" >> "$F"
    command -v canberra-gtk-play >/dev/null && canberra-gtk-play -i bell >/dev/null 2>&1 & ;;
esac
