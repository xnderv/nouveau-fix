#!/usr/bin/env python3
# Режим монитора через Mutter (GNOME, Wayland) — ВРЕМЕННО (method 1): не сохраняется в monitors.xml, после перезагрузки
# или нового входа возвращается сохранённый режим.
#   python3 monmode.py            — показать текущий режим
#   python3 monmode.py РЕЖИМ      — поставить режим (id из списка Mutter, например 1920x1080@120.000)
import sys
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
call = lambda m, a=None: bus.call_sync('org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
                                       'org.gnome.Mutter.DisplayConfig', m, a, None, 0, -1, None)
serial, monitors, logical, props = call('GetCurrentState').unpack()
conn = monitors[0][0][0]
cur = next(m[0] for m in monitors[0][1] if m[6].get('is-current'))
if len(sys.argv) < 2:
    print(conn, cur)
    sys.exit(0)
mode = sys.argv[1]
if mode not in [m[0] for m in monitors[0][1]]:
    sys.exit(f'нет режима {mode} у {conn}')
x, y, scale, transform, primary = logical[0][:5]
lm = [(x, y, scale, transform, primary, [(conn, mode, {})])]
call('ApplyMonitorsConfig', GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})', (serial, 1, lm, {})))
print(conn, 'режим', mode, '(временно)')
