# Second reply in Twilight0/nouveau-dkms issue #9 (to rox4d) — posted 27.10.2026 14:00 MSK as xnderv: https://github.com/Twilight0/nouveau-dkms/issues/9#issuecomment-6440230311

Place: a comment in https://github.com/Twilight0/nouveau-dkms/issues/9 (public). Only our own experience. Mentions the
script fix — post only after the commits are pushed to github.com/xnderv/nouveau-fix.

---

Thanks, good to hear it worked.

The "Device or resource busy" at the end comes from our script, not from your trace: on newer kernels the tracer can't
be switched to `nop` while `trace_pipe` is still open, and the script did the stop in the wrong order. Your
`mmiotrace.txt` is complete — the message appears after the "конец записи" (end of recording) mark. It's fixed in the
repo now: the script first sets `tracing_on` to 0, lets the reader finish, stops it, and only then switches the tracer
to `nop`.

About a GF106 trace: yes, it would be useful for us. We're building a model of how the NVIDIA driver changes clocks on
Fermi (GF114 here). GF106 is one of the two chips NVIDIA named in the 270.41.06 changelog ("some GPUs stop responding
when the X Server was started… primarily seen on GF104 and GF106"). A second Fermi chip recorded with the same scenario
would show which parts of the clock-change order are common to Fermi and which are specific to our card. If you do it:
the same script as is (control pass, then the recorded pass, light load only), and please keep `steps.txt` and
`nvsettings.txt` next to the trace — they give the timing of each phase. We'd treat it as your observation and credit
you. Publishing the raw trace is your call (it also contains reads of your card's VBIOS); a private link is fine too.

---

## Перевод для тебя (не отправлять)

Спасибо, рад, что заработало.

«Устройство или ресурс занято» в конце — от нашего сценария, а не от твоей записи: на новых ядрах трассировщик нельзя
переключить на `nop`, пока `trace_pipe` ещё открыт, а сценарий останавливал запись в неправильном порядке. Твой
`mmiotrace.txt` полный — сообщение появляется уже после метки «конец записи». В репозитории это исправлено: сценарий
сначала ставит `tracing_on` в 0, даёт программе чтения дописать, останавливает её и только потом переключает
трассировщик на `nop`.

Про запись GF106: да, нам это пригодится. Мы строим модель того, как драйвер NVIDIA меняет частоты на Fermi (у нас
GF114). GF106 — один из двух чипов, которые NVIDIA назвала в журнале изменений 270.41.06 («некоторые GPU перестают
отвечать при запуске X… чаще всего на GF104 и GF106»). Второй чип Fermi, записанный тем же сценарием, покажет, какие
части порядка смены частот общие для Fermi, а какие — особенность нашей карты. Если будешь делать: тот же сценарий как
есть (контрольный проход, потом проход под записью, только лёгкая нагрузка), и сохрани рядом с записью `steps.txt` и
`nvsettings.txt` — в них время каждой фазы. Мы будем считать это твоим наблюдением и укажем авторство. Публиковать сырую
запись или нет — решай сам (в ней есть и чтения VBIOS твоей карты); можно и закрытой ссылкой.
