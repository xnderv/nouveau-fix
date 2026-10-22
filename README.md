# nouveau-fix: full reclocking for GeForce GTX 560 Ti (GF114) on Linux

**English summary — the rest of this file is in Russian.**

Upstream nouveau leaves Fermi cards at their boot clocks (GTX 560 Ti: core 50 MHz, memory 135 MHz),
because its memory reclock sequence for GF100-class chips was recorded from one old board and does not
work on others. This repository contains a nouveau driver build in which a GTX 560 Ti runs at its
full factory clocks, switching between performance levels automatically, the way the NVIDIA driver does:

| Level | Core / shader | Memory | When |
|---|---|---|---|
| 03 | 50 / 101 MHz | 135 MHz | idle |
| 07 | 405 / 810 MHz | 324 MHz | desktop, video |
| 0f | 900 / 1800 MHz | 2004 MHz (4 GT/s) | 3D load |

How it was done: the NVIDIA 390 driver was traced with mmiotrace on this board; the PMU memory scripts,
PLL settings, voltages, PCIe link speed, busy-counter setup and the order of operations were extracted
from the trace and reproduced in nouveau, one change at a time, each verified on the hardware
(`docs/`, `results/`). The load accounting runs in the PMU firmware (a new `PERF` process), the decision
is taken in the driver once a second; a thermal brake lowers the level at 90 / 95 °C.

**Patches** (`patches/`, on top of the nouveau in Linux 7.0.x):
- `0001` — fix for a GPU hang when a Chromium-based app deletes an engine object while the channel is busy
  (`nouveau_abi16.c`, candidate for upstream);
- `0003` — HDMI mode was refused (fell back to DVI, no audio/InfoFrames) whenever the monitor supports SCDC
  and the GPU does not; only refuse above 340 MHz. Fixed upstream independently in Sept 2026
  (commit `1717fcc5be57`); kept here for 7.0.x kernels and skipped automatically once the fix is present;
- `0010` — the reclocking itself. Board-gated: active only on Gigabyte GV-N560 (PCI subsystem 1458:3515);
  everywhere else the driver behaves like upstream. `nouveau.gf114_board=1` enables it on any GF114 board
  (untested — the memory scripts come from this board's VBIOS, yours may differ; watch for VRAM errors),
  `nouveau.gf114_gov=0` disables the governor, `/sys/module/nouveau/parameters/gf114_*` shows load and temperature.

**Install** (Ubuntu, kernel 7.0.x; needs `dkms build-essential patch git linux-headers-generic`):
`bash stable/stable.sh install`, reboot, `bash stable/stable.sh status`. DKMS rebuilds the module for every
new kernel. `lab/` holds the instrumented driver (`lab/0002-*.patch`, `patches/0004`, `0005`) with runtime
switches for every step, and the scripts of all experiments; `trace/` is the mmiotrace tooling.

Known differences from the NVIDIA driver and open questions are listed in `docs/2026-10-22/review-driver.md`.
Reports from other GTX 560 / 560 Ti boards are welcome (open an issue with `dmesg | grep -i nouveau` and
`stable.sh status` output).

---

# nouveau-fix — исправление зависаний GTX 560 Ti (Fermi) в Ubuntu

## Что это и зачем

Драйвер nouveau (ядро Linux 7.0 и новее, проверено до 7.3) при удалении графического объекта
по запросу программы не дожидается, пока карта закончит связанную работу. Программы на Chromium
(Яндекс Браузер, Claude, Cursor) при старте создают и сразу удаляют пробные 3D-объекты. Если в этот
момент карта занята рабочим столом (анимация запуска из Dash, движение мыши), она обращается к уже
удалённому контексту → `fifo: fault ... [HUB/CTXCTL] ... PAGE_NOT_PRESENT` → канал убит → экран встаёт.

Исправление (`patches/0001-...patch`, ~15 строк, файл `nouveau_abi16.c`) добавляет ожидание
`nouveau_channel_idle()` перед удалением объекта — так же, как это делает старый путь `GPUOBJ_FREE`.
Проверено 2026-10-19: 10 запусков из Dash подряд без ошибок (до исправления падало почти каждый раз).

Пока исправление не принято в ядро, **каждое новое ядро Ubuntu приходит без него** — его нужно пересобрать.

## Стабильный драйвер (с 22.10.2026) — основной способ

Один драйвер, без переключателей, ставится через DKMS и **сам пересобирается под каждое новое ядро**:
исправление гонки (0001) + HDMI без SCDC (0003) + полная смена частот для GTX 560 Ti (0010):
память скриптами NVIDIA, PLL как у NVIDIA, порядок как у NVIDIA, PCIe 2,5/5 GT/s, учёт загрузки в прошивке PMU,
регулятор режимов 03/07/0f в драйвере с температурным тормозом (≥ 90 °C — не выше 07, ≥ 95 °C — 03), флаг ITC в HDMI.
Всё включается только на плате Gigabyte 1458:3515; на других картах драйвер ведёт себя как штатный
(`nouveau.gf114_board=1` — попробовать на другой GF114, `nouveau.gf114_gov=0` — выключить регулятор).

| Команда | Что делает | Пароль |
|---|---|---|
| `bash ~/nouveau-fix/stable/stable.sh install` | ставит исходники в DKMS, собирает под текущее ядро, убирает службу и ручные сборки | да |
| `bash ~/nouveau-fix/stable/stable.sh status` | какой драйвер загружен, режим, загрузка, температура, шина, события | частично |
| `bash ~/nouveau-fix/newkernel.sh` | после установки нового ядра, до перезагрузки: проверить/досабрать | при сборке |
| `bash ~/nouveau-fix/lab/lab.sh install` | поставить лабораторный драйвер (с переключателями `lab_*`) вместо стабильного | да |

Нужны пакеты: `dkms build-essential patch git` и заголовки ядра (`linux-headers-generic`).

## Команды (старый путь: только исправление гонки)

| Команда | Что делает | Пароль |
|---|---|---|
| `~/nouveau-fix/rebuild.sh` | скачивает исходники nouveau под **самое новое установленное** ядро, накладывает исправление, собирает и (после твоего `y`) ставит | только на установке |
| `~/nouveau-fix/rebuild.sh 7.0.0-40-generic` | то же для конкретного ядра | только на установке |
| `~/nouveau-fix/check.sh` | показывает, какой драйвер работает сейчас, сколько раз сработало исправление и были ли ошибки карты | нет |
| `~/nouveau-fix/revert.sh` | возвращает стандартный драйвер Ubuntu для текущего ядра | да |

Стандартный драйвер Ubuntu никогда не удаляется: наш кладётся рядом, в `/lib/modules/<ядро>/updates/nouveau-fix/`.

## Порядок действий при обновлении ядра

1. Ubuntu поставила обновления, среди них новое ядро (`linux-image-...`).
2. **До перезагрузки** открой Терминал и запусти `~/nouveau-fix/rebuild.sh`.
   Скрипт сам возьмёт самое новое ядро. Ответь `y`, введи пароль.
3. Перезагрузись.
4. Запусти `~/nouveau-fix/check.sh` — должно быть «НАШ драйвер с исправлением ✅».

Если забыл и уже перезагрузился в новое ядро — ничего страшного: пока не пересоберёшь, запускай
Яндекс и Claude **из Терминала** (так гонка почти не возникает), выполни `rebuild.sh` и перезагрузись.

## Что может сказать `rebuild.sh`

- **«Исправление наложено… Готово»** — всё хорошо.
- **«Исправление УЖЕ ЕСТЬ в этой версии Linux»** — разработчики приняли правку, пересобирать больше не нужно.
  Можно запустить `revert.sh` на старых ядрах, а сам набор хранить на память.
- **«Исправление НЕ накладывается»** — код драйвера в новой версии изменился. Ничего не установлено,
  система на стандартном драйвере. Покажи вывод ассистенту — патч нужно обновить.
- **«Сборка НЕ удалась» / «Нет заголовков ядра»** — ничего не установлено. Для заголовков:
  `sudo apt install linux-headers-<версия ядра>`. Остальное — показать ассистенту лог из `~/nouveau-build/fix-<ядро>/build.log`.

## Подробный журнал драйвера

Для разбора неисправностей драйвер умеет писать подробный журнал. Включается параметром загрузки
`nouveau.debug=...` в `/etc/default/grub` (строка `GRUB_CMDLINE_LINUX_DEFAULT`), затем `sudo update-grub` и перезагрузка.

- Для частот (сейчас): `nouveau.debug=clk=trace,fb=trace,volt=trace,pmu=debug` — молчит, пока частоты не трогают.
- Для гонки (использовался 19.10): `nouveau.debug=fifo=trace,gr=trace` — ~9 тыс. строк в минуту, держать долго нельзя.
- **Выключить совсем** (вернуть чистые параметры `quiet splash nouveau.hdmimhz=297`):
  ```bash
  sudo cp /etc/default/grub.before-trace /etc/default/grub && sudo update-grub
  ```

## Лаборатория частот (`lab/`)

Только для опытов. `lab/lab.sh install` ставит экспериментальный драйвер: исправление гонки +
разрешение смены частот + подробные строки `LAB ...` в журнале. Стабильный драйвер сохраняется
в `~/nouveau-build/stable-<ядро>-nouveau.ko`. `lab/lab.sh try 07 0f` — опыт со страховкой: после
каждого режима 15 с ждёт Enter («вижу экран»); нет ответа → возврат в 03; снова нет → сам сохраняет
журнал в `results/` и перезагружает компьютер. `lab/lab.sh pstate 07` — переключить без страховки.

Серия опытов «по одному параметру» (каждый — `try 0f 03`, со страховкой):

| Опыт | Команда | Что меняется |
|---|---|---|
| A | `lab/lab.sh exp A` | только напряжение до уровня 0f |
| B | `lab/lab.sh exp B` | напряжение (первым) + память |
| C | `lab/lab.sh exp C` | напряжение (первым) + ядро |
| D | `lab/lab.sh exp D` | всё: PCIe + напряжение + память + ядро |

Порядок этапов в драйвере nouveau: PCIe → память → вентилятор → напряжение ↑ → ядро → напряжение ↓.
Память меняется ДО подъёма напряжения — подозреваемый; переключатель `lab_volt_first` поднимает напряжение первым.
`lab/lab.sh flags` показывает переключатели (`/sys/module/nouveau/parameters/lab_*`). `lab/lab.sh restore` — вернуть стабильный драйвер. После перезагрузки карта всегда
на исходных частотах, сама частота не поднимается.

## Что нужно на компьютере

`git`, `make`, `gcc` и заголовки ядра (`linux-headers-...`). Скрипт сам проверит и скажет, чего не хватает.
Нужен интернет: исходники качаются с GitHub-зеркала стабильных ядер `gregkh/linux` (тег вида `v7.0.14`;
ядро Ubuntu 7.0.0-38 основано на Linux 7.0.14).

## Связанные материалы

- `handoff-2026-10-19-evening-nouveau-fix.md` на рабочем столе — полный разбор, что проверяли и почему.
- Открытые вопросы: отправить исправление разработчикам nouveau; падение ядра при «шторме» закрытий
  (`nouveau_fence_sync`, use-after-free); смена частот карты (`gf100_clk_prog_3` timeout).
