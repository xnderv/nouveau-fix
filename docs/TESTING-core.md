# Testing the automatic core reclocking (Fermi, November 2026)

This build changes the **core clocks automatically by load**, the way the NVIDIA driver does: up to the top level when the
GPU is busy, down step by step when it is idle. All core clocks, sources and voltages are computed from **your card's own
VBIOS**; nothing in it is tuned for one particular board. No service and no module options are needed.

**Memory clock:** stays where your VBIOS puts it at power-on (on most boards 135 or 324 MHz), except on the two boards whose
NVIDIA memory scripts we have recorded (GTX 560 Ti Gigabyte 1458:3515, GTS 450 Gigabyte 1458:3500). So you get the full
core clock with the memory at its boot clock: a clear gain in compute-heavy work, less in memory-heavy 3D.

Tested on our GTX 560 Ti (GF114): 10,000 core switches under load without a hang, and 900 automatic switches overnight
without an error. On your card it has not run yet — that's what we ask you for.

## Before you start
- **Post your card report first** (`bash tools/card-report.sh`, attach the output to your issue) and wait for an OK. On
  one GF108 board the VBIOS asks for a hub clock that a divider can't make exactly, and this build would set it 16 % higher;
  the report shows in a minute whether your board has that case.
- **One monitor.** We have never tested with two or more displays. Please unplug the others for these tests.
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
