# Draft v2: message to Twilight0 (26.10.2026; replaces the 22–23.10 draft, not sent)

Suggested place: a new issue in `Twilight0/nouveau-dkms`, or e-mail if he prefers.
Suggested title: **GF114 / GDDR5 reclocking results, and a proposal to exchange hardware observations**

---

Hi,

I own a desktop GeForce GTX 560 Ti (GF114, Gigabyte GV-N560OC-1GI, 1 GB GDDR5, PCI subsystem 1458:3515). Over the
last week I worked on Fermi reclocking in nouveau. Your project, and the idea of recording the NVIDIA 390 driver with
mmiotrace and reading its PMU memory scripts, is where we started, thank you for that.

What we have now, all from our own mmiotrace recordings of NVIDIA 390 on this board and from tests on the hardware:
- GDDR5 memory reclock 135 / 324 / 2004 MHz through nouveau's **stock memx**, replaying NVIDIA's own scripts for this
  board (your issue #4 asked about GDDR5);
- four separate causes of hangs and stalls in nouveau's Fermi clock code:
  1. VBIOS clocks are whole MHz (101 for 101.25). nouveau's gf100 "closest at any cost" choice put the shader clock on
     a PLL at the lowest level and the PMU at 216 instead of 202.5 MHz. The gt215 window rule gives NVIDIA's choice on
     every unit.
  2. GPC and hubk06 clock changes need the PTHERM FSRM slowdown bracket. Without it the graphics engine hangs under
     load, 7 runs out of 7.
  3. In some boots the GPC clock mux sticks for 60–330 ms when leaving its PLL for the divider. Writing the core
     divider with a new value right before the mux write, as NVIDIA does, cured it: 0 timeouts in 2700 load cycles
     against 27 in 2279 without it, in the same boot.
  4. nouveau continues a transition after a mux timeout: it switches off the PLL and lowers the voltage while the unit
     is still on that PLL.
- NVIDIA's ordering rules and governor shape as seen in the recordings.

We are now writing this up as a model of how the NVIDIA driver manages the card, with per-register coverage:
https://github.com/xnderv/nouveau-fix (`docs/model/`; the model itself is in Russian for now, the README is in
English).

One thing I want to be upfront about. Our project follows a strict provenance rule: we don't use conclusions derived
from decompiling or disassembling NVIDIA's driver, including from third-party notes. Your README says part of your
findings come from Ghidra decompilation, so we no longer read your reverse-engineering notes. We also removed from our
code the one item we had taken from them, an interpretation of memory-script op 0x3a; our own test had shown that it
was not needed. Nothing personal: we want our results to stay usable by anyone, upstream included, without questions
about their origin.

So here is a proposal: let's exchange **observations**, not code or RE notes. If you are willing, these would help
our model a lot, and we would credit you:
- an mmiotrace recording of the NVIDIA 390 driver switching performance levels on your GT 555M (GF106M, DDR3), even a
  short one;
- your board's VBIOS tables (perf, PLL limits, memory), or simply the output of our read-only `tools/card-report.sh`;
- register snapshots of the clock block at each level, if you have them.

In return you get our findings and hypotheses, and I'm happy to answer questions about the GF114 / GDDR5 side. If
some of your users would like to check the model on their cards, `card-report.sh` only reads, and we would point them
to it only with your OK.

Thanks,
Alex

---

## Перевод для тебя (не отправлять)

Привет.

У меня настольная GTX 560 Ti (GF114, Gigabyte GV-N560OC-1GI, 1 ГБ GDDR5, подсистема 1458:3515). Последнюю неделю я
занимался сменой частот Fermi в nouveau. Начинали мы с твоего проекта и с идеи записать драйвер NVIDIA 390 через
mmiotrace и прочитать его скрипты памяти PMU — спасибо за это.

Что у нас сейчас — всё из наших собственных записей драйвера NVIDIA на этой плате и опытов на железе:
- смена частоты GDDR5 135 / 324 / 2004 МГц через **штатный memx** nouveau, скриптами самой NVIDIA для этой платы (в
  твоём issue #4 спрашивали про GDDR5);
- четыре отдельные причины зависаний и сбоев в коде частот Fermi у nouveau:
  1. Частоты в VBIOS — целые МГц (101 вместо 101,25). Выбор gf100 «ближе любой ценой» ставил шейдерный такт на PLL на
     нижнем уровне, а PMU — на 216 МГц вместо 202,5. Правило окна из gt215 даёт выбор NVIDIA на всех узлах.
  2. Смене такта GPC и hubk06 нужна скобка замедлителя PTHERM FSRM. Без неё графический движок под нагрузкой
     зависает, 7 прогонов из 7.
  3. В части загрузок переключатель GPC застревает на 60–330 мс при уходе с PLL на делитель. Запись делителя ядра с
     новым значением прямо перед переключателем, как у NVIDIA, вылечила это: 0 тайм-аутов на 2700 циклов против 27 на
     2279 без неё, в той же загрузке.
  4. nouveau продолжает переход после тайм-аута переключателя: выключает PLL и снижает напряжение, хотя узел ещё на
     этом PLL.
- порядок шагов NVIDIA и форма её регулятора по записям.

Сейчас мы оформляем это как модель того, как драйвер NVIDIA управляет картой, с покрытием по каждому регистру:
ссылка на репозиторий (`docs/model/`; сама модель пока на русском, README — на английском).

Одно хочу сказать прямо. В нашем проекте строгое правило происхождения знаний: выводы из декомпиляции или
дизассемблирования драйвера NVIDIA не используем, в том числе из чужих заметок. В твоём README сказано, что часть
находок получена декомпиляцией в Ghidra, поэтому твои заметки по разбору мы больше не читаем. Единственное, что мы из
них взяли, — толкование операции 0x3a в скриптах памяти, — мы из кода убрали; наш собственный опыт показал, что она не
нужна. Ничего личного: мы хотим, чтобы наши результаты мог взять кто угодно, в том числе основное ядро, без вопросов о
происхождении.

Поэтому предложение: давай обмениваться **наблюдениями**, а не кодом и не заметками по разбору. Если ты согласен, нам
бы очень помогло — с указанием твоего авторства:
- запись mmiotrace драйвера NVIDIA 390, который переключает уровни на твоей GT 555M (GF106M, DDR3), хотя бы короткая;
- таблицы VBIOS твоей платы (уровни, пределы PLL, память) или просто вывод нашего `tools/card-report.sh`, который
  только читает;
- снимки регистров тактов на каждом уровне, если они у тебя есть.

Взамен — наши находки и гипотезы, и я с радостью отвечу на вопросы про GF114 и GDDR5. Если кто-то из твоих
пользователей захочет сверить модель со своей картой, `card-report.sh` только читает, и мы направим их к нему только с
твоего согласия.

Спасибо,
Алекс
