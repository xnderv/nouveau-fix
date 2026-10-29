# Отправка в upstream

## 0001 — гонка при удалении объекта движка (abi16)
Файл `0001-drm-nouveau-idle-channel-before-engobj-dtor.patch` — письмо в формате `git send-email`/`git am`:
заголовок, описание, `Signed-off-by`, diff с путями от корня ядра (без отладочной `pr_info`).
Проверено 22.10.2026: в главной ветке Linux ошибка на месте (`nouveau_abi16_ioctl_del` не ждёт канал).

Как отправить (из любого каталога с клоном ядра не обязательно):
1. Проверить, что патч накладывается на свежий nouveau: `git clone --depth 1 https://github.com/torvalds/linux` →
   `git apply --check docs/upstream/0001-*.patch`.
2. Получить адреса сопровождающих: `./scripts/get_maintainer.pl docs/upstream/0001-*.patch`
   (ожидаемо: Lyude Paul, Danilo Krummrich, dri-devel@lists.freedesktop.org, nouveau@lists.freedesktop.org).
3. Отправить: `git send-email --to=<сопровождающие> --cc=dri-devel@lists.freedesktop.org --cc=nouveau@lists.freedesktop.org docs/upstream/0001-*.patch`
   или вставить файл целиком в письмо текстом (без HTML) из почтового клиента.
4. В теле письма ничего менять не нужно; если попросят — отчёт о воспроизведении лежит в `results/crash/` и `docs/`.

**Отправлено 23.10.2026 17:42 (MSK)** через `git send-email` (smtp.yandex.ru), ответ сервера 250.
Message-ID: `<20261023144219.46478-1-xnderv@yandex.com>`.
Кому: Lyude Paul, Danilo Krummrich; копии: Karol Herbst, nouveau@, dri-devel@, linux-kernel@.
Архив: https://lore.kernel.org/dri-devel/20261023144219.46478-1-xnderv@yandex.com/
Дальше: следить за ответами в этой ветке (придут на xnderv@yandex.com); при замечаниях — v2 тем же способом с `--in-reply-to=<Message-ID>`.

**Отклик 23.10.2026 ~18:10:** автоматический рецензент Sashiko AI (не сопровождающий) указал на гонку
с планировщиком при VM_BIND: EXEC-задания пишут в канал из рабочей очереди без cli->mutex, а
nouveau_channel_idle() из ioctl_del эмитит ограждение в тот же канал. Замечание верное.
**v2** — `v2-0001-drm-nouveau-idle-channel-before-engobj-dtor.patch`: перед idle ждём опустошения
очереди заданий планировщика (nouveau_sched_wait_idle, вынесено из nouveau_sched_fini). Проверено:
накладывается на master, компилируется в дереве 7.0.0-38. Черновик ответа и команда отправки —
`reply-sashiko-v1.md`. Локальный `patches/0001-*.patch` обновлён до v2 (стабильный DKMS и
лабораторный драйвер пересобрать при следующем удобном случае).

**Отправлено 23.10.2026 18:23 (MSK)**, оба письма в ответ на v1 (In-Reply-To первому Message-ID):
ответ рецензенту — Message-ID `<20261023152332.9420-1-xnderv@yandex.com>`; следом v2 патча.

## 0003 — HDMI без SCDC
Не отправлять: исправлено upstream коммитом `1717fcc5be57` (2026-09-17). Наш вариант остаётся для ядер 7.0.x.

## 0010 — смена частот GF114
В upstream в таком виде не пойдёт (привязка к одной плате, скрипты из записи NVIDIA). Путь в upstream —
через обсуждение с разработчиками nouveau (список nouveau@lists.freedesktop.org, IRC #nouveau): показать
запись и различия (`docs/2026-10-22/review-driver.md`), спросить, как они видят общий механизм для Fermi.

## 0006 — вентилятор: бит 31 при чтении скважности ШИМ (подготовлено и отправлено 25.10.2026)
Файл `0006-drm-nouveau-therm-mask-pwm-update-bit.patch` — письмо для `git send-email`, сделано `git format-patch` на ветке
torvalds/linux от 24.10.2026 (21a7f44). Проверено:
- ошибка в свежем ядре на месте; therm-код (nv50.c, gf119.c, fan.c, fanpwm.c, base.c, gt215.c) совпадает с 7.0;
- правка собирается без предупреждений (дерево 7.0.14, те же файлы); на карте — 0 ложных чтений из 155 (fantrace-123706);
- `checkpatch.pl --strict`: только «Missing Signed-off-by» (ставит автор сам) и «Unknown commit id» для обоих Fixes —
  из-за неполного клона; оба коммита проверены через GitHub: cb9fa62671ac «drm/nv50/pm: add support for pwm fan control»,
  bc79202f4c8f «nvd0/therm: implement more appropriate pwm fan control functions»;
- адресаты (`get_maintainer.pl`): Lyude Paul, Danilo Krummrich, dri-devel@, nouveau@ (+ drm-misc сопровождающие — как и
  для 0001, не ставим);
- правила ядра для ИИ-ассистентов (Documentation/process/coding-assistants.rst, generated-content.rst): ассистент НЕ ставит
  Signed-off-by; в описании сказано, что сделал ассистент и как проверено, чего не проверено (gf119 на железе).
Отправка (после прочтения и добавления своей строки `Signed-off-by: Alex <xnderv@yandex.com>` после `Cc: stable@…`):
```
cd ~/Home/nouveau-fix && git send-email --to='Lyude Paul <lyude@redhat.com>' --to='Danilo Krummrich <dakr@kernel.org>' \
  --cc=dri-devel@lists.freedesktop.org --cc=nouveau@lists.freedesktop.org --cc=linux-kernel@vger.kernel.org \
  docs/upstream/0006-drm-nouveau-therm-mask-pwm-update-bit.patch
```
(`Cc: stable@vger.kernel.org` из текста git send-email добавит в копию сам.)

**Отправлено 25.10.2026 13:16 (MSK)** через `git send-email`, Message-ID `<20261025101640.49779-1-xnderv@yandex.com>`.
Кому: Lyude Paul, Danilo Krummrich; копии: dri-devel@, nouveau@, linux-kernel@, stable@, автор.
**Ушло без строки `Signed-off-by` автора** (не была добавлена перед отправкой). Если попросят — ответ в ту же ветку
со строкой подписи или v2 с подписью.
**Подпись отправлена 25.10.2026 13:24 (MSK)** ответом в ту же ветку (`reply-0006-signoff.sh`, строку подписи напечатал
автор): Message-ID `<20261025102413.51786-1-xnderv@yandex.com>`, In-Reply-To — письмо патча. Ждём ответа.

**29.10 — ответы Martin Roukala (бывший Martin Peres, автор therm/fan в nouveau):**
- на 0006 (07:03, Message-ID <1c76eb81-feac-419c-bcb8-bb505788e549@mupuf.org>): «Acked-by: Martin Roukala <martin.roukala@mupuf.org>»;
  просит сократить описание коммита до первого абзаца, остальное — в письмо под ---. Подготовлен v2:
  `v2-0006-drm-nouveau-therm-mask-pwm-update-bit.patch` (+ одна строка про ИИ-ассистента в описании — generated-content.rst),
  отправка `send-0006-v2.sh` (подпись печатает автор).
- на RFC (07:24, <8abb7b92-c16a-47a9-8caf-49773845c246@free.fr>): FSRM вокруг реклокинга у NVIDIA не видел (занимался Tesla и
  раньше); есть закрытая база VBIOS + mmiotrace, может дать доступ; исторический контекст — почта martin.roukala@mupuf.org
  или IRC #nouveau (OFTC, mupuf). **Пользователь ответил сам 29.10 08:40 (MSK)**, лично Мартину, Message-ID
  <608521793252115@mail.yandex.ru>: рад, будет очень благодарен за доступ к базе. Черновик
  `nouveau-ml-reply-martin-2026-10-29.eml` устарел и не отправляется. Когда Мартин даст доступ — уточнить условия
  (что можно публиковать из выводов; сырые данные держим у себя).
- **v2 0006 отправлен 29.10.2026 16:00 (MSK)** через `send-0006-v2.sh` (подпись напечатал автор), Message-ID
  `<20261029130012.21738-1-xnderv@yandex.com>`, результат 250. Кому: Lyude Paul, Danilo Krummrich; копии: Martin Roukala,
  dri-devel@, nouveau@, linux-kernel@, stable@, автор. Новая ветка (не ответом в v1); ссылка на v1 — под чертой.
