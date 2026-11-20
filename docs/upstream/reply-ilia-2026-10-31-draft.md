# Ответ Илье Миркину (рассылка nouveau) — черновик 31.10.2026

Отвечать из почты кнопкой «Ответить всем», чтобы рассылка осталась в копии. Текст обычный, без HTML.

---

Hi Ilia,

Thank you for digging it out, this is very useful.

One thing in Ben's branch matches our results exactly: "bios/perf: parse flags attached to clock frequencies" (bit 0x8000
= no PLL, bit 0x4000 = no divider, marked "not entirely certain"). We arrived at the same reading independently from the
trace database Martin gave us access to: across 32 Fermi boards the NVIDIA driver's choice between a PLL and a divider
followed those two bits in all 425 clock/level pairs we checked, and where neither bit is set it follows the frequency.
So Ben was right.

In the branch the flags only reach the memory code, though; the core clocks still go through the existing gf100 code.
On our GTX 560 Ti that code has a few problems that would explain "works on some boards, not on others": the PLL bypass bit
set after lock (our core ended up at ~25 MHz), the hubk06 PLL reference taken as 1620 MHz instead of 405, no PTHERM
slowdown around the mux switches (the NVIDIA driver always does that), and the switch carrying on after a mux timeout.

About your Quadro 600: in the VBIOS images we have of that board (10de:0df8) the top level asks for 1280 MHz on hubk01
while hubk06, whose PLL hubk01 has to share, is at 1012 MHz. The table cannot be met there, and we don't know what the
NVIDIA driver does in that case. If you still have the card and ever feel like recording the NVIDIA 390 driver on it
(our script does it in one evening, see issue #2 on github.com/xnderv/nouveau-fix), that would close exactly that gap.
No pressure at all.

We'll credit Ben's branch when any of this goes upstream.

Cheers,
Alex
