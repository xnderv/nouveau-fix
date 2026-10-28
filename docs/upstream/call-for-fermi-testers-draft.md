# Call for Fermi GDDR5 cards — posted 28.10.2026 21:31 MSK: issue https://github.com/xnderv/nouveau-fix/issues/2; line for Q0AL in Twilight0#5: https://github.com/Twilight0/nouveau-dkms/issues/5#issuecomment-6477307415

## Кандидаты (28.10)
- **Q0AL** (Twilight0/nouveau-dkms#4, #5): Debian sid; NVS 5200M (GF108M, **GDDR5**) и **GTX 560 (GF114 — наш чип, GDDR5)**;
  10.10 обещал отчёт с GTX 560, не прислал. Лучший кандидат: тот же чип, что у нас; нужна его запись (плата другая).
- В репозитории Twilight0 остальные — ноутбуки с DDR3 (GF119M, GF108M DDR3) и Kepler/Pascal: не наш случай.
- Поиск по GitHub за год «fermi nouveau reclock», «GTX 560/570/460, GTS 450, GTX 550 + nouveau» — ничего по делу.
- Площадка с нужной аудиторией — список рассылки nouveau (nouveau@lists.freedesktop.org); Phoronix/Reddit — шире, но шумнее.

## Вариант 1 — issue в xnderv/nouveau-fix (публичный призыв) + одна строка Q0AL в Twilight0 #5
Title: Fermi GDDR5 owners (GF114/GF106/GF116/GF110): one evening of recording → a lab driver build for your card

We are building a model of how NVIDIA's own driver (390.157, the last one for Fermi) manages clocks on GF11x, and a lab
nouveau module that replays the memory-clock sequences the NVIDIA driver ran **on the same card**. Two cards are covered so
far: our GTX 560 Ti (GF114) and rox4d's GTS 450 (GF106, build offered in #1). Each additional card with GDDR5 adds data we
cannot get otherwise.

What it takes on your side (one evening, no permanent changes):
1. A spare disk or partition with Linux, NVIDIA 390.157 and a kernel with CONFIG_MMIOTRACE (Debian/Ubuntu kernels have it);
   our script `trace/run-trace.sh` does the rest: loads the driver, runs a control pass and a recorded pass with marked phases.
2. Your VBIOS image (`cat /sys/bus/pci/devices/0000:01:00.0/rom` after `echo 1 > rom`, or nvflash).
3. Send the archive (a few hundred MB compressed) as an attachment or a link.

What you get: a build of the lab driver with your card's own sequences (see #1 for what that means and the risks — it is
an experimental kernel module; hangs are possible, no warranty), and everything we learn goes into this repository.

Cards of interest: GTX 460/465/470/480/550 Ti/560/560 Ti/570/580, GTS 450, Quadro 2000/4000/5000/6000 — anything GF100–GF119
with GDDR5. Mobile GF119M/GF108M with DDR3: Twilight0's project covers those.

This is a hobby project: no support promises, no schedule. We answer when we can, and if we stop, we will say so here.
Everything we learn is published in this repository regardless.

Строка в Twilight0 #5 (после его «ill also post a report from a GTX 560»):
> If the GTX 560 is still around: a recording of the NVIDIA 390 driver on it (one evening, script provided) would be
> especially useful for us — it is the same chip as our card. Details and what you would get back are in
> https://github.com/xnderv/nouveau-fix/issues/<N>; entirely optional.

## Вариант 2 — письмо в список рассылки nouveau (от имени пользователя, с его почты)
Subject: [RFC] Fermi (GF11x) reclocking: NVIDIA 390 traces wanted from GDDR5 cards, lab module available
(текст — тот же призыв + краткие результаты: 992 переходов 270.41.06 без застреваний, выдержка 2,2→4 мкс, скрипты памяти
по плате; ссылка на репозиторий. Писать только после согласия пользователя; рассылка — публичный архив навсегда.)
