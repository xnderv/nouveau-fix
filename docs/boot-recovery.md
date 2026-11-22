# Test machine boot (since 22.11.2026: lab/safeboot.sh)

- **Default: our module, with a boot guard** (`bash lab/safeboot.sh default-lab`, 22.11). Before booting the LAB line GRUB sets
  `lab_pending=1` in its environment; a service (`nouveau-lab-ok`) clears it 2 minutes after a successful start. If GRUB finds
  the mark still set — the last LAB boot hung — it boots the first menu line (the newest kernel with the distribution's
  nouveau, SSH up), turns the LAB default off (`lab_default=0`) and records `lab_fell_back=1`, so a broken module never loops.
  Back to LAB: `safeboot.sh default-lab`; plain safe default: `safeboot.sh default-safe`. Checked 22.11: LAB boot confirmed,
  a simulated hang fell back, LAB restored.
- **The first menu line is always safe:** the newest kernel with the distribution's own nouveau. Our module is not in the
  normal initramfs and not in /lib/modules. Kernels update the usual way (apt).
- **Our module is in its own image** `/boot/initrd.img-<kernel>.lab` and its own menu line
  "Ubuntu - LAB nouveau (<kernel>)". `bash lab/safeboot.sh lab` boots it once even when the default is safe. If it hangs: Reset or the smart plug, and the machine is back to the safe default.
- **New build or new kernel:** build the module (on the laptop — about 4–5× faster), copy the `.ko`, then
  `bash lab/safeboot.sh install MODULE.ko KERNEL` (two images by dracut, 2–4 min), then `bash lab/safeboot.sh lab`.
- `bash lab/safeboot.sh status` — what runs now, what boots by default and next time, which kernels have a `.lab` image.

The previous arrangements (pinning the kernel in GRUB, a "STABLE nouveau" fallback line, reminders on new kernels, the
autoclock service) are in `archive/daily-2026-11/` and `archive/stable-2026-10/`.
