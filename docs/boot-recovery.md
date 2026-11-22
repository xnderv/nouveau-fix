# Test machine boot (since 22.11.2026: lab/safeboot.sh)

- **By default GRUB boots the first menu line — the newest kernel with the distribution's own nouveau.** Our module is not in
  the normal initramfs and not in /lib/modules. Kernels update the usual way (apt); after any reboot, Reset or power cut the
  machine comes up this way, with SSH. The card works at its boot clocks.
- **Our module is in its own image** `/boot/initrd.img-<kernel>.lab` and its own menu line
  "Ubuntu - LAB nouveau (<kernel>, one boot)". Before experiments: `bash lab/safeboot.sh lab` — the next boot, and only that
  one, uses it. If it hangs: Reset or the smart plug, and the machine is back to the safe default.
- **New build or new kernel:** build the module (on the laptop — about 4–5× faster), copy the `.ko`, then
  `bash lab/safeboot.sh install MODULE.ko KERNEL` (two images by dracut, 2–4 min), then `bash lab/safeboot.sh lab`.
- `bash lab/safeboot.sh status` — what runs now, what boots by default and next time, which kernels have a `.lab` image.

The previous arrangements (pinning the kernel in GRUB, a "STABLE nouveau" fallback line, reminders on new kernels, the
autoclock service) are in `archive/daily-2026-11/` and `archive/stable-2026-10/`.
