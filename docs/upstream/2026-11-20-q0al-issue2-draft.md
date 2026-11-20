@Q0AL — sorry for the long silence; a lot has changed since your last runs, and there is a new build I'd like you to try.

**What's new:**
- **The core clocks now change by themselves, by load**, the way the NVIDIA driver does: up to the top level when the GPU is busy, down step by step when it's idle. No service and no module options are needed any more.
- **Everything is computed from the card's own VBIOS** — clocks, sources, voltages, the display clock, the waits around each switch. Nothing in the driver is tuned for our board any more.
- **Memory stays at your boot clock** (for the GTX 560 most likely 135 MHz — the NVIDIA memory scripts exist only for two boards so far). So you get the full core clock; memory-heavy 3D will gain less than compute.
- On our GTX 560 Ti: 10,000 core switches under load without a hang, and one night of 900 automatic switches without an error.

**How to install** — step by step in [docs/TESTING-core.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/TESTING-core.md). Two things matter: **delete the old options line** in `/etc/modprobe.d/nouveau-lab.conf` (old options would override the new defaults), and use **one monitor** — we have never tested with two. The patches now pick the right variant for your kernel (Debian's 6.12 included).

**Which cards:**
- **GTX 560 — yes, please.** Use it normally for an evening and send the kernel log as described.
- **GT 730 — not yet.** The issue I mentioned in November is still there: at the top level its VBIOS asks for 1400 MHz on one hub clock that our build can only make as 1620. With the automatic governor the card would reach the top level on its own, so please keep this build off the GT 730 until I fix that rule.
- **NVS 5200M** — not yet either; it's the same chip as the GT 730 and I haven't seen its VBIOS. If you can run `tools/card-report.sh` on it and post the output, I'll check whether it has the same problem.

Thanks again for your patience and for all the runs so far.
