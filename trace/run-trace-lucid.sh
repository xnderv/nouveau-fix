#!/bin/bash
# ЗАПИСЬ mmiotrace первых драйверов NVIDIA (270.x, 2011) на GTX 560 Ti в Ubuntu 10.04 (раздел u1004-trace, ядро 2.6.32).
# Перенос run-trace.sh версии 7 (26.10): тот же сценарий, чтобы записи 270.x сравнивались с записью 390.157 (try7) один к одному.
# Отличия от версии для 22.04:
#  - у драйвера 270 нет модулей nvidia_modeset/nvidia_drm; версию драйвера modinfo не знает (в модуле 2011 года нет
#    MODULE_VERSION) — берём строку «Kernel Module 270.xx» из самого nvidia.ko;
#  - снимок регистров — regdump-lucid.py (Python 2.6); нет systemd/journalctl; нет Scroll Lock (в 2.6.32 светодиодов
#    клавиатуры в sysfs нет — из-за этого первая версия сценария молча выходила на первой же строке);
#  - на экран — короткие строки латиницей (кириллица в консоли 10.04 может не отображаться), подробно по-русски — в steps.txt;
#  - запись не сжимается здесь (старый xz не умеет потоки) — сжатие в основной системе (lucid-disk.sh get);
#  - сторож при срабатывании сохраняет ещё и журнал X — зависание 270.26 на запуске X само по себе результат;
#  - запись — только на «чистой» карте: после установки драйвера или прошлой записи в этой загрузке нужна перезагрузка
#    (как в try7: запись сразу после загрузки системы).
# Два прохода одного сценария подряд, без перезагрузки и без ввода команд:
#   1) КОНТРОЛЬ — драйвер и X без mmiotrace, все ядра процессора работают;
#   2) ЗАПИСЬ — драйвер выгружается, включается mmiotrace (остаётся одно ядро), драйвер грузится заново, тот же сценарий.
# Пока загружен драйвер NVIDIA, регистры карты НЕ читаются (снимков нет): в прогонах 1–6 снимки regdump сбивали драйвер.
# Сторож: Xid / «fallen off the bus» в журнале ядра или 120 с без новой отметки — сохранить журналы и ВЫКЛЮЧИТЬ машину
# (не перезагрузить: дважды после зависшей карты тёплый сброс давал пустой список дисков в BIOS; выключение обесточивает карту).
# Сценарий прохода (маленькая программа крутится всё время с синхронизацией кадров — лёгкая постоянная нагрузка, простоя нет):
#   0  «максимум», запуск маленькой (60 кадров/с)
#   A  адаптивный 45 с                             -> спуск под лёгкой нагрузкой
#   B  большая 25 с                                -> подъём под нагрузкой; большая снимается
#   C  30 с                                        -> снова спуск под лёгкой нагрузкой
#   D  «максимум» 10 с, «адаптивный» 25 с          -> 0f и спуск под лёгкой нагрузкой
#   E  всплески большой: 4 x (4 с, пауза 8 с)      -> резкие переходы
# Запуск: rec  (или sudo ~/trace/run-trace-lucid.sh)
#         rec1 (или sudo ~/trace/run-trace-lucid.sh only) — только запись, без контрольного прохода: драйвер под записью
#         грузится первый раз после включения. Проба 26.10 22:00: у 270.41.06 контроль прошёл, а запись (вторая загрузка
#         драйвера в той же сессии) повесила систему на запуске X — разделяем «повторная загрузка» и «сама запись на 2.6.32».   (~9 минут, ничего не трогать)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-}"   # only — без контрольного прохода
show() { echo ">>> $*"; }
nvver() {   # версия установленного драйвера NVIDIA по строке в самом модуле; пусто — не установлен
  local f; f="$(find "/lib/modules/$(uname -r)" -name nvidia.ko 2>/dev/null | head -n 1 || true)"
  [ -n "$f" ] && grep -ao 'Kernel Module  *[0-9][0-9.]*' "$f" | head -n 1 | awk '{print $NF}' || true
}
NV="$(nvver)"
[ -n "$NV" ] || { show "STOP: no NVIDIA driver installed. Install it first (nv1 or nv2)."; exit 1; }
if [ -e /tmp/stand-card-used ]; then
  show "STOP: the card was already used in this boot ($(cat /tmp/stand-card-used))."
  show "Reboot first (sudo reboot, F12 -> ST120FN0), then rec."
  exit 1
fi
lsmod | grep -q '^nvidia ' && { show "STOP: nvidia module is loaded. Reboot first (sudo reboot, F12 -> ST120FN0)."; exit 1; }
OUT="$HERE/out-$NV-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" >> "$LOG"; sync; }
SYSRQ=/proc/sysrq-trigger
echo "запись $NV" > /tmp/stand-card-used

show "RECORD: NVIDIA $NV, about 9 minutes. Do not touch anything until DONE."
say "Ядро $(uname -r), драйвер NVIDIA $NV, сценарий 7 для 10.04 (без снимков, со сторожем; контроль, затем запись)${MODE:+; режим $MODE — только запись}"
say "Время в 10.04 — UTC (в Москве +3 ч)"
say "Настройки модулей: $(grep -h -v '^#' /etc/modprobe.d/stand-2011.conf | tr '\n' ';')"
[ -e "$HERE/regdump-lucid.py" ] || { say "СТОП: нет regdump-lucid.py"; show "STOP: regdump-lucid.py missing"; exit 1; }
command -v glxgears >/dev/null || { say "СТОП: нет glxgears"; show "STOP: glxgears missing"; exit 1; }
mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true
T=/sys/kernel/debug/tracing
grep -qw mmiotrace "$T/available_tracers" || { say "СТОП: в ядре нет mmiotrace"; show "STOP: no mmiotrace in kernel"; exit 1; }
echo "$T" > /tmp/trace-dir
# Тот же xorg.conf, что в записи 390 (try7). Первая версия установщика (26.10) могла остановиться до него на проверке версии.
printf 'Section "Device"\n    Identifier "nv"\n    Driver "nvidia"\n    Option "Coolbits" "8"\nEndSection\n' > /etc/X11/xorg.conf
mark() { echo "MARK: $*" > "$T/trace_marker" 2>/dev/null || true; say "MARK: $*"; }

# Снимок только ДО загрузки драйвера: карту тогда никто не трогает.
python "$HERE/regdump-lucid.py" "0 до драйвера (после BIOS)" "$OUT/regs.txt"
say "Снимок регистров «до драйвера» сделан (дальше регистры не читаются)"

# Сторож: Xid / отвал от шины в журнале ядра или 120 с без новой отметки -> журналы на диск и выключение.
watchdog() {
  set +e   # сторож не должен умирать от ошибки одной команды
  while sleep 5; do
    if dmesg 2>/dev/null | grep -qE 'NVRM: Xid|fallen off the bus'; then why="в журнале ядра Xid / «GPU has fallen off the bus»"
    elif [ $(( $(date +%s) - $(stat -c %Y "$LOG") )) -gt 120 ]; then why="120 с без новой отметки сценария"
    else continue; fi
    say "СТОРОЖ: $why — сохраняю журналы и выключаю машину"
    chvt 1 2>/dev/null; show "WATCHDOG: driver stuck — saving logs and POWERING OFF. Then power on, F12, continue."
    dmesg > "$OUT/dmesg-watchdog.txt" 2>/dev/null; cp /var/log/Xorg.0.log "$OUT/Xorg-watchdog.log" 2>/dev/null
    ps axww > "$OUT/ps-watchdog.txt" 2>/dev/null
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
pm() { { echo "### \$P: PowerMizer=\$1 \$(date +%T)"; nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=\$1" 2>&1; } >> "\$OUT/nvsettings.txt" || true; }   # 0 адаптивный, 1 максимум
LIMIT=2000000000
big() { [ "\$(stat -c %s "\$OUT/mmiotrace.txt" 2>/dev/null || echo 0)" -gt "\$LIMIT" ]; }
guard() { big && { mark "запись больше 2 ГБ — фаза \$1 и дальше пропущены"; stop_all; exit 0; }; }
G1=""; G2=""
# В 10.04 каталог Mesa (/usr/lib/mesa) стоит в поиске библиотек раньше /usr/lib, где libGL драйвера NVIDIA (README 270.26,
# гл. 5 — «conflicting libraries»): без этого glxgears взял бы Mesa. В контроле записываем, чья библиотека работает.
export LD_LIBRARY_PATH=/usr/lib
[ "\$P" = контроль ] && glxinfo 2>&1 | grep -E "direct rendering|OpenGL (vendor|renderer|version)" > "\$OUT/glxinfo.txt"
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
  sleep 3
  mark "$1: драйвер загружен, запуск X11"
  ( sleep 20; grep -i nvidia /proc/interrupts >> "$LOG" 2>/dev/null; sync ) &   # MSI или общая линия — видно через 20 с
  make_session "$1"
  xinit /tmp/xsession.sh -- :0 vt2 >"$OUT/xinit-$1.txt" 2>&1 || true
  chvt 1 2>/dev/null || true
  mark "$1: X11 закрыт"
  cp /var/log/Xorg.0.log "$OUT/Xorg-$1.log" 2>/dev/null || true
  sleep 2
}

if [ "$MODE" != only ]; then
# Проход 1: контроль, без записи, все ядра работают.
show "[1/2] control pass (no recording): X with gears, ~4 min"
run_pass контроль
# Драйвер выгружается: mmiotrace видит только отображения регистров, сделанные ПОСЛЕ его включения.
ok=0
for i in 1 2 3 4 5; do
  modprobe -r nvidia 2>>"$LOG" && { ok=1; break; }
  sleep 2
done
if [ "$ok" != 1 ]; then
  kill "$WDPID" 2>/dev/null || true
  say "СТОП: драйвер nvidia не выгрузился за 5 попыток — запись невозможна. Контроль сделан, результат: $OUT"
  show "STOP: driver did not unload, recording impossible. Control pass saved. Reboot to main system (sudo reboot, no F12)."
  exit 1
fi
say "Контроль прошёл, драйвер выгружен"
fi

# Проход 2: запись.
show "[2/2] recording pass: other CPU cores switch off for a while (normal), ~5 min"
say "Включаю запись (остальные ядра процессора на время записи выключатся — это нормально)"
echo nop > "$T/current_tracer"
echo 65536 > "$T/buffer_size_kb"     # размер записи задаёт нагрузка, а не буфер
echo mmiotrace > "$T/current_tracer"
nice -n -20 cat "$T/trace_pipe" > "$OUT/mmiotrace.txt" &
CATPID=$!
sleep 2
run_pass запись
mark "конец записи"
kill "$WDPID" 2>/dev/null || true   # сторож снимается ДО остановки mmiotrace: в прогоне 7 остановка шла > 2 мин
show "stopping the recording (can take 1-2 minutes)..."
sleep 1
echo nop > "$T/current_tracer"
sleep 1; kill "$CATPID" 2>/dev/null || true
dmesg > "$OUT/dmesg.txt"
if grep -q 'mmiotrace has lost events' "$OUT/dmesg.txt"; then say "!!! Запись потеряла часть событий (буфер не успел)"; show "WARNING: the recording lost some events"
else say "Потерь в записи нет"; fi
[ -s "$OUT/mmiotrace.txt" ] && say "Записано строк: $(wc -l < "$OUT/mmiotrace.txt") (сжатие — в основной системе)"
ls -lh "$OUT" >> "$LOG"
sync
say "ГОТОВО. Результат: $OUT"
show "DONE. Saved: $(basename "$OUT") ($(du -sh "$OUT" | cut -f1))"
