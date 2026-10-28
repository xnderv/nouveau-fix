# Draft: fifth reply to rox4d in Twilight0/nouveau-dkms#9 (28.10.2026, not posted)

Good question, and the difference is expected — it does not mean your BIOS is modified.

What the two methods read:
- `nvflash` dumps the SPI flash chip itself: the whole 64–128 KB, with the x86 legacy image, the UEFI (GOP) image if the
  board has one, the NBSI/IFR headers in front, and the padding between them.
- `/sys/bus/pci/devices/…/rom` (and card-report.sh when nouveau is not loaded) reads through the card's PCI expansion-ROM
  window. On NVIDIA boards that window usually exposes only the x86 image, and on some boards the image is served from a
  shadow copy with a different layout, so the file is shorter and the bytes don't line up with the flash dump even
  though the tables inside are the same. card-report.sh prefers a third source when nouveau is loaded: the copy nouveau
  itself fetched at boot (`/sys/kernel/debug/dri/0/vbios.rom`), which is the one nouveau's parsers are written for.

All three contain the same BIT tables (the version string, 70.06.13.00.01 in your Xorg log, is inside them), and our
tools locate the tables by their signature, so any of the files works. The nvflash dump is the most complete one, so if
you still have it, that's the one to send — otherwise the sysfs file is fine. A quick way to see they agree: our survey
prints the device id, version and the performance levels from either file:

    python3 -I lab/vbios-survey.py --text your.rom

Thanks also for mentioning the earlier mod-and-restore; the pre-driver register snapshot from your trace matched the init
scripts of a stock 70.06.13 image from TechPowerUp register for register (0x020130, 0x020164, the clock dividers), which
is independent evidence that what's in your card now is the original firmware.
