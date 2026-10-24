#!/bin/bash
# ЗАПИСЬ mmiotrace драйвера NVIDIA 390 на GTX 560 Ti (система u2204-trace). Версия 7 — «без снимков, со сторожем» (24.10).
# Два прохода одного сценария подряд, без перезагрузки и без ввода команд:
#   1) КОНТРОЛЬ — драйвер и X без mmiotrace, все ядра процессора работают;
#   2) ЗАПИСЬ — драйвер выгружается, включается mmiotrace (остаётся одно ядро), драйвер грузится заново, тот же сценарий.
# Главное изменение: пока загружен драйвер NVIDIA, регистры карты НЕ читаются (снимков нет). Во всех шести прошлых прогонах
# отказ начинался через 0,1–2 с после снимка regdump: try2 — зависание на запуске X, try3/4 — сброс записи 0x070000 не
# завершается, try5 и контроль try6 (без записи!) — «Xid 79, GPU has fallen off the bus». Снимок читает блоки целиком —
# видимо, с несуществующими адресами — и сбивает работающий драйвер. Состояние уровней видно в самой записи.
# Индикаторы: Scroll Lock мигает (ядро, триггер heartbeat) — система жива; маленькие шестерёнки крутятся всё время — жива карта.
# Сторож: Xid / «fallen off the bus» в журнале ядра или 120 с без новой отметки — сохранить журналы и ВЫКЛЮЧИТЬ машину
# (не перезагрузить: дважды после зависшей карты тёплый сброс давал пустой список дисков в BIOS; выключение обесточивает карту).
# Сценарий прохода (маленькая программа крутится всё время с синхронизацией кадров — лёгкая постоянная нагрузка, простоя нет;
# большая программа без синхронизации запускается и снимается, без пауз SIGSTOP — от них в контроле try6 «nvLock: client timed out»):
#   0  «максимум», запуск маленькой (60 кадров/с)
#   A  адаптивный 45 с                             -> спуск под лёгкой нагрузкой
#   B  большая 25 с                                -> подъём под нагрузкой; большая снимается
#   C  30 с                                        -> снова спуск под лёгкой нагрузкой
#   D  «максимум» 10 с, «адаптивный» 25 с          -> 0f и спуск под лёгкой нагрузкой
#   E  всплески большой: 4 x (4 с, пауза 8 с)      -> резкие переходы
# Запуск: sudo ~/trace/run-trace.sh   (~9 минут, ничего не трогать; конец — строка «ГОТОВО»)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || [ "${TRACE_DRY:-0}" = 1 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }
SYSRQ="${TRACE_SYSRQ:-/proc/sysrq-trigger}"
LED="${TRACE_LED:-$(ls -d /sys/class/leds/input*::scrolllock 2>/dev/null | head -n 1)}"

say "Ядро $(uname -r), версия сценария 7 (без снимков, со сторожем; контроль, затем запись)"
lsmod | grep -q '^nvidia ' && { say "СТОП: драйвер nvidia уже загружен — перезагрузись."; exit 1; }
[ -e "$HERE/regdump4.py" ] || { say "СТОП: нет $HERE/regdump4.py"; exit 1; }
command -v glxgears >/dev/null || { say "СТОП: нет glxgears (пакет mesa-utils)"; exit 1; }
T="${TRACE_DIR:-}"
if [ -z "$T" ]; then
  grep -q tracefs /proc/mounts || mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
  T=/sys/kernel/tracing; [ -e "$T/current_tracer" ] || { mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true; T=/sys/kernel/debug/tracing; }
fi
grep -qw mmiotrace "$T/available_tracers" || { say "СТОП: в ядре нет mmiotrace"; exit 1; }
echo "$T" > /tmp/trace-dir
mark() { echo "MARK: $*" > "$T/trace_marker" 2>/dev/null || true; say "MARK: $*"; }

# Снимок только ДО загрузки драйвера: карту тогда никто не трогает.
python3 "$HERE/regdump4.py" "0 до драйвера (после BIOS)" "$OUT/regs.txt"
say "Снимок регистров «до драйвера» сделан (дальше регистры не читаются)"

# Индикатор «система жива»: Scroll Lock мигает от ядра. Если ядро встанет — мигание прекратится.
LED_OLD=""
if [ -n "$LED" ]; then
  modprobe ledtrig-heartbeat 2>/dev/null || true
  LED_OLD="$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$LED/trigger" 2>/dev/null)"
  echo heartbeat > "$LED/trigger" 2>/dev/null && say "Scroll Lock мигает — система жива" || say "Scroll Lock мигать не будет (нет триггера)"
fi

# Сторож: Xid / отвал от шины в журнале ядра или 120 с без новой отметки -> журналы на диск и выключение.
watchdog() {
  while sleep 5; do
    if dmesg 2>/dev/null | grep -qE 'NVRM: Xid|fallen off the bus'; then why="в журнале ядра Xid / «GPU has fallen off the bus»"
    elif [ $(( $(date +%s) - $(stat -c %Y "$LOG") )) -gt 120 ]; then why="120 с без новой отметки сценария"
    else continue; fi
    say "СТОРОЖ: $why — сохраняю журналы и выключаю машину"
    dmesg > "$OUT/dmesg-watchdog.txt" 2>/dev/null; journalctl -b 0 -o short-precise --no-pager > "$OUT/journal-watchdog.txt" 2>/dev/null
    echo nop > "$T/current_tracer" 2>/dev/null; sync; sleep 3; sync
    echo s > "$SYSRQ"; sleep 3; echo u > "$SYSRQ"; sleep 2; echo o > "$SYSRQ"
    exit 0
  done
}
watchdog & WDPID=$!

make_session() {   # $1 — имя прохода; подписи меток начинаются с него
cat > /tmp/xsession.sh <<EOF
#!/bin/bash
T=\$(cat /tmp/trace-dir); OUT="$OUT"; P="$1"
mark() { echo "MARK: \$P: \$*" > "\$T/trace_marker" 2>/dev/null; echo "\$(date +%T) MARK: \$P: \$*" >> "\$OUT/steps.txt"; sync; }
level() { { echo "### \$P: \$1 \$(date +%T)"; nvidia-settings -t -q GPUCurrentPerfLevel -q GPUCurrentClockFreqs 2>&1; } >> "\$OUT/nvsettings.txt"; }
pm() { nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=\$1" >/dev/null 2>&1 || true; }   # 0 адаптивный, 1 максимум
LIMIT=2000000000
big() { [ "\$(stat -c %s "\$OUT/mmiotrace.txt" 2>/dev/null || echo 0)" -gt "\$LIMIT" ]; }
guard() { big && { mark "запись больше 2 ГБ — фаза \$1 и дальше пропущены"; stop_all; exit 0; }; }
G1=""; G2=""
small_on() { __GL_SYNC_TO_VBLANK=1 glxgears -geometry 300x300+40+40 >/dev/null 2>&1 & G1=\$!; }      # 60 кадров/с — лёгкая
big_on()   { __GL_SYNC_TO_VBLANK=0 glxgears -geometry 640x480+380+40 >/dev/null 2>&1 & G2=\$!; }     # без синхронизации — тяжёлая
big_off()  { [ -n "\$G2" ] && { kill "\$G2" 2>/dev/null; wait "\$G2" 2>/dev/null; G2=""; }; }
stop_all() { big_off; [ -n "\$G1" ] && { kill "\$G1" 2>/dev/null; wait "\$G1" 2>/dev/null; }; }
sleep 3
mark "0 максимум, запуск маленькой программы (крутится до конца прохода)"
pm 1; sleep 2
small_on; sleep 5
pm 0
mark "A адаптивный 45 с, лёгкая нагрузка (спуск под нагрузкой)"
sleep 45
level "A"
guard B
mark "B большая программа 25 с (подъём под нагрузкой)"
big_on; sleep 25
level "B"
big_off
mark "C большая снята, 30 с (спуск под лёгкой нагрузкой)"
sleep 30
level "C"
guard D
mark "D максимум 10 с (0f под лёгкой нагрузкой)"
pm 1; sleep 10
level "D максимум"
mark "D адаптивный 25 с (спуск под лёгкой нагрузкой)"
pm 0; sleep 25
level "D адаптивный"
guard E
mark "E всплески большой: 4 x (4 с, пауза 8 с)"
for i in 1 2 3 4; do
  mark "E всплеск \$i"; big_on; sleep 4; big_off; sleep 8
done
level "E"
mark "конец прохода: программы снимаются"
stop_all
EOF
chmod +x /tmp/xsession.sh
}

run_pass() {   # $1 — имя прохода
  mark "== проход «$1»: загрузка драйвера nvidia"
  modprobe nvidia
  modprobe nvidia_modeset
  modprobe nvidia_drm
  sleep 3
  mark "$1: драйвер загружен, запуск X11"
  make_session "$1"
  xinit /tmp/xsession.sh -- :0 vt2 >"$OUT/xinit-$1.txt" 2>&1 || true
  mark "$1: X11 закрыт"
  cp /var/log/Xorg.0.log "$OUT/Xorg-$1.log" 2>/dev/null || true
  sleep 2
}

finish() {   # сторож больше не нужен; Scroll Lock — как было
  kill "$WDPID" 2>/dev/null || true
  [ -n "$LED" ] && [ -n "$LED_OLD" ] && echo "$LED_OLD" > "$LED/trigger" 2>/dev/null || true
}

# Проход 1: контроль, без записи, все ядра работают.
run_pass контроль
# Драйвер выгружается: mmiotrace видит только отображения регистров, сделанные ПОСЛЕ его включения.
systemctl stop nvidia-persistenced 2>/dev/null || true
ok=0
for i in 1 2 3 4 5; do
  modprobe -r nvidia_drm nvidia_modeset nvidia 2>>"$LOG" && { ok=1; break; }
  sleep 2
done
if [ "$ok" != 1 ]; then
  finish
  say "СТОП: драйвер nvidia не выгрузился за 5 попыток — запись невозможна. Контроль сделан, результат: $OUT"
  say "Перезагрузись в основную систему: sudo reboot"
  exit 1
fi
say "Контроль прошёл, драйвер выгружен"

# Проход 2: запись.
say "Включаю запись (остальные ядра процессора на время записи выключатся — это нормально)"
echo nop > "$T/current_tracer"
echo 65536 > "$T/buffer_size_kb"     # размер записи задаёт нагрузка, а не буфер
echo mmiotrace > "$T/current_tracer"
nice -n -20 cat "$T/trace_pipe" > "$OUT/mmiotrace.txt" &
CATPID=$!
sleep 2
run_pass запись
mark "конец записи"
finish   # сторож снимается ДО остановки mmiotrace: в прогоне 7 остановка шла > 2 мин, и сторож выключил машину
sleep 1
echo nop > "$T/current_tracer"
sleep 1; kill "$CATPID" 2>/dev/null || true
dmesg > "$OUT/dmesg.txt"
grep -q 'mmiotrace has lost events' "$OUT/dmesg.txt" && say "!!! Запись потеряла часть событий (буфер не успел)" || say "Потерь в записи нет"
if [ -s "$OUT/mmiotrace.txt" ]; then
  say "Записано строк: $(wc -l < "$OUT/mmiotrace.txt"). Сжимаю..."
  xz -T0 -6 "$OUT/mmiotrace.txt"
fi
ls -lh "$OUT" | tee -a "$LOG"
sync
say "ГОТОВО. Результат: $OUT. Перезагрузись в основную систему: sudo reboot"
