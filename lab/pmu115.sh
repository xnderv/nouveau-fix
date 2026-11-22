#!/bin/bash
# ОПЫТ 115 (22.11, ночь), модуль build-1122a: потеря ответа прошивки PMU и защита драйвера (опыт 114: в 15:31 поток регулятора
# повис навсегда — прошивка nouveau молча выбрасывает сообщение при полной очереди процесса, а драйвер ждал ответа без предела).
# Теперь запрос итога ждёт ответа не больше lab_perf_wait_ms (1 с); тайм-ауты — в журнале (с состоянием очередей) и в
# lab_perf_timeouts; опоздавший ответ nouveau покажет как «неожиданное» сообщение PERF.
#   0. проверка защиты: lab_perf_drop=3 — три запроса нарочно уходят в несуществующий процесс; ждём 3 тайм-аута, а потом
#      обычные ответы и живой регулятор (без защиты здесь повис бы поток);
#   1. воспроизведение: условия, где по версии совпадение чаще — два уровня (lab_gov_two=1, память на каждом переходе),
#      темп NVIDIA (lab_gov_nv=1), опрос 5 раз в секунду (lab_perf_ms=200); циклы нагрузки 20 с / покоя 20 с;
#   2. для сравнения — обычные ключи, циклы 45/45.
# Стоп на ошибке GPU или вечном застревании переключателя. Ключи в конце — как были.
#   bash ~/Home/nouveau-fix/lab/pmu115.sh [C1=200] [C2=80]   — в терминале рабочего стола; ≈ 2,3 ч + 2 ч
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_perf_drop" ] || { echo "Нет lab_perf_drop — нужен модуль build-1122a"; exit 1; }
C1="${1:-200}"; C2="${2:-80}"
OUT=~/Home/nouveau-fix/results/test115-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
K0="lab_gov_two=$(cat $PRM/lab_gov_two) lab_gov_nv=$(cat $PRM/lab_gov_nv) lab_perf_ms=$(cat $PRM/lab_perf_ms)"
restore() { for kv in $K0; do w "${kv%%=*}" "${kv#*=}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращены"; restore; exit 1' INT TERM
lateq() { sudo journalctl -k -b 0 --no-pager --since "$1" | grep -cE "pmu: PERF [0-9a-f]{8}"; }   # опоздавшие ответы
tmo() { sudo journalctl -k -b 0 --no-pager --since "$1" | grep -c "PMU не ответил"; }
say "опыт 115: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s); ключи сейчас: $K0; ожидание ответа $(cat $PRM/lab_perf_wait_ms) мс"

say "--- 0. проверка защиты: три запроса нарочно теряются"
T="$(date "+%F %T")"; n0="$(cat $PRM/lab_perf_samples)"; t0="$(cat $PRM/lab_perf_timeouts)"
w lab_perf_drop 3; sleep 12
say "    тайм-аутов: $(( $(cat $PRM/lab_perf_timeouts) - t0 )) (ждали 3); замеров после: было $n0, сейчас $(cat $PRM/lab_perf_samples); опоздавших ответов $(lateq "$T")"
sudo journalctl -k -b 0 --no-pager --since "$T" | grep -E "PMU не ответил|pmu: PERF" | sed -E 's/^.*pmu: //' | tee -a "$OUT"
[ "$(( $(cat $PRM/lab_perf_timeouts) - t0 ))" -ge 3 ] || { say "    защита не сработала как ждали — стоп"; restore; exit 1; }

part() {   # $1 имя, $2 циклы, $3 нагрузка, $4 покой, дальше ключи
  local name="$1" c="$2" l="$3" i="$4" t f; shift 4; t="$(date "+%F %T")"
  for kv in "$@"; do w "${kv%%=*}" "${kv#*=}"; done
  say "--- $name: $*; циклов $c ($l/$i с)"
  bash "$HERE/gov94.sh" "$c" "$l" "$i" > /dev/null 2>&1
  f="$(ls -t ~/Home/nouveau-fix/results/test94-*.txt | head -n 1)"
  say "    файл $(basename "$f"): $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //')"
  say "    переходы: $(sudo journalctl -k -b 0 --no-pager --since "$t" | grep -oE 'LAB gov: -> [0-9a-f]{2}' | sort | uniq -c | tr '\n' ' ')"
  say "    тайм-аутов ответа PMU: $(tmo "$t"); опоздавших ответов: $(lateq "$t"); всего с загрузки: $(cat $PRM/lab_perf_timeouts)"
  sudo journalctl -k -b 0 --no-pager --since "$t" | grep -E "PMU не ответил|pmu: PERF" | sed -E 's/^.{7}(.{8}).*pmu: /\1 /' | head -n 20 | tee -a "$OUT"
  grep -qE '=== итог: .*вечных 0, ошибок GPU 0' "$f" || { say "    ошибка GPU или вечное застревание — стоп"; return 1; }
}
part "1. воспроизведение: два уровня + темп NVIDIA + опрос 200 мс" "$C1" 20 20 lab_gov_two=1 lab_gov_nv=1 lab_perf_ms=200 &&
part "2. обычные ключи" "$C2" 45 45 lab_gov_two=0 lab_gov_nv=0 lab_perf_ms=1000
restore; trap - INT TERM
say "=== конец; ключи возвращены: $K0"
grep -E "опыт 115|^.{8} ---|тайм-аут|переходы|файл|стоп|=== конец" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"
