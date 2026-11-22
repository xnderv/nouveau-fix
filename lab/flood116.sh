#!/bin/bash
# ОПЫТ 116 (22.11), модуль build-1122b (ключ lab_perf_flood). Проверка версии опыта 114: прошивка PMU nouveau молча выбрасывает
# сообщение, если очередь процесса полна (у процесса 4 места; процесс HOST забирает очередь драйвера — 8 мест — целиком),
# а драйвер ждёт ответа без предела и виснет навсегда. Переполнение вызывается нарочно: перед запросом итога драйвер шлёт PERF
# ещё N=6 безвредных сообщений «начать замеры» подряд.
#   часть 1 — С ЗАЩИТОЙ (ожидание 1000 мс): 5 переполнений; ждём 5 тайм-аутов с прежней картиной очередей и живой регулятор;
#   часть 2 — БЕЗ ЗАЩИТЫ (lab_perf_wait_ms=0, как nouveau): одно переполнение; если версия верна, поток регулятора повиснет
#             навсегда. Ждём сообщения ядра «task blocked» (2–4 мин) и читаем регистры PMU (только чтение).
#             ПОСЛЕ ЧАСТИ 2 МАШИНУ НУЖНО ПЕРЕЗАГРУЗИТЬ (повисший поток не отпускается).
#   bash ~/Home/nouveau-fix/lab/flood116.sh [1|2|все]   — по умолчанию все; около 5 минут
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_perf_flood" ] || { echo "Нет lab_perf_flood — нужен модуль build-1122b"; exit 1; }
WHAT="${1:-все}"
OUT=~/Home/nouveau-fix/results/test116-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
W0="$(cat $PRM/lab_perf_wait_ms)"
say "опыт 116: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s); ожидание ответа $W0 мс"

if [ "$WHAT" = 1 ] || [ "$WHAT" = все ]; then
  say "--- часть 1: с защитой, 5 переполнений по 6 сообщений"
  T="$(date "+%F %T")"; t0="$(cat $PRM/lab_perf_timeouts)"
  w lab_perf_wait_ms 1000
  for k in 1 2 3 4 5; do w lab_perf_flood 6; sleep 4; say "    переполнение $k: тайм-аутов с начала части $(( $(cat $PRM/lab_perf_timeouts) - t0 )), замеров в последнем ответе $(cat $PRM/lab_perf_samples)"; done
  sudo journalctl -k -b 0 --no-pager --since "$T" | grep -E "опыт 116|PMU не ответил|pmu: PERF|LAB gov: ->" | sed -E 's/^.{7}(.{8}).*(pmu: )/\1 /' | tee -a "$OUT"
  sleep 3; say "    регулятор после: замеры идут? $(cat $PRM/lab_perf_samples) -> $(sleep 3; cat $PRM/lab_perf_samples)"
fi

if [ "$WHAT" = 2 ] || [ "$WHAT" = все ]; then
  say "--- часть 2: БЕЗ защиты (ожидание без предела, как nouveau), одно переполнение"
  T="$(date "+%F %T")"
  w lab_perf_wait_ms 0; w lab_perf_flood 6; sleep 5
  s1="$(cat $PRM/lab_perf_samples)"; sleep 5; s2="$(cat $PRM/lab_perf_samples)"
  say "    замеры после переполнения: $s1 -> $s2 (одинаковые = ответов больше нет); жду сообщения ядра о зависшей задаче (до 4 мин)"
  for s in $(seq 1 48); do sudo journalctl -k -b 0 --no-pager --since "$T" | grep -q "blocked for more than" && break; sleep 5; done
  sudo journalctl -k -b 0 --no-pager --since "$T" | grep -E "опыт 116|blocked for more than|Workqueue|lab_perf_work|gt215_pmu_send" | sed -E 's/^.{7}(.{8}) [^ ]+ kernel: /\1 /' | head -n 8 | tee -a "$OUT"
  say "    регистры PMU (только чтение):"
  sudo python3 -I "$HERE/pmu-peek.py" | tee -a "$OUT"
  say "    ВНИМАНИЕ: поток регулятора повис — перезагрузите машину (sudo reboot)"
fi
say "=== конец"
cp "$OUT" "$OUT.sum"; echo "Результат: $OUT"
