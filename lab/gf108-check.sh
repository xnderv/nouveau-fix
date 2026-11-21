#!/bin/bash
# GF108 hub clock check (20.11.2026) — for testers with a GF108 card (GT 430/440/530/620/630/730, Quadro 600, NVS 5200M ...)
# running the lab build. On GF108 the VBIOS asks for a hub clock (HUB2CLK) at the top level that a divider can't make; the
# NVIDIA driver then takes it from a PLL. Which PLL actually reaches the hub can only be measured on a GF108 card.
#
#   bash lab/gf108-check.sh          — measure only: switch levels 03 -> 07 -> 0f -> 07 -> 03 and read the card's clock
#                                      counters after each switch (read-only). About 15 seconds.
#   bash lab/gf108-check.sh probe    — the same, then one extra step: for ~0.3 ms per variant the hub is fed from each of the
#                                      eight inputs of its "source 2" and measured, then restored at once. On our GF114 this
#                                      ran without any effect on the desktop; on GF108 it is the first run. Optional.
# One monitor, desktop idle. The result file is printed at the end — attach it to your issue or letter.
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_cntr_sys" ] || { echo "The lab build is not loaded (no lab_cntr_sys) — install it first (docs/TESTING-core.md)"; exit 1; }
MODE="${1:-measure}"
OUT="$HOME/gf108-check-$(date +%Y%m%d-%H%M%S).txt"
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
[ -n "$PS" ] || { echo "No pstate file in debugfs"; exit 1; }
G0=$(cat $PRM/lab_gov)
trap 'w lab_cntr_sys 0; w lab_hub01_probe 0; w lab_gov "$G0"; echo "interrupted, settings restored"; exit 1' INT TERM
lvl() { sudo sh -c "echo $1 > $PS"; sleep 2; }
{
  echo "gf108-check ($MODE): $(uname -r), module $(cat /sys/module/nouveau/srcversion), $(date)"
  lspci -nn | grep -iE "vga|3d" | grep -i nvidia
  sudo cat "$PS"
} > "$OUT"
T0=$(date "+%F %T")
w lab_gov 0
lvl 03
w lab_cntr_sys 1
for l in 07 0f 07 03; do lvl $l; done
w lab_cntr_sys 0
if [ "$MODE" = probe ]; then
  lvl 0f; lvl 03                      # PLLs started at 0f stay running; the probe runs on the way to 07
  w lab_hub01_probe 1; lvl 07
  w lab_hub01_probe 0
fi
lvl 03
w lab_gov "$G0"
{ sudo journalctl -k -b 0 --no-pager | grep -m1 "LAB build"; sudo journalctl -k -b 0 --no-pager --since "$T0"; } | grep -E "LAB build|LAB узлы по расчёту|LAB счётчик|LAB hub01-проба|hub01-alt|беру снизу|LAB calc idx 0[278] |Xid|FAULT|ТАЙМ-АУТ" \
  | sed -E 's/^.*nouveau [0-9a-f:.]+: //' >> "$OUT"
echo "=== end; governor restored" >> "$OUT"
cat "$OUT"
echo
echo "Result: $OUT — please attach this file."
