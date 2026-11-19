# Тестировщики и похожие проекты (сбор 18.11.2026)

## Наши (работали с нашими сборками)
| кто | карты | где | состояние |
|---|---|---|---|
| rox4d | GF106 GTS 450 (GDDR5) | issue #1 | 01.11 прислал прогон 4 (nouveau-fix_4.zip) — **мы не ответили**; с тех пор ничего не просили |
| Q0AL | GTX 560 (GF114), GT 730 (GF108), NVS 5200M (GF108M), FX 880M (GT216) | issue #2 | 31.10 два прогона на GTX 560 + GT 730; 01.11 наш ответ; дальше не просили |

| sasim44 | GT 630 (GF108, DDR3, ASUS 1043:8400), Debian 13, ядро 6.12 | issue #3 (19.11) | **пришёл сам**; отчёт VBIOS + запись NVIDIA 390 (всё на верхнем уровне — спусков нет); 20.11 попросили проверку PowerMizer, обещан пакет «только ядро» |

## Люди с Fermi в issues проекта Twilight0 (его код не используем; люди — сами по себе)
| кто | карта | чем интересен |
|---|---|---|
| chrisnoisel | GTX 560 Ti (GF114, ASUS), Arch, ядро 7.2 | **вторая плата нашего чипа**; 04.11 пробовал реклокинг, отчёт с диагностикой |
| MegaRak64 | GTX 550 Ti (GF116, настольная) | GF116 — группы ещё нет ни одной карты |
| Bonjour540 | 410M (GF119M), Sony VAIO, CachyOS | GF119; в июне сам просил в рассылке nouveau довести реклокинг Fermi и предлагал тестировать |
| kriho520m | GT 520M (GF119M), ASUS K53SJ | GF119; собирал на ядре 7.0 |
| yhaenggi | NVS 4200M (GF119M), ThinkPad T520 | GF119 |
| jfouquart | GT 610M (GF119M), ASUS K53SD | GF119; сам правил сборку |
| aruncveli | 820M (GF117M), Dell Inspiron 3542 | **GF117** — единственный известный; реклокинг у него не заработал |
| RowerStudios | GF108 | вопрос про Vulkan |
Не Fermi (на будущее, Kepler по дорожной карте): freemangman — GT 740 (GK107); lukaszsobala — Kepler; Sh4dowzinha — Pascal.

## Похожие проекты
- **IgorChicherin/reclocked** (и форк arcesannemannmartin/reclocked) — Kepler GK107: регулятор уровней в пространстве
  пользователя через debugfs pstate + патчи ядра и Mesa. Наш шаг «Kepler» по дорожной карте; автор — возможный собеседник.
- **ventureoo/nouveau-reclocking** — скрипт ручной смены уровня; Fermi под вопросом. Пользователи — Tesla/Kepler.
- Twilight0/nouveau-fermi-reclock-dkms (бывш. nouveau-dkms) — не берём (декомпиляция драйвера NVIDIA).
- История: Karol Herbst (2016, ядро Fermi на GF108), Roy Spliet (2016–2017, делители и память GF100), Martin Roukala
  (база записей; Acked-by на 0006), W1zzard (TechPowerUp, база VBIOS).

## Покрытие групп чипов для «универсального ядра»
| группа | NVIDIA: ступень 405 / скобка | карты у людей |
|---|---|---|
| GF114 | ступень / скобка | наша, Q0AL (GTX 560), chrisnoisel (GTX 560 Ti) |
| GF106 | нет / скобка | rox4d |
| GF108 | нет / скобка | Q0AL (GT 730, NVS 5200M), RowerStudios |
| GF116 | нет / скобка | MegaRak64 |
| GF119 | нет / обычно нет | Bonjour540, kriho520m, yhaenggi, jfouquart |
| GF117 | нет / нет | aruncveli |
| GF110, GF104, GF100 | GF110: ступень; остальные нет / скобка | никого |
