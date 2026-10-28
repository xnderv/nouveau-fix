#!/bin/bash
# nouveau-fix lab driver: test run for the GF106 GTS 450 build (rox4d's card). Run as root.
#   sudo bash rox4d-test.sh [cycles=3] [pause_s=20]
# What it does: checks that the lab nouveau module is loaded and has recognised the board, prints its lab_* parameters,
# then switches the performance level 0f -> 07 -> 03 -> 0f ... for N cycles with a pause between steps, logging the
# driver's dmesg lines, GPU errors and the pstate file to rox4d-test-<date>.log in the current directory.
# It stops at the first error line. Nothing else is written to the GPU: only the pstate file.
# RULE: the first level change after boot must be 0f (the only transition recorded from the POST memory state).
#       If the card is not in its boot state (you already changed levels), reboot before running this.
# Note: the driver's own log lines are in Russian (it is a lab build); the numbers in them are what matters.
set -u
CYCLES="${1:-3}"; PAUSE="${2:-20}"
LOG="rox4d-test-$(date +%Y%m%d-%H%M%S).log"
PRM=/sys/module/nouveau/parameters
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
die() { say "STOP: $*"; say "full dmesg saved to $LOG.dmesg"; dmesg > "$LOG.dmesg"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 2; }
[ -d "$PRM" ] || die "nouveau module not loaded"
PST=""; for f in /sys/kernel/debug/dri/*/pstate; do [ -r "$f" ] && grep -q '^AC:' "$f" 2>/dev/null && PST="$f" && break; done
[ -n "$PST" ] || die "no readable pstate file under /sys/kernel/debug/dri/*/ (debugfs mounted? nouveau pstate support?)"
say "=== nouveau-fix lab test, cycles=$CYCLES pause=${PAUSE}s, log $LOG"
say "kernel $(uname -r); module: $(modinfo -n nouveau 2>/dev/null) srcversion $(cat /sys/module/nouveau/srcversion 2>/dev/null)"
say "card: $(lspci -nn -d 10de: | head -n 1)"
say "lab parameters:"; for p in "$PRM"/lab_*; do printf '  %s=%s\n' "$(basename "$p")" "$(cat "$p" 2>/dev/null)"; done | tee -a "$LOG"
say "board recognised by the driver (dmesg):"; dmesg | grep -E 'LAB: (плата|board)' | tail -n 3 | tee -a "$LOG"
dmesg | grep -qE 'LAB: плата (GF106|GF114)' || die "the driver did not recognise the board (no 'LAB: плата ...' line); memory replay would be refused"
[ "$(cat $PRM/lab_mem_replay)" != 0 ] || die "lab_mem_replay is 0: memory steps are not enabled (expected 14 for GF106)"
say "pstate file $PST:"; cat "$PST" | tee -a "$LOG"
ERR='DATA_ERROR|fifo: fault|killed|Xid|timeout|тайм-аут|не из записи|не трогаю|ret -[0-9]|не годится|не разрешён|плата не описана|failed'
step() {   # $1 = level
    local n0 n1 new
    n0=$(dmesg | wc -l)
    say "--- set level $1"
    echo "$1" > "$PST" 2>>"$LOG" || say "write to pstate returned error $? (see dmesg below)"
    sleep 3
    n1=$(dmesg | wc -l); new=$(dmesg | tail -n +$((n0 + 1)))
    echo "$new" | grep -E 'LAB|nouveau' | tee -a "$LOG" >/dev/null
    echo "$new" | grep -E 'LAB replay|LAB volt|LAB therm|LAB: ' | tail -n 12 | tee -a "$LOG"
    say "now: $(grep -E '^AC:' "$PST")"
    if echo "$new" | grep -qE "$ERR"; then say "error lines:"; echo "$new" | grep -E "$ERR" | tee -a "$LOG"; die "error after setting level $1"; fi
    sleep "$PAUSE"
}
for ((c = 1; c <= CYCLES; c++)); do
    say "=== cycle $c of $CYCLES"
    step 0f; step 07; step 03
done
step 0f
say "=== done: $CYCLES cycles without error lines. Please send $LOG and $LOG.dmesg"
dmesg > "$LOG.dmesg"
