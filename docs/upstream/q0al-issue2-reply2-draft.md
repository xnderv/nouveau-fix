# Reply 2 to Q0AL in xnderv/nouveau-fix#2 — DRAFT, post after approval

@Q0AL — both are fine, with details:

**"Installed but not loaded at boot".** Debian loads nvidia automatically through udev as soon as the module is installed.
To stop that for the recording, add a file `/etc/modprobe.d/trace-no-autoload.conf` with
```
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
```
then `update-initramfs -u` and reboot. `blacklist` only stops the automatic loading; the script's own `modprobe nvidia`
still works. Also boot into a text console (once: add `systemd.unit=multi-user.target` to the kernel line in GRUB, or
`systemctl stop gdm3` / your display manager before running), and check that `lsmod | grep nvidia` prints nothing
before `sudo trace/run-trace.sh`. Delete the file afterwards.

**Debian version.** Any Debian with a working 390.157 is fine — the script only needs the module, `nvidia-settings`,
`xinit` and `glxgears`, and every Debian kernel has `CONFIG_MMIOTRACE`. What Debian itself ships: `nvidia-legacy-390xx-driver`
390.157-16 is in **sid** (DKMS, patched for current kernels), there is **none in trixie**, and bullseye has 390.157-1~deb11u1
with its 5.10 kernel. So trixie + 6.12 works only if you bring your own 390 build for 6.12 (rox4d did that on 6.18); the
least effort on a spare partition is probably sid's package, or plain bullseye where everything is in the archive.
Whatever boots with 390 loaded by the script is good.

**NVS 5200M and the GDDR5 GT 730 — yes, please, after the GTX 560.** Both are GF108 with GDDR5, a chip we have no
recording of at all, so each is new data. The GT 730 is a desktop card: same procedure. The NVS 5200M in the Latitude
is worth a try too: the only question there is whether X starts on the NVIDIA GPU in that laptop (Optimus); if the
control pass fails to start X, `steps.txt` and `xinit-контроль.txt` will show it and we can adjust the script.
