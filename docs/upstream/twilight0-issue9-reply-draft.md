# Draft: reply to Twilight0/nouveau-dkms issue #9 (mmiotrace with the NVIDIA 390 driver) — not sent

Place: a comment in https://github.com/Twilight0/nouveau-dkms/issues/9 (public). Only our own experience, no code or notes
from that project.

---

Hi, not the author here, but we recorded the NVIDIA 390.157 driver with mmiotrace on a GTX 560 Ti last week, so maybe
this helps.

In your raw file there is only one late `MAP` (0xe82e0000, 128 KiB) and no mapping of the GPU's register BAR (BAR0,
0xf6000000 in your `PCIDEV` line). The usual reason is that `nvidia.ko` was already loaded before the tracer was
enabled. mmiotrace only sees `ioremap` calls made *after* it is switched on, so a driver loaded at boot has already
mapped BAR0 and you get almost nothing. What worked for us:

1. Don't let `nvidia` load at boot (blacklist it, or boot to a text console), and make sure `lsmod | grep nvidia` is
   empty.
2. `echo mmiotrace > /sys/kernel/tracing/current_tracer` (all CPUs but one go offline — that's expected), then start
   `cat /sys/kernel/tracing/trace_pipe > /some/fast/disk/trace.txt` in the background.
3. Only now `modprobe nvidia` and start X with a *light* load (a small glxgears window). Heavy 3D floods the trace and
   can stall a single-CPU system.
4. Stop: `echo nop > current_tracer`, then stop the `cat`.

Our setup was a separate Ubuntu 22.04 install with its stock 5.15 kernel and the packaged 390 driver, so no extra
patches for newer kernels. If it still fails on 6.18 after step 1, trying an older kernel is the next thing I'd do.
Our scripts for this are in https://github.com/xnderv/nouveau-fix (`trace/run-trace.sh`, comments are in Russian).

---

## Перевод для тебя (не отправлять)

Привет. Я не автор проекта, но мы на прошлой неделе записывали драйвер NVIDIA 390.157 через mmiotrace на GTX 560 Ti —
может, пригодится.

В твоём файле есть только одно позднее отображение памяти (`MAP` 0xe82e0000, 128 КиБ) и нет отображения окна регистров
карты (BAR0, 0xf6000000 в строке `PCIDEV`). Обычная причина: `nvidia.ko` уже был загружен до включения трассировщика.
mmiotrace видит только те `ioremap`, что сделаны *после* его включения. Драйвер, загруженный при старте системы, уже
отобразил BAR0, и в запись почти ничего не попадает. Что сработало у нас:

1. Не давать `nvidia` загрузиться при старте (чёрный список или текстовая консоль) и убедиться, что
   `lsmod | grep nvidia` пуст.
2. `echo mmiotrace > /sys/kernel/tracing/current_tracer` — все ядра процессора, кроме одного, выключатся, так и должно
   быть. Затем в фоне запустить `cat /sys/kernel/tracing/trace_pipe > /быстрый/диск/trace.txt`.
3. Только теперь `modprobe nvidia` и запуск X с *лёгкой* нагрузкой (маленькое окно glxgears). Тяжёлое 3D заваливает
   запись, и система на одном ядре может встать.
4. Остановка: `echo nop > current_tracer`, потом остановить `cat`.

У нас была отдельная Ubuntu 22.04 со своим ядром 5.15 и драйвером 390 из репозитория — без патчей для новых ядер. Если
на 6.18 не заработает и после шага 1, следующее, что я бы попробовал, — более старое ядро. Наши скрипты — в
репозитории, `trace/run-trace.sh` (комментарии на русском).
