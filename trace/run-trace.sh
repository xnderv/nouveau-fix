#!/bin/bash
# ЗАПИСЬ mmiotrace драйвера NVIDIA 390 на GTX 560 Ti (система u2204-trace). Версия 6 — «контроль и запись за один запуск» (24.10).
# Два прохода одного и того же сценария подряд, без перезагрузки и без ввода команд:
#   1) КОНТРОЛЬ — драйвер и X без mmiotrace, все ядра процессора работают;
#   2) ЗАПИСЬ — драйвер выгружается, включается mmiotrace (остаётся одно ядро), драйвер грузится заново, тот же сценарий.
# Зачем контроль: записи 3–5 под NVIDIA ломались (сброс записи 0x070000 не завершается, Xid 79 «GPU has fallen off the bus»).
# Если повиснет контроль — виноваты карта/драйвер NVIDIA под Linux, а не запись; если только запись — сама запись.
# Сценарий прохода (маленькая программа крутится всё время — простоя нет нигде; уровни меняют большая программа и PowerMizer):
#   0  «максимум», запуск двух glxgears (300x300 и 640x480) один раз; большая — на паузу (SIGSTOP), дальше только продолжение
#   A  адаптивный 45 с                             -> спуск под лёгкой нагрузкой (до 07 или 03 — решает NVIDIA)
#   B  продолжение большой 25 с                    -> подъём под нагрузкой
#   C  большая на паузе 30 с                       -> снова спуск под лёгкой нагрузкой
#   D  «максимум» 10 с, «адаптивный» 25 с          -> 0f и спуск под лёгкой нагрузкой
#   E  всплески большой: 5 x (3 с, пауза 6 с)      -> резкие переходы
# Уроки прошлых версий: снимка регистров между загрузкой драйвера и X нет (версия 2 на нём встала); regdump4 не читает
# блоки PMU и PFB; нагрузка — glxgears, не glmark2 (версия 1: 842 МБ за 1,5 мин); запись больше 2 ГБ — фазы пропускаются.
# Запуск: sudo ~/trace/run-trace.sh   (~9 минут, ничего не трогать; конец — строка «ГОТОВО»)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || [ "${TRACE_DRY:-0}" = 1 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }

say "Ядро $(uname -r), версия сценария 6 (контроль без записи, затем запись — за один запуск)"
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

python3 "$HERE/regdump4.py" "0 до драйвера (после BIOS)" "$OUT/regs.txt"
say "Снимок регистров «до драйвера» сделан"

make_session() {   # $1 — имя прохода; подписи меток и снимков начинаются с него
cat > /tmp/xsession.sh <<EOF
#!/bin/bash
T=\$(cat /tmp/trace-dir); OUT="$OUT"; HERE="$HERE"; P="$1"
mark() { echo "MARK: \$P: \$*" > "\$T/trace_marker" 2>/dev/null; echo "\$(date +%T) MARK: \$P: \$*" >> "\$OUT/steps.txt"; sync; }
snap() { mark "снимок: \$1"; python3 "\$HERE/regdump4.py" "\$P: \$1" "\$OUT/regs.txt"
         { echo "### \$P: \$1 \$(date +%T)"; nvidia-settings -t -q GPUCurrentPerfLevel -q GPUCurrentClockFreqs 2>&1; } >> "\$OUT/nvsettings.txt"; }
pm() { nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=\$1" >/dev/null 2>&1 || true; }   # 0 адаптивный, 1 максимум
LIMIT=2000000000
big() { [ "\$(stat -c %s "\$OUT/mmiotrace.txt" 2>/dev/null || echo 0)" -gt "\$LIMIT" ]; }
guard() { big && { mark "запись больше 2 ГБ — фаза \$1 и дальше пропущены"; snap "конец по размеру"; stop_loads; exit 0; }; }
G1=""; G2=""
start_loads() { __GL_SYNC_TO_VBLANK=0 glxgears -geometry 300x300+40+40 >/dev/null 2>&1 & G1=\$!
                __GL_SYNC_TO_VBLANK=0 glxgears -geometry 640x480+380+40 >/dev/null 2>&1 & G2=\$!; }
alive() { kill -0 "\$1" 2>/dev/null || mark "!!! программа нагрузки \$1 не работает"; }
go()   { alive "\$1"; kill -CONT "\$1" 2>/dev/null; }   # продолжить рисовать
halt() { kill -STOP "\$1" 2>/dev/null; }                # остановить, память остаётся за программой
stop_loads() { kill -9 \$G1 \$G2 2>/dev/null; }
sleep 3
mark "0 максимум, запуск обеих программ; большая — на паузу, маленькая крутится всё время"
pm 1; sleep 2
start_loads; sleep 4
halt \$G2
pm 0
mark "A адаптивный 45 с, крутится только маленькая (спуск под лёгкой нагрузкой)"
sleep 45
snap "A лёгкая нагрузка"
guard B
mark "B продолжение большой 25 с (подъём под нагрузкой)"
go \$G2; sleep 20
snap "B обе программы"
sleep 5; halt \$G2
mark "C большая на паузе, 30 с (спуск под лёгкой нагрузкой)"
sleep 30
snap "C лёгкая нагрузка"
guard D
mark "D максимум 10 с (0f под лёгкой нагрузкой)"
pm 1; sleep 10
snap "D максимум"
mark "D адаптивный 25 с (спуск под лёгкой нагрузкой)"
pm 0; sleep 25
snap "D адаптивный"
guard E
mark "E всплески большой: 5 x (продолжение 3 с, пауза 6 с), маленькая крутится"
for i in 1 2 3 4 5; do
  mark "E всплеск \$i"; go \$G2; sleep 3; halt \$G2; sleep 6
done
snap "E после всплесков"
mark "конец прохода: обе программы снимаются"
stop_loads
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

# Проход 1: контроль, без записи, все ядра работают.
run_pass контроль
# Драйвер выгружается: mmiotrace видит только отображения регистров, сделанные ПОСЛЕ его включения.
systemctl stop nvidia-persistenced 2>/dev/null || true
if ! modprobe -r nvidia_drm nvidia_modeset nvidia 2>>"$LOG"; then
  say "СТОП: драйвер nvidia не выгрузился — записать его заново нельзя. Контроль сделан, результат: $OUT"
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
