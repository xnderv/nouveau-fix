#!/bin/bash
# НОЧНАЯ ЦЕПОЧКА на стенде 10.04 (27.10): два прогона циклов «максимум 2 с — адаптивный 18 с» друг за другом без человека:
#   1) mux  A — под записью (прогрев, затем A минут циклов, запись останавливается и сохраняется);
#   2) muxc B — без записи, B минут (настоящая скорость обращений к регистрам);
#   3) выключение машины (утром включить — без F12 грузится основная система; там lucid-disk.sh get).
# Порядок именно такой: запись проверена для второй загрузки драйвера за сессию (прогрев, затем запись); muxc идёт третьей
# загрузкой — так ещё не делали, но его данные (журналы, уровни) меньше, а запись к тому моменту уже на диске.
# Сторож внутри каждого прогона при Xid / остановке сам сохраняет журналы и выключает машину — цепочка на этом кончается.
# Проверка последовательности коротко: night 2 2 nooff  (~8 минут, без выключения).
# Запуск в 10.04: night 180 180   (или sudo ~/trace/stand-night-lucid.sh 180 180)
set -u
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
A="${1:-180}"; B="${2:-180}"; OFF="${3:-off}"
LOG="$HERE/night-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }
show() { echo ">>> $*"; }
unload() {   # выгрузить драйвер с повторами (как между проходами в run-trace-lucid.sh)
  local i
  for i in 1 2 3 4 5; do
    lsmod | grep -q '^nvidia ' || return 0
    modprobe -r nvidia 2>>"$LOG" && return 0
    sleep 3
  done
  return 1
}
say "ночная цепочка: mux $A мин -> muxc $B мин -> $([ "$OFF" = nooff ] && echo 'без выключения' || echo 'выключение')"
show "NIGHT CHAIN: mux $A min, then muxc $B min, then $([ "$OFF" = nooff ] && echo 'stop' || echo 'POWER OFF'). Do not touch."

say "=== 1/2 mux $A (под записью)"
"$HERE/run-trace-lucid.sh" mux "$A"; rc=$?
say "mux завершился с кодом $rc; результат: $(ls -td "$HERE"/out-* 2>/dev/null | head -n 1)"
if [ $rc -ne 0 ]; then
  say "СТОП: mux не прошёл — muxc не запускаю"; show "STOP: mux failed (code $rc), muxc skipped"
  [ "$OFF" = nooff ] || { sleep 5; poweroff; }
  exit 1
fi
sleep 5
if ! unload; then
  say "СТОП: драйвер nvidia не выгрузился после mux — muxc не запускаю"; show "STOP: driver did not unload after mux, muxc skipped"
  [ "$OFF" = nooff ] || { sleep 5; poweroff; }
  exit 1
fi
say "драйвер выгружен"

say "=== 2/2 muxc $B (без записи)"
STAND_CHAIN=1 "$HERE/run-trace-lucid.sh" muxc "$B"; rc=$?
say "muxc завершился с кодом $rc; результат: $(ls -td "$HERE"/out-* 2>/dev/null | head -n 1)"
unload || true
say "ГОТОВО: цепочка завершена"
show "NIGHT CHAIN DONE."
if [ "$OFF" = nooff ]; then show "Not powering off (nooff)."; exit 0; fi
show "Powering off in 20 s. In the morning: power on (no F12), then lucid-disk.sh get."
sleep 20; sync; poweroff
