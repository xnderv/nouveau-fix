<!-- Draft 31.10.2026: reply to Q0AL in issue #2 (public). Not posted. Same content as the e-mail draft
(q0al-mail-reply1-draft.md), adapted for the issue; the e-mail itself becomes a short note pointing here. -->

@Q0AL — thanks again for the recording: it turned out to be one of the most useful pieces of data we have.

No need to dump the VBIOS after all. The NVIDIA driver reads the full image from the card when it starts, and it is right
there in your recording, so we rebuilt it from that (version 70.24.18.00.64). Please ignore my earlier request for a dump.

What your card showed us. We now compute the core clock settings for each performance level from the card's own VBIOS
instead of copying them from a recording. On your card that matched what the NVIDIA driver set everywhere except two points
at the top level, and those two points were the key: they showed that the choice between a PLL and a plain divider for each
clock comes from a flag in the VBIOS performance table, not from arithmetic. We checked that rule against recordings from 32
other Fermi boards in the nouveau trace archive, and it holds on all of them. Your recording also showed which of two equal
PLL settings the NVIDIA driver picks for the core clock (63/15 rather than 21/5 for 1701 MHz); the build follows that too.
The voltage needs no tweak: your 1.0125 V at the top level is exactly what the VBIOS formula gives, and nouveau rounds the
same way.

If you are up for it, here is a lab build of nouveau that changes only the core clocks. Memory stays where the VBIOS leaves
it at boot, so the card will be slower than with the NVIDIA driver, but nothing touches the memory controller.
We ran the same build and settings (plus PCIe speed changes, which your line leaves off) on our GTX 560 Ti:
2000 switches between the levels under a browser load, no hangs and no GPU errors.
Twice the core did not move from its divider to the PLL on the way up; the driver noticed, left it at 810 MHz for that one
round and the next switch was normal.

What it takes (about half an hour, most of it the build):

1. Boot with nouveau instead of the NVIDIA driver. The NVIDIA packages blacklist nouveau;
   `grep -rl nouveau /etc/modprobe.d /usr/lib/modprobe.d` shows where. Comment that line out (you can put it back later),
   keep the NVIDIA modules from loading the way you did for the recording, run `sudo update-initramfs -u` and reboot.
   `lsmod | grep nouveau` should list it. If Secure Boot is on (`mokutil --sb-state`), the unsigned lab module will not
   load; it would need to be off for the test.
2. Get the tools and this repository:
   ```
   sudo apt install git build-essential linux-headers-$(uname -r)
   git clone https://github.com/xnderv/nouveau-fix && cd nouveau-fix
   ```
3. Build and install the module for your running kernel:
   ```
   bash lab/tester-build.sh
   bash lab/tester-build.sh install
   ```
   The first command fetches the nouveau sources of your kernel version (a sparse clone of that tag from
   github.com/gregkh/linux, about 15 MB), applies our four patches and builds; it stops and changes nothing if a patch does
   not apply. The second one copies the module to `/lib/modules/<kernel>/updates` and asks for sudo.
   `bash lab/tester-build.sh remove` undoes it.
4. Put this single line into `/etc/modprobe.d/nouveau-lab.conf`:
   ```
   options nouveau lab_mem=0 lab_vbios_src=1 lab_gpc_div=1 lab_pmu_div=1 lab_gpc_seq=13 lab_mux_guard=1 lab_nv_div_late=1 lab_clk_mmu_lock=0
   ```
   then `sudo update-initramfs -u` and reboot.
5. Run the test from the repository folder, in a terminal of your normal desktop session:
   ```
   sudo bash lab/rox4d-test.sh
   ```
   (The name is historical; with lab_mem=0 it works for any Fermi card.) It switches 0f -> 07 -> 03 three times with
   20-second pauses, checks the kernel log before and after every step, stops at the first error line, and writes
   `rox4d-test-<date>.log` and `.log.dmesg` in the current folder. Please attach both files here (zip them if GitHub
   refuses the extension), whatever the outcome; by e-mail is fine too if you prefer.

If something hangs, a reboot brings everything back (the module only changes clocks while it runs); please send the logs
anyway. Could you also post the output of `uname -r`? No rush, and no obligation.

The build is commit 7dd2c79 in the repository (lab/0002, lab/tester-build.sh, lab/rox4d-test.sh).
