@Q0AL — thank you, both runs are very useful, and the build working on Debian's 6.12.113 is good news in itself.

**What the logs show.** The driver computed the core clocks from your card's VBIOS and set exactly what the NVIDIA driver set
in your recording: at the top level the core PLL is 63/15 (1701 MHz) — the first time that rule of ours ran on real hardware —
ROP and hubk07 at 1804, hubk06/hubk01 at 1620; the lower levels on dividers (810, and 101/270/540). The voltages, 1.0125 /
0.9125 / 0.875 V, are also the NVIDIA ones. After the first run, 9 switches in a row went through without a single error.

**The one failure.** The very first switch after boot, from the boot state straight to the top level: the core PLL locked,
but the core clock mux did not move from its divider to the PLL within 2 seconds. The driver noticed, left the core at the
lower clock and finished the switch; the test stopped there, as it should. This is the same rare event we see on our own
card (2 in 2000 switches), and we have two candidate fixes. We'd like to split them: you test one, we test the other.

**Yours: the NVIDIA driver's own wait.** Around every mux switch the driver slows the clock down for a moment; the NVIDIA
driver then waits a fixed time (8 µs for the core, 4.5 µs for the hub on GF114) before switching, while our build waits for
a hardware status flag (about 2.3 µs). No rebuild is needed, only the options:

1. `git pull` in nouveau-fix (the test script now ends at the lowest level instead of leaving the core at the top while the
   memory stays at its boot clock of 135 MHz — that combination never happens with the NVIDIA driver, and it may be what
   crashed your system after the second run).
2. Replace the line in `/etc/modprobe.d/nouveau-lab.conf` with:
   ```
   options nouveau lab_mem=0 lab_vbios_src=1 lab_gpc_div=1 lab_pmu_div=1 lab_gpc_seq=13 lab_mux_guard=1 lab_nv_div_late=1 lab_clk_mmu_lock=0 lab_therm_fixed_ns=8000 lab_therm_fixed_hub_ns=4500
   ```
   then `sudo update-initramfs -u`.
3. Since the failure was on the first switch after boot, please do this three times: reboot, run `sudo bash lab/rox4d-test.sh`
   right after logging in, and keep the two log files of each run.

About the crash: what did it look like — a freeze, a reboot, a black screen? If your journal is kept on disk, then after
the next crash `journalctl -k -b -1 > prev-boot.txt` (run right after the following boot) would show us what happened.

Thanks for the bonus run on the GT 730 too — it is useful, more than you'd think. It went through cleanly, and it shows
exactly the one case our computation does not handle yet: at the top level the card's VBIOS asks for 1400 MHz on one hub
clock (hubk01) and says "divider only", but that divider can only make 1620 or 1080 MHz. Our build picked 1620, about 16 %
above what the board asks for; on three other GF108 boards the NVIDIA driver handles this differently (it switches that
clock to another source we can't identify from registers alone). It survived the short test, but please don't keep the GT
730 at the top level with this build for long. If you ever feel like recording the NVIDIA 390 driver on the GT 730, the same
way you did for the GTX 560, that recording would answer exactly this question.

No rush, and thanks again.
