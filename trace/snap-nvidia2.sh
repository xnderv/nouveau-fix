#!/bin/bash
# СНИМКИ РЕГИСТРОВ под NVIDIA 390 в ЗАКРЕПЛЁННЫХ режимах 07, 03 и 0f. Без mmiotrace. Только чтение.
# Режим закрепляется настройкой драйвера NVIDIA (PowerMizerDefaultAC: 3 = 03, 2 = 07, 1 = 0f),
# для каждого режима — отдельный запуск X11. Снимок — через 10 с после старта X11 (не в момент запуска),
# только проверенные диапазоны (regdump3.py). До загрузки драйвера ничего не читаем.
# Запуск: sudo ~/trace/snap-nvidia2.sh   (~2 минуты, ничего не трогать)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/snap2-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }
XC=/etc/X11/xorg.conf; cp "$XC" "$OUT/xorg.conf.orig"
trap 'cp "$OUT/xorg.conf.orig" "$XC"' EXIT

say "Ядро $(uname -r), снимки в закреплённых режимах, версия 1"
lsmod | grep -q '^nvidia ' && { say "СТОП: драйвер nvidia уже загружен. Перезагрузись."; exit 1; }
modprobe nvidia
say "Драйвер nvidia загружен"

for PM in 2 3 1; do
  case $PM in 2) NAME=07;; 3) NAME=03;; 1) NAME=0f;; esac
  printf 'Section "Device"\n    Identifier "nv"\n    Driver "nvidia"\n    Option "Coolbits" "8"\n    Option "RegistryDwords" "PowerMizerEnable=0x1; PerfLevelSrc=0x2222; PowerMizerDefault=0x%s; PowerMizerDefaultAC=0x%s"\nEndSection\n' $PM $PM > "$XC"
  cat > /tmp/xsnap2.sh <<XEOF
#!/bin/bash
OUT="$OUT"; HERE="$HERE"; NAME="$NAME"
say() { echo "\$(date +%T) \$*" >> "\$OUT/steps.txt"; sync; }
sleep 10
L="\$(nvidia-settings -t -q GPUCurrentPerfLevel 2>/dev/null | head -n 1)"
F="\$(nvidia-settings -t -q GPUCurrentClockFreqs 2>/dev/null | head -n 1)"
say "режим \$NAME: уровень \$L, частоты \$F — снимок A"
python3 "\$HERE/regdump3.py" "\$NAME A | уровень \$L частоты \$F" "\$OUT/regs.txt"
say "снимок A сделан"
sleep 5
L="\$(nvidia-settings -t -q GPUCurrentPerfLevel 2>/dev/null | head -n 1)"
F="\$(nvidia-settings -t -q GPUCurrentClockFreqs 2>/dev/null | head -n 1)"
python3 "\$HERE/regdump3.py" "\$NAME B | уровень \$L частоты \$F" "\$OUT/regs.txt"
say "режим \$NAME: снимок B сделан (уровень \$L, частоты \$F)"
XEOF
  chmod +x /tmp/xsnap2.sh
  say "=== X11 с закреплённым режимом $NAME (PowerMizerDefaultAC=$PM)"
  xinit /tmp/xsnap2.sh -- :0 vt2 >"$OUT/xinit-$NAME.txt" 2>&1 || true
  cp /var/log/Xorg.0.log "$OUT/Xorg-$NAME.log" 2>/dev/null || true
  sleep 3
done
dmesg > "$OUT/dmesg.txt"
grep -c '^###' "$OUT/regs.txt" | sed 's/^/снимков: /' | tee -a "$LOG"
sync
say "ГОТОВО. Результат: $OUT. Перезагрузись в основную систему: sudo reboot"
