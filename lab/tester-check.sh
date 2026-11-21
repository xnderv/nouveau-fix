#!/bin/bash
# One-shot check of the lab build on any Fermi card (21.11.2026): as much as one run can tell us, so testers don't have to come
# back many times. Works with any set of performance levels (03/07/0f, or 07/0f on GF119/GF117) and on laptops with two GPUs.
# Every stage is written to the result file as soon as it finishes, so if the machine hangs, what came before is kept.
#
#   bash lab/tester-check.sh              — all stages, about 6–8 minutes; one monitor, other programs closed
#   bash lab/tester-check.sh after-hang   — after a hang and a reboot: collects the kernel log of the previous boot
#
# Stages: 1 system and card; 2 clocks at every level, measured by the card's own clock counters; 3 fifty manual switches
# between the lowest and the top level; 4 the automatic governor under load (glxgears on the NVIDIA GPU) and at rest;
# 5 on laptops: the NVIDIA GPU goes to sleep and wakes up — load counting and the governor must start again; 6 the log.
# At the end it prints the path of one archive — please attach that to your issue or e-mail.
set -uo pipefail
PRM=/sys/module/nouveau/parameters
STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="$HOME/nouveau-check-$STAMP"; mkdir -p "$DIR"; OUT="$DIR/check.txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
# kernel log lines of nouveau / the lab build, without the host name and the root UUID (the archive may be posted publicly)
klog() { sudo journalctl -k "$@" --no-pager 2>/dev/null | grep -E "nouveau|LAB[ :]" \
         | sed -E 's/^([A-Z][a-z]{2} +[0-9]+ [0-9:]{8}) [^ ]+ kernel: /\1 /; s/nouveau [0-9a-f:.]+: //; s/(root|resume)=[^ ]+/\1=…/g'; }
errs() { sudo journalctl -k -b 0 --no-pager --since "$1" 2>/dev/null | grep -cE "Xid|FAULT|DATA_ERROR|ТАЙМ-АУТ|ОСТАЛСЯ НА PLL|killed|g84_bar_flush"; }

if [ "${1:-}" = after-hang ]; then
    sudo -v || exit 1
    klog -b -1 > "$DIR/previous-boot-nouveau.txt"
    LAST="$(ls -dt "$HOME"/nouveau-check-*/ 2>/dev/null | sed -n 2p)"
    [ -n "$LAST" ] && cp "$LAST/check.txt" "$DIR/check-before-hang.txt" 2>/dev/null
    tar -czf "$DIR.tar.gz" -C "$(dirname "$DIR")" "$(basename "$DIR")"
    echo "Collected. Please attach: $DIR.tar.gz"; exit 0
fi

[ -e "$PRM/lab_cntr_sys" ] || { echo "The lab build is not loaded — install it first (docs/TESTING-core.md)"; exit 1; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
BDF="$(lspci -D -d 10de: | grep -E "VGA|3D|Display" | head -n 1 | cut -d' ' -f1)"
PWR="/sys/bus/pci/devices/$BDF/power"
PC0="$(cat "$PWR/control" 2>/dev/null || echo on)"
PS="$(sudo sh -c 'for f in /sys/kernel/debug/dri/*/pstate; do [ -e "$f" ] && { echo "$f"; break; }; done')"
[ -n "$PS" ] || { echo "No pstate file in debugfs (is the NVIDIA GPU driven by nouveau?)"; kill $KEEP; exit 1; }
G0="$(cat $PRM/lab_gov)"
w() { sudo sh -c "echo $2 > $PRM/$1"; }
restore() { w lab_cntr_sys 0; w lab_gov "$G0"; sudo sh -c "echo $PC0 > $PWR/control" 2>/dev/null; pkill -f "glxgears" 2>/dev/null; kill $KEEP 2>/dev/null; }
trap 'say "interrupted — settings restored"; restore; exit 1' INT TERM
awake() { sudo sh -c "echo on > $PWR/control" 2>/dev/null; sleep 1; }
lvl() { sudo sh -c "echo $1 > $PS"; sleep "${2:-2}"; }
T0="$(date "+%F %T")"

say "=== 1. system and card"
{
  echo "kernel $(uname -r); module $(cat /sys/module/nouveau/srcversion)"
  klog -b 0 | grep -m1 "LAB build" || echo "(no LAB build line)"
  lspci -nn | grep -iE "vga|3d|display"
  echo "NVIDIA GPU $BDF: power control '$PC0', runtime status '$(cat "$PWR/runtime_status" 2>/dev/null || echo -)'"
  echo "connected displays: $(for c in /sys/class/drm/card*-*/status; do [ "$(cat "$c")" = connected ] && basename "$(dirname "$c")"; done | tr '\n' ' ')"
  awake; sudo cat "$PS"
  echo "switches: $(for p in lab_gov lab_mem lab_mem_new lab_therm lab_therm_gf119 lab_vbios_src lab_gpc_pre405; do [ -e $PRM/$p ] && printf '%s=%s ' $p "$(cat $PRM/$p)"; done)"
  echo "--- driver start (this boot):"
  klog -b 0 | grep -E "LAB (build|плата|источник|perf|gov: включён)|LAB: |calc idx|не попадает|мимо VBIOS|bios: version|fb: " | head -n 60
} >> "$OUT" 2>&1; sync
LV=($(sudo cat "$PS" | grep -oE '^[0-9a-f]{2}:' | tr -d ':' | sort))
[ "${#LV[@]}" -ge 1 ] || { say "no performance levels found — stopping"; restore; exit 1; }
LO="${LV[0]}"; HI="${LV[${#LV[@]}-1]}"
say "levels: ${LV[*]} (lowest $LO, top $HI)"

say "=== 2. clocks at every level (clock counters)"
T2="$(date "+%F %T")"; awake; w lab_gov 0
lvl "$LO"; w lab_cntr_sys 3
for l in "${LV[@]:1}"; do lvl "$l"; done
for ((i=${#LV[@]}-2; i>=0; i--)); do lvl "${LV[$i]}"; done
w lab_cntr_sys 0
klog -b 0 --since "$T2" | grep -E "LAB (узлы по расчёту|счётчик)|calc idx|не попадает|мимо VBIOS|hub01-alt|Xid|FAULT|ТАЙМ-АУТ" >> "$OUT"
say "stage 2 done: errors $(errs "$T2")"

say "=== 3. fifty switches between $LO and $HI"
T3="$(date "+%F %T")"
for i in $(seq 1 50); do lvl "$HI" 1; lvl "$LO" 1; done
say "stage 3 done: 50 cycles, timeouts/errors $(errs "$T3"); now: $(sudo grep '^AC' "$PS")"

say "=== 4. automatic governor: 60 s load on the NVIDIA GPU, then 60 s rest"
T4="$(date "+%F %T")"; w lab_gov 2
if command -v glxgears >/dev/null; then
    DRI_PRIME=1 vblank_mode=0 timeout 60 glxgears >/dev/null 2>&1 & GP=$!
    for s in 15 30 45 60; do sleep 15; say "  load $s s: $(sudo grep '^AC' "$PS")"; done
    wait "$GP" 2>/dev/null	# only glxgears — a bare wait would also wait for the sudo keep-alive loop forever (test 111)
    for s in 15 30 45 60; do sleep 15; say "  rest $s s: $(sudo grep '^AC' "$PS")"; done
else
    say "  glxgears not installed (Debian/Ubuntu: mesa-utils, Arch: mesa-utils) — skipping the load part"
fi
klog -b 0 --since "$T4" | grep -E "LAB (gov|perf)" | tail -n 30 >> "$OUT"
say "stage 4 done: governor switches $(klog -b 0 --since "$T4" | grep -c 'LAB gov: ->'), errors $(errs "$T4")"

say "=== 5. GPU sleep and wake (laptops)"
if [ "$PC0" = auto ] && [ -e "$PWR/runtime_status" ]; then
    T5="$(date "+%F %T")"; sudo sh -c "echo auto > $PWR/control"
    for s in $(seq 1 30); do [ "$(cat "$PWR/runtime_status")" = suspended ] && break; sleep 2; done
    say "  after up to 60 s idle: runtime status '$(cat "$PWR/runtime_status")'"
    awake; sleep 5
    say "  woken: runtime status '$(cat "$PWR/runtime_status")', $(sudo grep '^AC' "$PS")"
    klog -b 0 --since "$T5" | grep -E "LAB (perf|gov)|suspend|resume|Xid|FAULT" | tail -n 20 >> "$OUT"
    say "stage 5 done: load counting restarted $(klog -b 0 --since "$T5" | grep -c 'начать замеры') time(s), errors $(errs "$T5")"
else
    say "  the GPU does not sleep here (power control '$PC0') — skipped"
fi

say "=== 6. log"
restore; trap - INT TERM
klog -b 0 > "$DIR/kernel-nouveau.txt"
sudo cat "$PS" >> "$OUT" 2>/dev/null
say "total errors since start: $(errs "$T0")"
tar -czf "$DIR.tar.gz" -C "$(dirname "$DIR")" "$(basename "$DIR")"
echo
echo "Done. Please attach: $DIR.tar.gz"
