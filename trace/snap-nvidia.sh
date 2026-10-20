#!/bin/bash
# СНИМКИ РЕГИСТРОВ под драйвером NVIDIA 390 БЕЗ mmiotrace (система u2204-trace). Только чтение.
# Цель: эталон состояния памяти и тактирования в режимах 0f (900/2004), 07 и 03 — чтобы потом
# сравнить с нашим повтором скрипта NVIDIA на nouveau.
# Этапы: 0 до драйвера → драйвер + X11 (порядок как в удачной записи 1) → простой →
#        PowerMizer «максимум» + glxgears (0f), два снимка → адаптивный, ждём 07 и 03, снимки.
# Запуск: sudo ~/trace/snap-nvidia.sh   (~3 минуты, ничего не трогать)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/snap-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }

say "Ядро $(uname -r), снимки без записи, версия 1"
lsmod | grep -q '^nvidia ' && { say "СТОП: драйвер nvidia уже загружен — снимок «до драйвера» не получится. Перезагрузись."; exit 1; }
python3 "$HERE/regdump2.py" "0 до драйвера (после BIOS)" "$OUT/regs.txt"
say "Снимок «до драйвера» сделан"
modprobe nvidia
say "Драйвер nvidia загружен, запускаю X11"

cat > /tmp/xsnap.sh <<XEOF
#!/bin/bash
OUT="$OUT"; HERE="$HERE"
say() { echo "\$(date +%T) \$*" >> "\$OUT/steps.txt"; sync; }
lvl() { nvidia-settings -t -q GPUCurrentPerfLevel 2>/dev/null | head -n 1; }
snap() { say "снимок: \$1 (уровень \$(lvl), частоты \$(nvidia-settings -t -q GPUCurrentClockFreqs 2>/dev/null | head -n 1))"
         python3 "\$HERE/regdump2.py" "\$1 | уровень \$(lvl)" "\$OUT/regs.txt"
         { echo "### \$1 \$(date +%T)"; nvidia-settings -t -q GPUCurrentPerfLevel -q GPUCurrentClockFreqs 2>&1; } >> "\$OUT/nvsettings.txt"; }
sleep 5
nvidia-settings -q GPUPerfModes > "\$OUT/perfmodes.txt" 2>&1 || true
snap "1 X11, простой"
nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=1' >/dev/null 2>&1 || true
__GL_SYNC_TO_VBLANK=0 glxgears -geometry 300x300+50+50 >/dev/null 2>&1 &
GG=\$!
for i in \$(seq 1 30); do [ "\$(lvl)" = 2 ] && break; sleep 1; done
sleep 3
snap "2 максимум 0f, нагрузка, снимок A"
sleep 5
snap "3 максимум 0f, нагрузка, снимок B"
kill \$GG 2>/dev/null || true
nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=0' >/dev/null 2>&1 || true
say "адаптивный режим, жду спуска"
S07=0
for i in \$(seq 1 90); do
  L="\$(lvl)"
  if [ "\$L" = 1 ] && [ \$S07 = 0 ]; then snap "4 спуск, уровень 07"; S07=1; fi
  [ "\$L" = 0 ] && break
  sleep 1
done
sleep 3
snap "5 простой 03"
say "выход из X11"
XEOF
chmod +x /tmp/xsnap.sh
xinit /tmp/xsnap.sh -- :0 vt2 >"$OUT/xinit.txt" 2>&1 || true
say "X11 закрыт"
cp /var/log/Xorg.0.log "$OUT/" 2>/dev/null || true
dmesg > "$OUT/dmesg.txt"
grep -c '^###' "$OUT/regs.txt" | sed 's/^/снимков: /' | tee -a "$LOG"
ls -lh "$OUT" | tee -a "$LOG"
sync
say "ГОТОВО. Результат: $OUT. Перезагрузись в основную систему: sudo reboot"
