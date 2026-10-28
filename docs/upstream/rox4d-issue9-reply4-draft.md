# Draft: fourth reply to rox4d in Twilight0/nouveau-dkms#9 (28.10.2026, not posted)

Thanks for the second recording — it reproduces the first one exactly (same transition groups, same 21–23 µs waits in
the PTHERM brackets), so both now count as confirmed on your card.

We also pulled the memory-clock scripts your driver uploads to the PMU out of your trace (14 uploads, four distinct
scripts) and compared them with scripts our generator builds from a VBIOS: formulas from the VBIOS tables (timings,
mode registers, ramcfg nibbles) and the post-POST register state from the VBIOS init scripts. On our GTX 560 Ti the
generated scripts match the driver byte for byte; on your card we had to use a stand-in VBIOS from TechPowerUp (same
version 70.06.13.00.01, Gigabyte GTS 450) and 88 % of the values on the shared registers already match. What differs is
chip-shaped (GF106 uses 0x13d874 where GF114 uses 0x13d8f4, a different memory-partition set, a 567 MHz reference PLL)
and the bits the driver sets at load, which is exactly what we want to learn from your card.

Could you send one more small thing — your card's own VBIOS image? On Linux it is two commands, no reflashing involved:

    echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom
    sudo cat /sys/bus/pci/devices/0000:01:00.0/rom > gts450.rom
    echo 0 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom

(replace 0000:01:00.0 with your card's address from `lspci`; the file is about 64 KB). With the real image the comparison
becomes exact instead of "same version, probably same tables", and your card becomes the second chip the generator is
verified on. If you'd rather not share the image publicly, a private attachment is fine too.

One finding from the 300-image VBIOS survey that concerns your card: GTS 450 firmware comes in two waves. The early one
(70.06.0f/13, yours) leaves the hub slowdown register 0x020164 at 0 after POST; from 70.06.1f on it is pre-set to 0x20082,
which is the code the driver writes during every clock switch anyway. The driver behaves the same either way, so nothing
to do — just so the numbers in your pre-driver snapshot make sense.
