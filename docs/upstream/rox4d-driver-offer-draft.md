# Issue in xnderv/nouveau-fix for rox4d — final text, awaiting approval (not posted)

Title: GF106 GTS 450 (rox4d): lab driver build for testing — optional

@rox4d — you wrote in Twilight0/nouveau-dkms#9 "let me know if it needed more info (or testing)". Here is something to
test, only if you still want to. Please read the whole thing before deciding — it is an experimental kernel driver, and
there is no obligation at all.

**What it is.** The lab nouveau module (kernel 7.0 here, but the patches apply cleanly to the nouveau in 6.18) with
your card added as a second board: core clocks are switched by nouveau's own gf100 code plus the PTHERM/FSRM bracket
(slowdown code /2, as in your recordings); memory is switched by replaying the PMU scripts and the surrounding host
writes **from your own two recordings** — the exact sequences NVIDIA 390 ran on your card, not ours. The extraction
tool was validated on our recording first (it reproduces our driver's tables byte for byte). The driver checks the chip
and the PCI subsystem (1458:3500) and refuses to touch memory on any other board.

**What your recordings told me.** On your card NVIDIA uses no 135→324 memory script at all: from 135 (and from the
POST state, which is 324 MHz on GF106) it goes straight to 1804 with one script; 1804→324 is one script (a slightly
different one the first time after boot); 324→135 is two scripts back to back. The driver follows that state machine by
reading 0x132000 and will refuse any transition it has not seen in your recordings — in particular, **the first level
change after boot must be 0f**. Voltage: decoded from NVIDIA's GPIO writes, your card runs 1.1125 V at 0f and 0.9625 V at
03/07; nouveau computes the 0f voltage from the VBIOS CVB table and the chip's speedo value, so the build has a floor
option that keeps 0f at no less than 1.1125 V (03/07 stay at the table value).

**Risks, plainly.** Hangs and hard resets are likely during the first attempts; unsaved work can be lost; display
glitches during a transition. I know of no mechanism for hardware damage — clocks and voltages are your VBIOS levels and
the values NVIDIA itself set on your card, and the 0f voltage is capped at that value in the code — but this is a lab
driver with no warranty of any kind. Please run it on a session with nothing important open, ideally with another
machine on hand (ssh) to collect logs. The driver's own log lines are in Russian (it is a lab build); the test script
greps the relevant ones.

**How to build (Debian, your own 6.18 kernel tree, CONFIG_DRM_NOUVEAU=m):**
```
cd linux-6.18.x/drivers/gpu/drm/nouveau
patch -p1 < patches/0001-nouveau-abi16-idle-channel-before-engobj-del.patch
patch -p1 < lab/0002-LAB-fermi-reclock-instrumented.patch
patch -p1 < patches/0004-LAB-pmu-perf-load.patch
patch -p1 < patches/0006-nouveau-therm-mask-pwm-update-bit-on-read.patch   # without it the fan reads 0 % and creeps up by 3 %
cd ../../../..
make -j$(nproc) M=drivers/gpu/drm/nouveau modules
```
(paths are from this repository's root). Back up the stock nouveau.ko, install the new one (depmod; update the initramfs
if nouveau is in it), add
`options nouveau lab_mem_replay=14 lab_volt_min_uv=1112500 lab_pcie=0 lab_clk_mmu_lock=0 lab_gpc_div=1 lab_pmu_div=1`
to /etc/modprobe.d/, reboot, and check `dmesg | grep 'LAB:'` — it should name your board (GF106 GTS 450 …).
The test script is `lab/rox4d-test.sh` (run as root: it sets 0f → 07 → 03 in cycles, logs the driver's dmesg lines and
stops at the first error). What was changed and why is written up in `docs/2026-10-28/rox4d-build.md` (Russian).

**What would help afterwards:** the script's log and dmesg, whatever the outcome. If it hangs, the last lines before
the hang and which level change it was. No rush, and feel free to say no.
