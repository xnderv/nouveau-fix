@sasim44 — as promised, the build is ready.

It changes the **core clocks automatically by load** (the NVIDIA driver's way: up when busy, down step by step when idle),
with every clock, source and voltage computed from your card's own VBIOS. **Memory stays at your boot clock**, 324 MHz on
your board — your recording will help with the memory part later. On GF108 one hub clock (1595 MHz at the top level on
your board) can't be made exactly by a divider; the build now does what the NVIDIA driver does there — feeds it from the
crossbar PLL running at the same 1595 MHz — and checks the result with the card's clock counter, falling back to a lower
clock if it doesn't match. Your card will be the first to run that path, so please include the output of
`journalctl -k -b | grep -E "hub01-alt|беру снизу"` (partly Russian text — that's fine).

About the VBIOS: your clock tables match ASUS's stock GF108 images of the same generation, and the only difference I can
see is the fan minimum, as you said. Still, could you attach the original unmodified backup? Then I can compare them byte
by byte and work from the stock one.

Instructions: [docs/TESTING-core.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/TESTING-core.md). On Debian 13's
6.12 kernel the patches apply as they are. Please use **one monitor** for this — after your finding we're even more careful
about two.

Use the computer normally for an evening, then attach the kernel log as described. Thank you!
