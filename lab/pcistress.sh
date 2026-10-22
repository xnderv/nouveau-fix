#!/bin/bash
# НАГРУЗКА НА ШИНУ PCIe + смена уровней: воспроизведение обрыва шины 22.10 (карта читается 0xffffffff -> Machine Check).
#   pcistress.sh <0|1|2|3> [N] — lab_pcie: 0 не трогать, 1 nouveau переключает, 2 один раз 5 GT/s, 3 последовательность NVIDIA
#                               и N (по умолчанию 10) циклов 07 -> 0f -> 07 под glmark2 с постоянной загрузкой буферов
#                               по шине. ВО ВРЕМЯ ОПЫТА ДЕЛАЙ СНИМКИ ЭКРАНА (PrtSc, несколько раз) — именно это роняло.
#   CPU=1 bash pcistress.sh ...  — дополнительно занять ВСЕ ядра процессора (как при сборке драйвера): оба падения
#                                  22.10 были во время сборки; проверяем, не рвёт ли нагрузка на процессор тайминги шагов
# Чёрный ящик (gpu-blackbox) должен работать: при зависании после Reset — bash ~/nouveau-fix/lab/blackbox.sh show.
# Регулятор на время опыта выключается и в конце включается; lab_pcie в конце ВОЗВРАЩАЕТСЯ к значению до опыта.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
[ -e "$P/lab_pcie" ] || { echo "--- СТОП: нет lab_pcie (нужен лабораторный драйвер)"; exit 1; }
V="${1:-}"; [[ "$V" =~ ^[0123]$ ]] || { sed -n '2,7p' "$0"; exit 1; }
N="${2:-10}"
systemctl is-active -q gpu-blackbox || echo "⚠ чёрный ящик не запущен (bash ~/nouveau-fix/lab/blackbox.sh install) — при зависании следов не будет"
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "--- СТОП: нет glmark2"; exit 1; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
DEV="$(basename "$(for d in /sys/bus/pci/devices/*; do grep -q 0x10de "$d/vendor" && grep -q '^0x03' "$d/class" && echo "$d"; done | head -n1)")"
lnk() { cat /sys/bus/pci/devices/$DEV/current_link_speed 2>/dev/null; }
LOG="$KIT/results/pcistress-$V-$(date +%Y%m%d-%H%M%S).txt"
ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf|0xffffffff)'
errs() { journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true; }
GOV="$(cat $P/lab_gov)"; PC0="$(cat $P/lab_pcie)"; E0="$(errs)"
echo "Опыт PCIe-нагрузка lab_pcie=$V, CPU=${CPU:-0}, $N циклов, $(date '+%F %T'); линия: $(lnk). ДЕЛАЙ СНИМКИ ЭКРАНА (PrtSc)." | tee "$LOG"; sync
sudo sh -c "echo 0 > $P/lab_gov; echo $V > $P/lab_pcie"
"$G" --run-forever -s 1600x900 -b buffer:update-fraction=1:interleave=false:update-method=map -b texture:texture-filter=mipmap >/dev/null 2>&1 & GP=$!
CPUPIDS=""
if [ "${CPU:-0}" = 1 ]; then
    for c in $(seq 1 "$(nproc)"); do ( while :; do :; done ) & CPUPIDS="$CPUPIDS $!"; done
    echo "  процессор: занято $(nproc) ядер" | tee -a "$LOG"
fi
sleep 3
for i in $(seq 1 "$N"); do
    for m in 0f 07; do
        sudo sh -c "echo $m > '$PS'"; sleep 0.5
        echo "  $(date +%T) цикл $i -> $m: $(sudo grep '^AC' "$PS") | линия $(lnk) | ошибок +$(( $(errs) - E0 ))" | tee -a "$LOG"; sync
        sleep 5
    done
done
kill $GP $CPUPIDS 2>/dev/null; wait $GP $CPUPIDS 2>/dev/null
E1="$(errs)"
sudo sh -c "echo $PC0 > $P/lab_pcie; echo $GOV > $P/lab_gov"
echo "ошибок драйвера за опыт: $((E1 - E0)); lab_pcie возвращён = $PC0, регулятор lab_gov=$GOV. Лог: $LOG" | tee -a "$LOG"
[ "$((E1 - E0))" = 0 ] && echo "=== Выжили без ошибок ✅" || { echo "=== Были ошибки:"; journalctl -k -b 0 --no-pager | grep -E "$ERR" | tail -n 5; }
