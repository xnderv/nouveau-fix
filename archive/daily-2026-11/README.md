# Archived: daily helpers of the test machine (Oct–Nov 2026)

The autoclock service (replaced by the in-driver governor on 19 Nov), the login-time "is it our driver" window, the apt hook
and the menu button for new kernels, `newkernel.sh`, `grub-pin.sh` (pinning the kernel in GRUB) and `lab/bootmenu.sh` (the
"STABLE nouveau" fallback line). Retired on 22 Nov 2026 in favour of `lab/safeboot.sh`: the newest kernel with the
distribution's nouveau boots by default, our module only for one boot on demand (docs/boot-recovery.md). Kept for history;
not maintained.
