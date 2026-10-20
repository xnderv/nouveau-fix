#!/bin/bash
# ЗАПИСЬ mmiotrace драйвера NVIDIA 390 на GTX 560 Ti (система u2204-trace). Версия 2 — «лёгкая».
# Урок 1-й попытки: под записью любое обращение к карте в сотни раз медленнее, тяжёлый glmark2
# в окне 1600x900 и опрос nvidia-settings каждые 2 с переполнили запись и повесили систему.
# Теперь: маленький glxgears 300x300, nvidia-settings только в точках снимков, весь сценарий ~1 мин.
# Этапы (метки MARK в записи):
#   0 снимок регистров до драйвера
#   1 загрузка nvidia + nvidia_modeset + nvidia_drm (запуск PMU, отпирание, начальные частоты)
#   2 X11 без окон, простой
#   3 PowerMizer «максимум» + glxgears 15 с → переход в 0f (смена памяти, PLL ядра, напряжение)
#   4 PowerMizer «адаптивный», простой 30 с → спуск в 07/03
# Запуск: sudo ~/trace/run-trace.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }

say "Ядро $(uname -r), версия сценария 2 (лёгкая)"
lsmod | grep -q '^nvidia ' && { say "СТОП: драйвер nvidia уже загружен — начало не запишется. Перезагрузись."; exit 1; }
grep -q tracefs /proc/mounts || mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
T=/sys/kernel/tracing; [ -e "$T/current_tracer" ] || { mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true; T=/sys/kernel/debug/tracing; }
grep -qw mmiotrace "$T/available_tracers" || { say "СТОП: в ядре нет mmiotrace"; exit 1; }
echo "$T" > /tmp/trace-dir

python3 "$HERE/regdump.py" "0 до драйвера (после BIOS)" "$OUT/regs.txt"
say "Снимок регистров «до драйвера» сделан"

say "Включаю запись (остальные ядра процессора на время записи выключатся — это нормально)"
echo nop > "$T/current_tracer"
echo 65536 > "$T/buffer_size_kb"
echo mmiotrace > "$T/current_tracer"
nice -n -20 cat "$T/trace_pipe" > "$OUT/mmiotrace.txt" &
CATPID=$!
sleep 2
mark() { echo "MARK: $*" > "$T/trace_marker"; say "MARK: $*"; }

mark "1 загрузка драйвера nvidia"
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_drm
sleep 3
mark "1 драйвер загружен"
python3 "$HERE/regdump.py" "1 драйвер загружен, X11 ещё нет" "$OUT/regs.txt"

cat > /tmp/xsession.sh <<EOF
#!/bin/bash
T=\$(cat /tmp/trace-dir); OUT="$OUT"; HERE="$HERE"
mark() { echo "MARK: \$*" > "\$T/trace_marker"; echo "\$(date +%T) MARK: \$*" >> "\$OUT/steps.txt"; sync; }
snap() { mark "снимок: \$1"; python3 "\$HERE/regdump.py" "\$1" "\$OUT/regs.txt"
         { echo "### \$1 \$(date +%T)"; nvidia-settings -t -q GPUCurrentPerfLevel -q GPUCurrentClockFreqs 2>&1; } >> "\$OUT/nvsettings.txt"; }
sleep 3
mark "2 X11 запущен, простой"
snap "2 X11, простой"
mark "3 PowerMizer максимум + glxgears 15 с (ожидаю 0f)"
nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=1' >/dev/null 2>&1 || true
__GL_SYNC_TO_VBLANK=0 timeout 15 glxgears -geometry 300x300+50+50 >/dev/null 2>&1 || true
snap "3 после нагрузки, максимум"
mark "4 PowerMizer адаптивный, простой 30 с (спуск)"
nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=0' >/dev/null 2>&1 || true
sleep 30
snap "4 простой 30 с"
mark "5 выход из X11"
EOF
chmod +x /tmp/xsession.sh
mark "2 запуск X11"
xinit /tmp/xsession.sh -- :0 vt2 >"$OUT/xinit.txt" 2>&1 || true
mark "X11 закрыт"
sleep 2
mark "конец записи"
sleep 1
echo nop > "$T/current_tracer"
sleep 1; kill "$CATPID" 2>/dev/null || true
cp /var/log/Xorg.0.log "$OUT/" 2>/dev/null || true
dmesg > "$OUT/dmesg.txt"
grep -q 'mmiotrace has lost events' "$OUT/dmesg.txt" && say "!!! Запись потеряла часть событий (буфер не успел)" || say "Потерь в записи нет"
say "Записано строк: $(wc -l < "$OUT/mmiotrace.txt"). Сжимаю..."
xz -T0 -6 "$OUT/mmiotrace.txt"
ls -lh "$OUT" | tee -a "$LOG"
sync
say "ГОТОВО. Результат: $OUT. Перезагрузись в основную систему: sudo reboot"
