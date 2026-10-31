#!/bin/bash
# nouveau-fix lab driver: test run for the GF106 GTS 450 build (rox4d's card). Run as root.
#   sudo bash rox4d-test.sh [cycles=3] [pause_s=20]
# What it does: checks that the lab nouveau module is loaded and has recognised the board, prints its lab_* parameters,
# then switches the performance level 0f -> 07 -> 03 -> 0f ... for N cycles with a pause between steps, logging the
# driver's dmesg lines, GPU errors and the pstate file to rox4d-test-<date>.log in the current directory.
# It stops at the first error line. Nothing else is written to the GPU: only the pstate file.
# RULE (with memory, lab_mem=1): the first level change after boot must be 0f (the only transition recorded from the POST
#       memory state). If the card is not in its boot state (you already changed levels), reboot before running this.
# Note: the driver's own log lines are in Russian (it is a lab build); the numbers in them are what matters.
# 30.10: after every step a read-only register snapshot (lab/clk-probe.py: clock and memory PLLs) goes into the log; the
#        pstate file is not read at 0f (nouveau's read_pll divides by zero there on this card); any kernel oops stops the
#        test; it refuses to start without lab_gpc_seq=13 and lab_mux_guard=1 (both were missing in the 30.10 run).
# 30.10 (round 7): core-only mode when lab_mem=0: core clocks computed from the card's own VBIOS (lab_vbios_src=1), memory
#        stays at its boot clock, any level may come first. Kernel errors are now also checked before every step (round 6:
#        the errors began during the pause and the test went on), FAULT and WARNING lines stop it too. The register
#        snapshot (clk-probe) runs only with PROBE=1:  sudo PROBE=1 bash rox4d-test.sh
set -u
CYCLES="${1:-3}"; PAUSE="${2:-20}"; PROBE="${PROBE:-0}"
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
if [ "$(cat $PRM/lab_mem)" = N ]; then
    say "mode: core only (lab_mem=0): memory stays at its boot clock"
    [ -e "$PRM/lab_vbios_src" ] || die "this module has no lab_vbios_src: build it from the current patch (round 7)"
    [ "$(cat $PRM/lab_vbios_src)" = 1 ] || die "lab_vbios_src is $(cat $PRM/lab_vbios_src), expected 1: add lab_vbios_src=1 to the options line in /etc/modprobe.d/nouveau-lab.conf, then update-initramfs -u and reboot"
    [ "$(cat $PRM/lab_nv_div_late)" = 1 ] || die "lab_nv_div_late is $(cat $PRM/lab_nv_div_late), expected 1: add lab_nv_div_late=1 to the options line in /etc/modprobe.d/nouveau-lab.conf, then update-initramfs -u and reboot"
else
    say "mode: core and memory (lab_mem=1)"
    dmesg | grep -qE 'LAB: плата (GF106|GF114)' || die "the driver did not recognise the board (no 'LAB: плата ...' line); memory replay would be refused"
    [ "$(cat $PRM/lab_mem_replay)" != 0 ] || die "lab_mem_replay is 0: memory steps are not enabled (expected 14 for GF106)"
fi
[ "$(cat $PRM/lab_gpc_seq)" = 13 ] || die "lab_gpc_seq is $(cat $PRM/lab_gpc_seq), expected 13: add lab_gpc_seq=13 to the options line in /etc/modprobe.d/nouveau-lab.conf, then update-initramfs -u and reboot"
[ "$(cat $PRM/lab_mux_guard)" = 1 ] || die "lab_mux_guard is $(cat $PRM/lab_mux_guard), expected 1: add lab_mux_guard=1 to the options line in /etc/modprobe.d/nouveau-lab.conf, then update-initramfs -u and reboot"
HERE="$(cd "$(dirname "$0")" && pwd)"
say "pstate file $PST:"; cat "$PST" | tee -a "$LOG"
ERR='DATA_ERROR|fifo: fault|killed|Xid|timeout|тайм-аут|не из записи|не трогаю|ret -[0-9]|не годится|не разрешён|плата не описана|failed|Oops|BUG:|divide error|Call Trace|FAULT|WARNING'
LAST=$(dmesg | wc -l)
check() {   # $1 = when; stop on error lines in $new
    if echo "$new" | grep -qE "$ERR"; then say "error lines:"; echo "$new" | grep -E "$ERR" | tee -a "$LOG"; die "error $1"; fi
}
step() {   # $1 = level
    local all
    all=$(dmesg); new=$(echo "$all" | tail -n +$((LAST + 1))); LAST=$(echo "$all" | wc -l)
    echo "$new" | grep -E 'LAB|nouveau' >> "$LOG"
    check "during the pause before level $1"
    say "--- set level $1"
    echo "$1" > "$PST" 2>>"$LOG" || say "write to pstate returned error $? (see dmesg below)"
    sleep 3
    all=$(dmesg); new=$(echo "$all" | tail -n +$((LAST + 1))); LAST=$(echo "$all" | wc -l)
    echo "$new" | grep -E 'LAB|nouveau' | tee -a "$LOG" >/dev/null
    echo "$new" | grep -E 'LAB replay|LAB volt|LAB therm|LAB calc|LAB: ' | tail -n 20 | tee -a "$LOG"
    if [ "$1" = 0f ] && [ ! -e "$PRM/lab_vbios_src" ]; then say "now: (pstate file not read at 0f: this older build divides by zero there)"
    else say "now: $(grep -E '^AC:' "$PST")"; fi
    if [ "$PROBE" = 1 ]; then python3 -I "$HERE/clk-probe.py" "level $1" >> "$LOG" 2>&1 || say "clk-probe failed (see $LOG)"; fi
    check "after setting level $1"
    sleep "$PAUSE"
}
for ((c = 1; c <= CYCLES; c++)); do
    say "=== cycle $c of $CYCLES"
    step 0f; step 07; step 03
done
step 0f
all=$(dmesg); new=$(echo "$all" | tail -n +$((LAST + 1))); echo "$new" | grep -E 'LAB|nouveau' >> "$LOG"
check "during the last pause"
say "=== done: $CYCLES cycles without error lines. Please send $LOG and $LOG.dmesg"
dmesg > "$LOG.dmesg"
