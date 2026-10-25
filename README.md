# nouveau-fix: full reclocking for GeForce GTX 560 Ti (Fermi, GF114) on Linux

**English first; the same in Russian below. / Русская версия — ниже.**

> **Если машина автора не загружается (на время тестов лабораторного драйвера, с 25.10.2026)**
> 1. Экран чёрный или завис — нажми кнопку **Reset** (или подожди: при панике ядра машина сама перезагрузится через 10 с).
> 2. При старте 5 с видно меню GRUB (после сбоя оно ждёт 30 с). Стрелками выбери **третью строку**
>    `Ubuntu - STABLE nouveau (if the lab driver fails)` и нажми **Enter**.
> 3. Загрузится стабильный драйвер (копия от 19.10). Работай как обычно; лабораторный остаётся на диске, его разберём потом.
> 4. Меню не появилось — при старте держи **Shift**. Совсем ничего не помогает — в меню «Advanced options» → «recovery mode».
>
> *If the author's machine does not boot during lab-driver tests: Reset, then pick the 3rd GRUB line
> “Ubuntu - STABLE nouveau (if the lab driver fails)”. Set up by `lab/bootmenu.sh`.*

Upstream nouveau keeps Fermi cards at their boot clocks: a GTX 560 Ti stays at 50 MHz core and 135 MHz memory, so it
is slow in 3D and video. This project makes the card switch between its performance levels the way the NVIDIA
driver does, using only open methods, and tries to turn what we learn into changes that can go upstream.

| Level | Core / shader | Memory | When |
|---|---|---|---|
| 03 | 50 / 101.25 MHz | 135 MHz | idle |
| 07 | 405 / 810 MHz | 324 MHz | desktop, video |
| 0f | 900 / 1800 MHz | 2004 MHz (4 GT/s) | 3D, heavy load |

The reference board is a Gigabyte GV-N560OC-1GI (PCI subsystem 1458:3515). Its 0f level is a factory overclock;
03 and 07 are the chip's standard levels.

## Status (24 Oct 2026) — beta

- **Reclocking works on the reference board** — core, shader, memory, voltage, PCIe 2.5/5 GT/s, and an automatic
  governor that uses load measured in the PMU firmware.
- **The cause of the remaining hangs is found and fixed in the lab driver.** The VBIOS stores whole megahertz
  (101 for 101.25 MHz), and nouveau took that as an exact target. At level 03 it therefore put the shader clock
  on its PLL, while NVIDIA uses the 1620 MHz divider. Switching away from that PLL could wedge the GPU. With the
  divider, as NVIDIA does it, 900 level switches under browser load (tests 22–33a, 60 per test) passed without a
  single hang. The same rounding made nouveau run the PMU at 216 instead of 202.5 MHz; that is fixed too.
- **NVIDIA's order of operations is reproduced step by step**, each step behind its own switch and tested alone:
  `docs/2026-10-24/nvidia-logic.md` explains what NVIDIA does and why.
- **The author's daily driver** is the lab driver (`lab/`) with these settings, applied by `daily/gpu-autoclock.py`.
  The stable patch (`patches/0010`) does not have the divider and PMU fixes yet; a clean stable version with them is next.
- **Memory reclock is board-specific for now.** It replays the memory scripts recorded on the reference board,
  just as upstream nouveau replays a sequence recorded on another board. A generator from each card's own VBIOS
  tables is in progress (`docs/2026-10-24/memory-scripts-vs-nouveau.md`). **Data from other cards is what it needs.**

## How we work

- **Only open methods.** We observe how the NVIDIA 390 driver talks to the hardware (the kernel's built-in
  mmiotrace), read the VBIOS data tables, and use open sources: nouveau, envytools, and NVIDIA's own open nvgpu
  driver. We do not use decompiled or disassembled NVIDIA code, or anything derived from it.
- **No NVIDIA binaries in this repository.** VBIOS images and raw traces stay private; only findings and register
  values are published.
- **One change per test.** Every step is a separate switch, tested alone on the hardware, with the logs in `results/`.

## Help wanted: data from other Fermi cards

Owners of other Fermi cards — GTX 460–590, GTS 450, GT 4xx/5xx and mobile parts — can help the most by sharing their
card's VBIOS tables:

1. `git clone https://github.com/xnderv/nouveau-fix && cd nouveau-fix && bash tools/card-report.sh`.
   It only reads. It prints a summary of your VBIOS tables, asks a few questions (vendor, cooling, factory
   overclock), and with your consent saves an archive in your home folder.
2. Open a **Card data** issue and paste the summary there.
3. Send the archive to **xnderv@yandex.com**. Please don't attach it to the issue: the image belongs to NVIDIA and your
   card's vendor, so we never publish it, only values from its tables.

Hangs and results on other boards: the **Hang report** and **Hardware report** issue forms.

## Install (Ubuntu, kernel 7.0.x)

Needs `dkms build-essential patch git linux-headers-generic`.

| Command | What it does |
|---|---|
| `bash stable/stable.sh install` | stable driver via DKMS (rebuilt for every new kernel): patches 0001 + 0003 + 0010 |
| `bash stable/stable.sh status` | loaded driver, level, load, temperature, PCIe link, events |
| `bash lab/lab.sh install` | lab driver: 0001 + lab 0002 + 0003 + 0004 + 0005 + 0006, with `lab_*` switches for every step |
| `bash tools/card-report.sh` | read-only report about your card (see above) |

Reclocking is active only on the reference board. On any other card the driver behaves like upstream; the stable
driver tries other GF114 boards with `nouveau.gf114_board=1` (untested; watch for VRAM errors).

## Patches (`patches/`, on top of nouveau in Linux 7.0.x)

- `0001` — a GPU hang when a Chromium-based app deletes an engine object while the channel is still busy
  (`nouveau_abi16.c`; candidate for upstream).
- `0003` — HDMI was refused when the monitor supports SCDC and the GPU does not; refuse only above 340 MHz.
  Fixed upstream independently in Sept 2026 (`1717fcc5be57`); skipped automatically where present.
- `0004` (lab) — load accounting in the PMU firmware and the in-driver governor. `0005` (lab) — HDMI AVI InfoFrame ITC.
- `0006` — the fan could drop to 3 % on its own: nouveau read back the PWM duty with the update bit still set, and its
  u32 math turned that into 0 % (race between its two fan timers; `docs/2026-10-24/vent-20261024.md`). Candidate for upstream.
- `0010` — stable reclocking for the reference board (22–24 Oct); it does not yet have the shader-divider and PMU
  clock fixes from the lab driver.
- `lab/0002` — the instrumented reclocking with all switches.

## Where things are

| Path | Contents |
|---|---|
| `docs/2026-10-24/nvidia-logic.md` | how NVIDIA reclocks GF114 and why: rules, open questions, what we do the same way |
| `docs/2026-10-24/nvidia-vs-lab-map.md` | register-level map: NVIDIA vs the lab driver, every recording |
| `docs/2026-10-24/memory-scripts-vs-nouveau.md` | memory scripts: NVIDIA vs nouveau vs VBIOS tables |
| `docs/2026-10-23/hang-20261023-1802.md` | the hang investigation, tests 1–24 |
| `lab/` | lab driver, test series (`night.sh`, `hangtest.sh`), probes, VBIOS parsers |
| `trace/` | mmiotrace recording kit (a separate boot disk with the NVIDIA 390 driver) |
| `results/` | test logs |
| `stable/`, `daily/` | stable DKMS driver; the service that applies the daily settings |

---

# nouveau-fix: полная смена частот для GeForce GTX 560 Ti (Fermi, GF114) в Linux

Штатный nouveau оставляет карты Fermi на частотах загрузки: GTX 560 Ti так и работает на 50 МГц ядра и 135 МГц памяти,
в 3D и видео она медленная. Проект научил карту переключать уровни производительности так же, как это делает драйвер
NVIDIA, — только открытыми методами — и старается превратить найденное в правки, пригодные для основного ядра.

| Уровень | Ядро / шейдеры | Память | Когда |
|---|---|---|---|
| 03 | 50 / 101,25 МГц | 135 МГц | простой |
| 07 | 405 / 810 МГц | 324 МГц | рабочий стол, видео |
| 0f | 900 / 1800 МГц | 2004 МГц (4 ГТ/с) | 3D, тяжёлая нагрузка |

Эталонная плата — Gigabyte GV-N560OC-1GI (подсистема PCI 1458:3515). Уровень 0f у неё — заводской разгон;
03 и 07 — штатные уровни чипа.

## Состояние (24.10.2026) — бета

- **Смена частот работает на эталонной плате**: ядро, шейдеры, память, напряжение, PCIe 2,5/5 ГТ/с и регулятор,
  который сам выбирает уровень по загрузке, измеренной в прошивке PMU.
- **Причина оставшихся зависаний найдена и устранена в лабораторном драйвере.** VBIOS хранит целые мегагерцы
  (101 вместо 101,25 МГц), а nouveau принимал это число за точную цель. Поэтому на уровне 03 он ставил шейдерный
  такт на PLL, а NVIDIA — на делитель от 1620 МГц. Переход с этого PLL мог подвесить карту. С делителем, как у NVIDIA,
  900 переключений уровней под нагрузкой браузера (тесты 22–33а, по 60 в каждом) прошли без единого зависания.
  То же округление заставляло nouveau гнать PMU на 216 МГц вместо 202,5 — тоже исправлено.
- **Порядок действий NVIDIA повторён по шагам**: каждый шаг — отдельный переключатель, проверен отдельно.
  Что и зачем делает NVIDIA — `docs/2026-10-24/nvidia-logic.md`.
- **Ежедневный драйвер автора** — лабораторный (`lab/`) с этими настройками, их выставляет служба
  `daily/gpu-autoclock.py`. В стабильном патче (`patches/0010`) исправлений делителя и PMU ещё нет; чистая стабильная версия с ними — следующий шаг.
- **Смена частоты памяти пока привязана к плате.** Она проигрывает скрипты памяти, записанные на эталонной плате, —
  так же, как штатный nouveau проигрывает последовательность, записанную когда-то на другой плате. Генератор по
  таблицам VBIOS каждой карты в работе (`docs/2026-10-24/memory-scripts-vs-nouveau.md`). **Ему нужны данные других карт.**

## Как мы работаем

- **Только открытые методы.** Наблюдаем, как драйвер NVIDIA 390 обращается к железу (встроенный в ядро mmiotrace),
  читаем таблицы данных VBIOS, опираемся на открытые источники: nouveau, envytools и открытый драйвер самой NVIDIA nvgpu.
  Декомпилированный или дизассемблированный код NVIDIA и всё, что из него получено, не используем.
- **Никаких бинарных файлов NVIDIA в репозитории.** Образы VBIOS и сырые записи остаются у нас; публикуются только
  выводы и значения регистров.
- **Одно изменение на опыт.** Каждый шаг — отдельный переключатель, проверенный отдельно на железе; журналы — в `results/`.

## Нужна помощь: данные других карт Fermi

Больше всего помогут владельцы других карт Fermi — GTX 460–590, GTS 450, GT 4xx/5xx и мобильных — если поделятся
таблицами VBIOS своей карты:

1. `git clone https://github.com/xnderv/nouveau-fix && cd nouveau-fix && bash tools/card-report.sh`.
   Скрипт только читает. Он печатает разбор таблиц VBIOS, задаёт несколько вопросов (производитель, охлаждение,
   заводской разгон) и с вашего согласия сохраняет архив в домашнем каталоге.
2. Откройте на GitHub заявку **Card data** и вставьте туда разбор.
3. Сам архив отправьте на **xnderv@yandex.com**. Не прикладывайте его к заявке: образ принадлежит NVIDIA и производителю
   карты, поэтому мы его никогда не публикуем — только значения из его таблиц.

Зависания и результаты на других платах — формы **Hang report** и **Hardware report**.

## Установка (Ubuntu, ядро 7.0.x)

Нужны пакеты `dkms build-essential patch git linux-headers-generic`.

| Команда | Что делает |
|---|---|
| `bash stable/stable.sh install` | стабильный драйвер через DKMS (сам пересобирается под каждое новое ядро): патчи 0001 + 0003 + 0010 |
| `bash stable/stable.sh status` | какой драйвер загружен, уровень, загрузка, температура, шина PCIe, события |
| `bash lab/lab.sh install` | лабораторный драйвер: 0001 + лабораторный 0002 + 0003 + 0004 + 0005 + 0006, с переключателями `lab_*` на каждый шаг |
| `bash newkernel.sh` | после установки нового ядра, до перезагрузки: проверить и при необходимости дособрать драйвер |
| `bash tools/card-report.sh` | отчёт о вашей карте, только чтение (см. выше) |

Смена частот включается только на эталонной плате; на других картах драйвер ведёт себя как штатный. Стабильный драйвер
можно попробовать на другой плате GF114 параметром `nouveau.gf114_board=1` (не проверено; следите за ошибками видеопамяти).

Старый путь «только исправление 0001» (`rebuild.sh`, `check.sh`, `revert.sh`) сохранён для истории.

## Где что лежит

| Путь | Что там |
|---|---|
| `docs/2026-10-24/nvidia-logic.md` | как NVIDIA меняет частоты GF114 и почему: правила, белые пятна, что у нас так же |
| `docs/2026-10-24/nvidia-vs-lab-map.md` | карта регистров: NVIDIA против лабораторного драйвера, все записи |
| `docs/2026-10-24/memory-scripts-vs-nouveau.md` | скрипты памяти: NVIDIA, nouveau и таблицы VBIOS |
| `docs/2026-10-23/hang-20261023-1802.md` | расследование зависаний, тесты 1–24 |
| `lab/` | лабораторный драйвер, серии тестов (`night.sh`, `hangtest.sh`), пробники, разборщики VBIOS |
| `trace/` | набор для записи mmiotrace (отдельный загрузочный диск с драйвером NVIDIA 390) |
| `results/` | журналы тестов |
| `stable/`, `daily/` | стабильный драйвер DKMS; служба, выставляющая ежедневные настройки |
