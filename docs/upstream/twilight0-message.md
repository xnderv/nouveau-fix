# Draft: message to twilight0 (GitHub issue in Twilight0/nouveau-fermi-reclock-dkms)

Suggested title: **GF114 / GDDR5 (GTX 560 Ti): full reclock working via stock memx — trace + results to share**

Hi,

I'm the owner of a desktop GeForce GTX 560 Ti (GF114, Gigabyte GV-N560OC, 1 GB GDDR5, PCI subsystem
1458:3515) and over the last few days I've done on it roughly what you did on the GT 555M — with the
same method (mmiotrace of the NVIDIA 390 driver, decode of the PMU memory scripts, replay in nouveau,
one change at a time). Your RECLOCKING_NOTES.md and the opcode table were a real head start, thank you.
Since you have a DDR3 part and I have GDDR5 — and issue #4 asks exactly about GDDR5 — I think our
results are complementary, so here is what I have:

**Working on GF114/GDDR5** (Linux 7.0.x, nouveau from the kernel + patches, DKMS):
- memory 135 → 324 → 2004 MHz by replaying the NVIDIA PMU scripts **through the stock memx firmware
  channel** (`gt215_pmu_send`) — on my chip memx works; no custom Falcon executor needed;
- core/ROP/hub PLLs at factory values (1800/1907/1645): two nouveau bugs found — PLL ctrl bit 0x10
  set after lock puts the node into bypass (core ran at ~25 MHz while claiming 1800), and hubk06's PLL
  refclk read as 1620 instead of 405 (`read_div`, `doff <= 2`);
- voltage (VID GPIO) and PCIe Gen1/Gen2 switching verified bit-for-bit against the NVIDIA trace;
- NVIDIA's busy counters reproduced inside the nouveau PMU firmware (new `PERF` process), governor
  in the driver with a 90/95 °C brake; S3 verified; 03/07/0f switching under load ~100 cycles clean.

**Open:** a rare hard hang (3 in 3 days, `PMC_BOOT_0 = 0xffffffff` → MCE) that I can't reproduce on
demand yet — looks like your 06.09 one. Your RM decompilation notes on opcode 0x3a (per-partition buffer
flush via 0x13d7f4) and the 500 ms VBLANK timeout in Falcon are the two best leads I have for it.

**What I can share:** the full NVIDIA 390 trace from this board (~17 MB xz), the decoded scripts
A–E for GDDR5, register snapshots of NVIDIA vs nouveau in each level, and all experiment logs.
Repository: <URL after publication>. I'd be glad to compare the two traces side by side — what is
common between DDR3 and GDDR5 is what could eventually become a generic Fermi sequence in nouveau,
rather than two board-specific replays.

If you'd like the trace, tell me how you prefer to receive it (it contains NVIDIA binary blobs, so
I'm not putting it in the public repo).

Alex
