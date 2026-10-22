#!/bin/bash
# ЛИНИЯ PCIe В УСТАНОВИВШЕМСЯ РЕЖИМЕ: поднять до 5 GT/s выбранным способом ОДИН РАЗ и держать под нагрузкой
# N минут без переключений, каждые 5 с читая флаг «исправимые ошибки» (DevSta CorrErr, липкий; сбрасывается
# в начале). Так видно, идут ли ошибки линии на 5 GT/s в работе, а не только в момент переобучения.
#   pciehold.sh <1|2|3> [минут]   — способ подъёма: 1 nouveau, 2 nouveau один раз, 3 последовательность NVIDIA
#                                   (с таймерами линии под 5 GT/s); по умолчанию 3 минуты. Жми PrtSc во время опыта.
# В конце: уровень 07 тем же способом (для 1 и 3 линия опустится до 2,5), регулятор включается, lab_pcie=0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
V="${1:-}"; [[ "$V" =~ ^[123]$ ]] || { sed -n '2,7p' "$0"; exit 1; }
MIN="${2:-3}"
[ -e "$P/lab_pcie" ] || { echo "--- СТОП: нет lab_pcie"; exit 1; }
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "--- СТОП: нет glmark2"; exit 1; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
DEV="$(for d in /sys/bus/pci/devices/*; do grep -q 0x10de "$d/vendor" && grep -q '^0x03' "$d/class" && basename "$d"; done | head -n1)"
BDF="${DEV#0000:}"
RP="$(basename "$(dirname "$(readlink /sys/bus/pci/devices/$DEV)")")"
sta() { echo "линия $(cat /sys/bus/pci/devices/$DEV/current_link_speed) | карта: $(sudo lspci -vv -s $DEV | grep -m1 DevSta: | grep -oE 'CorrErr[+-] NonFatalErr[+-] FatalErr[+-]') | порт: $(sudo lspci -vv -s "$RP" | grep -m1 DevSta: | grep -oE 'CorrErr[+-] NonFatalErr[+-] FatalErr[+-]')"; }
clear_err() { sudo setpci -s "$BDF" CAP_EXP+0xa.w=0x000f; }   # Device Status: биты RW1C — сброс CorrErr/NonFatal/Fatal/UnsupReq
LOG="$KIT/results/pciehold-$V-$(date +%Y%m%d-%H%M%S).txt"
ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf|0xffffffff)'
errs() { journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true; }
GOV="$(cat $P/lab_gov)"; E0="$(errs)"
echo "Опыт удержания PCIe, способ $V, $MIN мин, $(date '+%F %T')" | tee "$LOG"
echo "  до сброса: $(sta)" | tee -a "$LOG"; clear_err; echo "  после сброса флага: $(sta)" | tee -a "$LOG"
sudo sh -c "echo 0 > $P/lab_gov; echo $V > $P/lab_pcie; echo 07 > '$PS'"; sleep 1   # сначала 07: если карта уже на 0f, драйвер «0f» проигнорирует
echo "  $(date +%T) уровень 07: $(sudo grep '^AC' "$PS" | cut -c5-) | $(sta)" | tee -a "$LOG"
sudo sh -c "echo 0f > '$PS'"; sleep 1
echo "  $(date +%T) уровень 0f: $(sudo grep '^AC' "$PS" | cut -c5-) | $(sta)" | tee -a "$LOG"
grep -q "^5" /sys/bus/pci/devices/$DEV/current_link_speed || { echo "--- СТОП: линия не поднялась до 5 GT/s, опыт не имеет смысла"; sudo sh -c "echo 0 > $P/lab_pcie; echo $GOV > $P/lab_gov"; exit 1; }
echo "  после переобучения (ошибки переобучения — норма): $(sta)" | tee -a "$LOG"; clear_err; echo "  флаг сброшен ещё раз, дальше — только работа на этой скорости. ДЕЛАЙ СНИМКИ ЭКРАНА." | tee -a "$LOG"
"$G" --run-forever -s 1600x900 -b buffer:update-fraction=1:interleave=false:update-method=map -b texture:texture-filter=mipmap >/dev/null 2>&1 & GP=$!
for i in $(seq 1 $((MIN * 12))); do sleep 5; echo "  $(date +%T) +$((i * 5)) с: $(sta) | ошибок драйвера +$(( $(errs) - E0 ))" | tee -a "$LOG"; sync; done
kill $GP 2>/dev/null; wait $GP 2>/dev/null
sudo sh -c "echo 07 > '$PS'"; sleep 1
echo "  $(date +%T) уровень 07: $(sudo grep '^AC' "$PS" | cut -c5-) | $(sta)" | tee -a "$LOG"
sudo sh -c "echo 0 > $P/lab_pcie; echo $GOV > $P/lab_gov"
echo "регулятор lab_gov=$GOV, lab_pcie=0. Лог: $LOG" | tee -a "$LOG"
