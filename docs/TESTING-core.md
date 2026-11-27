# Testing the automatic core reclocking (Fermi, November 2026)

This build changes the **core clocks automatically by load**, the way the NVIDIA driver does: up to the top level when the
GPU is busy, down step by step when it is idle. All core clocks, sources and voltages are computed from **your card's own
VBIOS**; nothing in it is tuned for one particular board. No service and no module options are needed.

**Memory clock:** stays where your VBIOS puts it at power-on (on most boards 135 or 324 MHz), except on the boards whose
NVIDIA memory scripts have been recorded (the table in the [README](../README.md) lists them). So on most cards you get
the full core clock with the memory at its boot clock: a clear gain in compute-heavy work, less in memory-heavy 3D. GF108
cards with DDR3 can go further: [TESTING-memory-ddr3.md](TESTING-memory-ddr3.md).

Tested on our GTX 560 Ti (GF114): 10,000 + 17,600 core switches under load without a hang, and 900 automatic switches
overnight without an error; and by testers on six more boards (GF106, GF108, GF119) without a hang. GF100, GF104, GF110,
GF116 and GF117 have not run it yet — that's what we ask you for.

## Before you start
- **Post your card report** (`bash tools/card-report.sh`, attach the output to your issue) — it helps us check your VBIOS.
  Since 20.11 the build never sets a clock above what the VBIOS asks for: where a divider can't make the clock exactly (seen
  on GF108), it takes the next lower one, or — like the NVIDIA driver on GF108 — feeds the hub from another PLL and checks
  the result with the card's clock counter, falling back if that path doesn't work. The log shows it as `hub01-alt`.
- **Already built an earlier version?** `git pull`, then build and install again (below). Builds from before 20.11 lack
  the rule above.
- **Use a single monitor: unplug any others.** Two or more monitors is a setup we have not tested, and we are not asking you to test it.
- If you tested an earlier round: **delete the old options line** in `/etc/modprobe.d/nouveau-lab.conf` (or delete the
  file). Old options override the new defaults.
- Needs: git, make, gcc, and the headers of your running kernel (Debian/Ubuntu: `sudo apt install linux-headers-$(uname -r)`).
  Tested to apply on Linux 6.12, 7.0, 7.2 and 7.3.

## Build and install
```
git clone https://github.com/xnderv/nouveau-fix.git      # or: git pull, if you have it
cd nouveau-fix
bash lab/tester-build.sh          # fetches nouveau for your kernel, applies the patches, builds (a few minutes)
bash lab/tester-build.sh install  # asks for sudo; your distribution's nouveau stays untouched
```
Reboot. Undo at any time: `bash lab/tester-build.sh remove`, then reboot.

## Check that it runs
```
cat /sys/module/nouveau/parameters/lab_gov          # 2 = the governor is on
sudo sh -c 'cat /sys/kernel/debug/dri/*/pstate'     # the line starting with AC: is the current level
journalctl -k -b | grep -E "LAB gov: ->"            # the level changes (the log text is partly in Russian — that's fine)
```
Open something graphical (a browser with a WebGL page, a game, glxgears) and watch the level go up; close it and wait
15–40 s for it to come down.

## What to send
Use the computer normally for a while — an evening is plenty. Then:
```
journalctl -k -b > nouveau-$(date +%Y%m%d-%H%M).txt
```
and attach the file to your issue, with a word about anything odd: freezes, artifacts, black screen, fan or temperature
behaviour. If the screen freezes, reboot and send `journalctl -k -b -1` (the previous boot) instead.

## Memory on a board that is recorded but not yet run
If the [README](../README.md) table says "recorded, not yet run" for your card, the build knows the memory scripts NVIDIA's
driver uses on your board, and keeps them off until you ask. Run the core test above first and send its log. Then, by hand
after boot:
```
echo 1 | sudo tee /sys/module/nouveau/parameters/lab_mem_new
```
From the next level change the memory clock follows the level (the kernel log shows `LAB replay ...: выполнен`, and
`память теперь N МГц` is the memory clock after the step). A level the recording does not contain keeps the memory at the
nearest recorded one. **This is a first run on your board:** a wrong step can corrupt the picture or freeze the machine.
Save your work, keep a second way in (SSH) or be ready to press Reset, and see [boot-recovery.md](boot-recovery.md). Do
not put the switch into `/etc/modprobe.d` until a session has gone well. Send the kernel log as above.
