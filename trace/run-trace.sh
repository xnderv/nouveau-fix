#!/bin/bash
# ЗАПИСЬ mmiotrace драйвера NVIDIA 390 на GTX 560 Ti (система u2204-trace). Версия 4 — «переходы под нагрузкой, нагрузка паузой» (24.10).
# Основа — версия 2 (запуск записи, драйвера и X11), но без её снимка перед X11 (см. ниже); нагрузка — как в версии 1, но без того, что её
# повесило: опроса nvidia-settings каждые 2 с и glmark2 1600x900. Уровень карты виден в самой записи (мультиплексор,
# делители, PLL), nvidia-settings — только в точках снимков.
# Зачем: в записях 1 и 2 переходы были только при старте X на пустой карте; нет ни одного перехода под нагрузкой и
# ни одного подъёма 03 -> 07. Смотрим: где скобка PTHERM и сколько NVIDIA ждёт, пост-делители GPC/hubk06 на 03 <-> 07,
# порядок hubk07/hubk06/hubk01 и памяти, PXBAR, 0x001548, 0x00e9e0, 0x022680, второе поле делителей.
# Фазы — от безопасных к рискованным (зависание обрывает запись, но всё до него уже на диске):
#   0  «максимум», запуск двух glxgears (300x300, 640x480), через 4 с — пауза обоим (SIGSTOP); дальше их только продолжают
#   A  простой 60 с                               -> карта сама опускается до 03
#   B  PowerMizer «максимум» в простое 10 с        -> 03 -> 0f без нагрузки; «адаптивный» 45 с -> спуск без нагрузки
#   C  продолжение 300x300 на 03, 30 с             -> подъём из 03 под нагрузкой (07 или 0f — решает NVIDIA)
#   D  300x300 + «максимум» 10 с                   -> 0f под нагрузкой; «адаптивный» 30 с с нагрузкой -> спуск под нагрузкой
#   E  всплески: 5 x (продолжение 3 с, пауза 6 с)  -> резкие переходы
#   F  продолжение 640x480, 30 с                   -> окно крупнее, последней
# Версия 4 (после записей 3 и 4, обе встали в C через 1,5–2 с после запуска glxgears на 03): драйвер NVIDIA обнулял
# 288 КБ под новую программу и бесконечно ждал сброса записи 0x070000 — первая крупная запись в память карты после простоя.
# Поэтому память под нагрузку выделяется один раз, пока карта на 0f, а дальше программы только ставятся на паузу.
#   Если запись перевалила за 2 ГБ, оставшиеся фазы пропускаются.
# Запуск: sudo ~/trace/run-trace.sh   (~8 минут, ничего не трогать; конец — строка «ГОТОВО»)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }

say "Ядро $(uname -r), версия сценария 4 (нагрузка паузой и продолжением)"
lsmod | grep -q '^nvidia ' && { say "СТОП: драйвер nvidia уже загружен — начало не запишется. Перезагрузись."; exit 1; }
[ -e "$HERE/regdump4.py" ] || { say "СТОП: нет $HERE/regdump4.py"; exit 1; }
command -v glxgears >/dev/null || { say "СТОП: нет glxgears (пакет mesa-utils)"; exit 1; }
grep -q tracefs /proc/mounts || mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
T=/sys/kernel/tracing; [ -e "$T/current_tracer" ] || { mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true; T=/sys/kernel/debug/tracing; }
grep -qw mmiotrace "$T/available_tracers" || { say "СТОП: в ядре нет mmiotrace"; exit 1; }
echo "$T" > /tmp/trace-dir

python3 "$HERE/regdump4.py" "0 до драйвера (после BIOS)" "$OUT/regs.txt"
say "Снимок регистров «до драйвера» сделан"

say "Включаю запись (остальные ядра процессора на время записи выключатся — это нормально)"
echo nop > "$T/current_tracer"
echo 65536 > "$T/buffer_size_kb"     # как в версии 2. Размер записи задаёт не буфер, а нагрузка: 842 МБ в версии 1 — от glmark2 1600x900
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
# Снимка между загрузкой драйвера и X11 НЕТ, как в версии 1. Версия 2 делала его (regdump.py, с блоком PMU) и зависла ровно
# на запуске X11; версия 1 без него X11 запустила. Блок PMU читать под NVIDIA нельзя (regdump3/4 его не читают).

cat > /tmp/xsession.sh <<EOF
#!/bin/bash
T=\$(cat /tmp/trace-dir); OUT="$OUT"; HERE="$HERE"
mark() { echo "MARK: \$*" > "\$T/trace_marker"; echo "\$(date +%T) MARK: \$*" >> "\$OUT/steps.txt"; sync; }
snap() { mark "снимок: \$1"; python3 "\$HERE/regdump4.py" "\$1" "\$OUT/regs.txt"
         { echo "### \$1 \$(date +%T)"; nvidia-settings -t -q GPUCurrentPerfLevel -q GPUCurrentClockFreqs 2>&1; } >> "\$OUT/nvsettings.txt"; }
pm() { nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=\$1" >/dev/null 2>&1 || true; }   # 0 адаптивный, 1 максимум
LIMIT=2000000000   # запись больше 2 ГБ — дальше фазы не идут (в версии 1 тяжёлая нагрузка дала 842 МБ за 1,5 мин и повесила систему)
big() { [ "\$(stat -c %s "\$OUT/mmiotrace.txt" 2>/dev/null || echo 0)" -gt "\$LIMIT" ]; }
guard() { big && { mark "запись больше 2 ГБ — фаза \$1 и дальше пропущены"; snap "конец по размеру"; stop_loads; exit 0; }; }
# Версия 4: программы нагрузки запускаются ОДИН раз, сразу после X на «максимуме» (0f), и дальше только
# останавливаются / продолжаются (SIGSTOP / SIGCONT) — драйверу больше не нужно выделять и обнулять память.
# Записи 3 и 4 зависли ровно на этом: первая крупная запись драйвера в память карты после 2 мин простоя на 03.
G1=""; G2=""
start_loads() { __GL_SYNC_TO_VBLANK=0 glxgears -geometry 300x300+40+40 >/dev/null 2>&1 & G1=\$!
                __GL_SYNC_TO_VBLANK=0 glxgears -geometry 640x480+380+40 >/dev/null 2>&1 & G2=\$!; }
alive() { kill -0 "\$1" 2>/dev/null || mark "!!! программа нагрузки \$1 не работает"; }
go()   { alive "\$1"; kill -CONT "\$1" 2>/dev/null; }   # продолжить рисовать
halt() { kill -STOP "\$1" 2>/dev/null; }                # остановить, память остаётся за программой
stop_loads() { kill -9 \$G1 \$G2 2>/dev/null; }
sleep 3
mark "0 максимум, запуск обеих программ нагрузки (300x300, 640x480) и сразу пауза"
pm 1; sleep 2
start_loads; sleep 4
halt \$G1; halt \$G2
pm 0
mark "A простой 60 с, программы на паузе (ожидаю спуск до 03)"
sleep 60
snap "A простой"
mark "B PowerMizer максимум в простое 10 с (03 -> 0f без нагрузки)"
pm 1; sleep 10
snap "B максимум, простой"
mark "B PowerMizer адаптивный, простой 45 с (спуск без нагрузки)"
pm 0; sleep 45
snap "B адаптивный, простой"
guard C
mark "C продолжение 300x300 на 03, адаптивный, 30 с (подъём из 03 под нагрузкой)"
go \$G1; sleep 25
snap "C лёгкая нагрузка"
sleep 5; halt \$G1
mark "C нагрузка на паузе, простой 40 с"
sleep 40
guard D
mark "D продолжение 300x300 + максимум 10 с (0f под нагрузкой)"
go \$G1; sleep 3; pm 1; sleep 10
snap "D максимум под нагрузкой"
mark "D адаптивный, нагрузка продолжается 30 с (спуск под нагрузкой)"
pm 0; sleep 30
snap "D адаптивный под нагрузкой"
halt \$G1
mark "D нагрузка на паузе, простой 40 с"
sleep 40
guard E
mark "E всплески: 5 x (продолжение 3 с, пауза 6 с)"
for i in 1 2 3 4 5; do
  mark "E всплеск \$i"; go \$G1; sleep 3; halt \$G1; sleep 6
done
snap "E после всплесков"
guard F
mark "F продолжение 640x480, 30 с (окно крупнее)"
go \$G2; sleep 25
snap "F средняя нагрузка"
sleep 5; halt \$G2
mark "F нагрузка на паузе, простой 30 с"
sleep 30
snap "F конец, простой"
stop_loads
mark "выход из X11"
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
