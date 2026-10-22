#!/bin/bash
# ОПЫТ «ШИНА PCIe»: одна переменная — lab_pcie (уже есть в драйвере, перезагрузка не нужна).
# NVIDIA 390 на 0f поднимает линию до 5 GT/s (gen2), на 03/07 опускает до 2,5 GT/s; мы шину не трогали.
#   pcietest.sh on  [N]  — lab_pcie=1 и N (по умолчанию 4) циклов 07 -> 0f -> 07 под нагрузкой, с проверкой
#                          скорости линии (lspci) в каждом режиме
#   pcietest.sh off [N]  — контроль с lab_pcie=0
#   pcietest.sh static [N] — lab_pcie=2: один раз поднять до 5 GT/s, дальше не переобучать (ожидание: 5 GT/s на всех уровнях)
# На время опыта регулятор выключается и в конце включается обратно. Если экран встанет: Alt+PrtSc, S, B.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
case "${1:-}" in on) V=1;; off) V=0;; static) V=2;; nvidia) V=3;; *) sed -n '2,8p' "$0"; exit 1;; esac
N="${2:-4}"
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "--- СТОП: нет glmark2"; exit 1; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
DEV="$(basename "$(for d in /sys/bus/pci/devices/*; do grep -q 0x10de "$d/vendor" && grep -q '^0x03' "$d/class" && echo "$d"; done | head -n1)")"
lnk() { sudo lspci -vv -s "$DEV" | grep -oE 'LnkSta:\s*Speed [0-9.]+GT/s[^,]*' | sed 's/LnkSta:\s*//'; }
LOG="$KIT/results/pcie-$V-$(date +%Y%m%d-%H%M%S).txt"
ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf)'
errs() { journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true; }
GOV="$(cat $P/lab_gov)"; E0="$(errs)"
echo "Опыт PCIe lab_pcie=$V, $N циклов, $(date '+%F %T'); линия сейчас: $(lnk)" | tee "$LOG"
sudo sh -c "echo 0 > $P/lab_gov; echo $V > $P/lab_pcie"
"$G" --run-forever -s 1600x900 -b refract >/dev/null 2>&1 & GP=$!
sleep 3
for i in $(seq 1 "$N"); do
    for m in 0f 07; do
        sudo sh -c "echo $m > '$PS'"; sleep 0.5
        A="$(sudo grep '^AC' "$PS")"
        L="$(journalctl -k -b 0 --no-pager | grep -E 'LAB pstate [0-9]+: pcie' | tail -n 1 | sed -E 's/.*LAB pstate [0-9]+: //')"
        echo "  $(date +%T) цикл $i -> $m: $A | линия: $(lnk) | драйвер: $L" | tee -a "$LOG"; sync
        sleep 7
    done
done
kill $GP 2>/dev/null; wait $GP 2>/dev/null
E1="$(errs)"
sudo sh -c "echo $GOV > $P/lab_gov"
echo "ошибок драйвера за опыт: $((E1 - E0)); регулятор снова lab_gov=$GOV; lab_pcie оставлен = $V. Лог: $LOG" | tee -a "$LOG"
echo "Ожидание при on: в 0f «Speed 5GT/s», в 07 «Speed 2.5GT/s» (как у NVIDIA); при static: 5GT/s везде; при off: 2.5GT/s везде."
