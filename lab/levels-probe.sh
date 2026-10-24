#!/bin/bash
# ТЕСТ Б (24.10): только чтение регистров. Карта проходит 03 -> 07 -> 0f -> 07 -> 03 (через debugfs, регулятор на это время
# выключен), на каждом уровне nvframe-probe.py читает регистры, которые NVIDIA ставит по уровню, и сравнивает с её значениями.
# Ничего, кроме смены уровня, не пишет. Итог — results/levels-probe-*.txt.
#   bash ~/Home/nouveau-fix/lab/levels-probe.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_gov" ] || { echo "Нужен лабораторный драйвер (нет $PRM/lab_gov)"; exit 1; }
sudo -v || exit 1
PSF="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
[ -n "$PSF" ] || { echo "Нет debugfs pstate"; exit 1; }
mkdir -p "$KIT/results"; OUT="$KIT/results/levels-probe-$(date +%Y%m%d-%H%M%S).txt"
GOV0="$(cat "$PRM/lab_gov")"
sudo sh -c "echo 0 > $PRM/lab_gov"
trap 'sudo sh -c "echo $GOV0 > $PRM/lab_gov"; echo "регулятор возвращён (lab_gov=$GOV0)"' EXIT
for L in 03 07 0f 07 03; do
    sudo sh -c "echo $L > '$PSF'"; sleep 3
    echo "=== $(date +%T) уровень $L: $(sudo sh -c "grep '^AC' '$PSF'")" >> "$OUT"
    sudo python3 -I "$HERE/nvframe-probe.py" "$L" "$OUT"
done
grep -E "^===|отличий" "$OUT"
echo "Итог: $OUT"
