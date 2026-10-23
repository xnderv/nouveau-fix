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

## 0003 — HDMI без SCDC
Не отправлять: исправлено upstream коммитом `1717fcc5be57` (2026-09-17). Наш вариант остаётся для ядер 7.0.x.

## 0010 — смена частот GF114
В upstream в таком виде не пойдёт (привязка к одной плате, скрипты из записи NVIDIA). Путь в upstream —
через обсуждение с разработчиками nouveau (список nouveau@lists.freedesktop.org, IRC #nouveau): показать
запись и различия (`docs/2026-10-22/review-driver.md`), спросить, как они видят общий механизм для Fermi.
