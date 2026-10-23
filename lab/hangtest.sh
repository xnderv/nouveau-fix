#!/bin/bash
# ТЕСТ ВОСПРОИЗВЕДЕНИЯ зависания 23.10 (два случая: сразу после подъёма 07 -> 0f под нагрузкой браузера
# графический блок GR встаёт «занят» на 100 % и не отпускает; ядро и шина живы, экран замирает).
# Идея: не ждать случайности, а повторять ровно этот переход под похожей нагрузкой, пока не повторится.
#   bash ~/Home/nouveau-fix/lab/hangtest.sh [N]        — N подъёмов 07 -> 0f -> 07 под нагрузкой (по умолчанию 60)
#   LOAD=none bash .../hangtest.sh [N]                 — то же без нагрузки (контроль: должно не зависать)
#   LOAD=glmark2 bash .../hangtest.sh [N]              — нагрузка glmark2 вместо браузера (если установлен)
#   HOLD=СЕК                                           — сколько держать 0f после подъёма (по умолчанию 6)
# Нагрузка по умолчанию: Яндекс.Браузер с локальной страницей lab/hangload.html (WebGL с загрузкой текстур
# каждый кадр, 2D-канвас, CSS-анимации, непрерывное выделение текста — как в момент зависаний).
# Регулятор драйвера на время теста выключается (lab_gov=0), переключения делаются вручную через debugfs,
# в конце lab_gov возвращается. Признак зависания: lab_perf_gr >= 999‰ четыре секунды подряд или строки
# «failed to idle channel» / SCHED_ERROR / runl / timeout в журнале ядра. При зависании тест останавливается,
# нагрузка НЕ убивается (чёрному ящику нужно состояние «как есть» для снимка hang-*.txt), экран, скорее
# всего, уже замер: Alt+PrtSc, затем S, U, B. Лог теста пишется с sync после каждой строки.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; PRM=/sys/module/nouveau/parameters
N="${1:-60}"; [[ "$N" =~ ^[0-9]+$ ]] || { echo "Число подъёмов"; exit 1; }
LOAD="${LOAD:-browser}"; HOLD="${HOLD:-6}"
[ -e "$PRM/lab_gov" ] || { echo "Нужен лабораторный драйвер (нет $PRM/lab_gov)"; exit 1; }
systemctl is-active -q gpu-blackbox || echo "⚠ чёрный ящик не запущен (lab/blackbox.sh install) — снимка регистров при зависании не будет"
mkdir -p "$KIT/results"; LOG="$KIT/results/hangtest-$(date +%Y%m%d-%H%M%S).txt"
PSF="$(ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n1)"
sudo -v || exit 1
[ -n "$PSF" ] || PSF="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
ac()     { sudo sh -c "grep '^AC' '$PSF'" | sed 's/^AC: //'; }
pstate() { sudo sh -c "echo $1 > '$PSF'"; }
gr()     { cat "$PRM/lab_perf_gr" 2>/dev/null || echo 0; }
errs()   { journalctl -k -b 0 --no-pager --since "$T0" 2>/dev/null | grep -cE 'failed to idle|SCHED_ERROR|runl|nouveau.*timeout|fifo:.*INTR' || true; }
bdur()   { journalctl -k -b 0 --no-pager --since "$T0" 2>/dev/null | grep -oE 'replay B 324->2004: выполнен за [0-9]+ мкс' | tail -n1 | grep -oE '[0-9]+ мкс'; }
GOV0="$(cat "$PRM/lab_gov")"; LP=""; HUNG=0
finish() {
    if [ "$HUNG" = 0 ]; then
        [ -n "$LP" ] && { kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null; }
        pstate 07 2>/dev/null; sudo sh -c "echo $GOV0 > $PRM/lab_gov" 2>/dev/null
        echo "$(date +%T) регулятор возвращён (lab_gov=$GOV0), режим: $(ac)" | tee -a "$LOG"
    fi
    sync
}
trap finish EXIT
T0="$(date '+%Y-%m-%d %H:%M:%S')"
{ echo "hangtest $T0: подъёмов $N, нагрузка $LOAD, удержание 0f ${HOLD}с, lab_gov был $GOV0, ядро $(uname -r)"
  echo "параметры: $(for p in lab_mem_order lab_mem_op13 lab_mem_op34 lab_mem_op3a lab_mem_replay lab_pcie lab_gpc_seq; do printf '%s=%s ' $p "$(cat $PRM/$p)"; done)"
} | tee "$LOG"; sync
sudo sh -c "echo 0 > $PRM/lab_gov"
# Память при lab_mem=0 стоит на одном значении весь тест. По умолчанию MEMHOLD=324 (база теста 1). MEMHOLD=2004 — поднять память на 2004 с
# включённым lab_mem, затем выключить lab_mem: дальше ходит только ядро, память как в реальной работе на 0f (опция на потом).
# MEMHOLD=324 — держать 324. При 135 МГц GR голодает и показывает 1000‰ без зависания — так не тестируем.
MEM0="$(cat $PRM/lab_mem)"; MEMHOLD="${MEMHOLD:-324}"
if [ "$MEM0" = N ] || [ "$MEM0" = 0 ]; then
    case "$MEMHOLD" in 2004) LV=0f;; 324) LV=07;; *) echo "MEMHOLD=2004|324"; exit 1;; esac
    case "$(ac)" in *"memory $MEMHOLD MHz"*) ;; *) sudo sh -c "echo 1 > $PRM/lab_mem"; pstate $LV; sleep 3; sudo sh -c "echo 0 > $PRM/lab_mem";; esac
    pstate 07; sleep 3
    case "$(ac)" in *"memory $MEMHOLD MHz"*) ;; *) echo "СТОП: не удалось поставить память $MEMHOLD МГц: $(ac)" | tee -a "$LOG"; exit 1;; esac
else
    pstate 07; sleep 3
fi
echo "$(date +%T) старт: $(ac); lab_mem=$MEM0 lab_core=$(cat $PRM/lab_core) lab_volt_min_uv=$(cat $PRM/lab_volt_min_uv) lab_gr_pause=$(cat $PRM/lab_gr_pause 2>/dev/null) khz: gpc=$(cat $PRM/lab_gpc_khz) rop=$(cat $PRM/lab_rop_khz) hub07=$(cat $PRM/lab_hub07_khz) hub06=$(cat $PRM/lab_hub06_khz) hub01=$(cat $PRM/lab_hub01_khz)" | tee -a "$LOG"; sync
case "$LOAD" in
  browser)
    B="$(command -v yandex-browser || command -v chromium || command -v google-chrome || true)"
    [ -n "$B" ] || { echo "Браузер не найден"; exit 1; }
    # отдельный профиль: иначе уже открытый браузер получает страницу, а новый процесс сразу завершается
    PROF="$HOME/.cache/nouveau-hangtest-profile"; rm -rf "$PROF"; mkdir -p "$PROF"   # свежий профиль каждый раз: иначе восстановление сессии прячет страницу
    "$B" --user-data-dir="$PROF" --no-first-run --no-default-browser-check --disable-sync --new-window \
         --app="file://$HERE/hangload.html" >/dev/null 2>&1 & LP=$!
    echo "$(date +%T) нагрузка: $B (pid $LP, профиль $PROF), страница hangload.html; прогрев 10 с" | tee -a "$LOG"; sleep 10 ;;
  glmark2)
    G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "glmark2 не установлен"; exit 1; }
    "$G" --run-forever -s 1600x900 -b shading:shading=phong -b bump:bump-render=high-poly -b refract >/dev/null 2>&1 & LP=$!
    echo "$(date +%T) нагрузка: glmark2 (pid $LP); прогрев 5 с" | tee -a "$LOG"; sleep 5 ;;
  none) echo "$(date +%T) без нагрузки (контроль)" | tee -a "$LOG" ;;
  *) echo "LOAD=browser|glmark2|none"; exit 1 ;;
esac
G="$(gr)"
if [ "$LOAD" != none ]; then
    for i in 1 2 3 4; do [ "$G" -ge 300 ] 2>/dev/null && break; sleep 5; G="$(gr)"; done
    [ "$G" -ge 300 ] 2>/dev/null || { echo "$(date +%T) СТОП: нагрузка не поднялась (gr $G‰): окно нагрузки не на виду или без ускорения. Тест не начат." | tee -a "$LOG"; exit 1; }
fi
echo "$(date +%T) загрузка GR перед циклами: $G‰" | tee -a "$LOG"; sync
DONE=0
for c in $(seq 1 "$N"); do
    [ -n "$LP" ] && ! kill -0 "$LP" 2>/dev/null && { echo "$(date +%T) СТОП: нагрузка завершилась сама" | tee -a "$LOG"; break; }
    sleep "$(shuf -i 15-55 -n1 | awk '{print $1/10}')"       # случайная фаза 1.5–5.5 с, как у регулятора
    G0="$(gr)"; pstate 0f; TS="$(date +%T.%N | cut -c1-12)"
    busy=0; hung=""
    for s in $(seq 1 "$HOLD"); do
        sleep 1; g="$(gr)"
        [ "$g" -ge 999 ] 2>/dev/null && busy=$((busy + 1)) || busy=0
        E="$(errs)"
        if [ "$busy" -ge 4 ] || [ "${E:-0}" -gt 0 ]; then hung="gr=$g‰ ${busy}с подряд, ошибок журнала $E"; break; fi
    done
    AC="$(ac)"
    echo "$(date +%T) подъём $c/$N в $TS: gr до $G0‰, скрипт B $(bdur), после: $AC, gr $(gr)‰${hung:+ — ЗАВИСАНИЕ: $hung}" | tee -a "$LOG"; sync
    if [ -n "$hung" ]; then
        # подтверждение от ядра: «failed to idle channel» приходит через ~35-45 с после зависания; ждём до 90 с
        echo "$(date +%T) подозрение на зависание ($hung) — жду подтверждения ядра до 90 с, не перезагружайте" | tee -a "$LOG"; sync
        for s in $(seq 1 18); do sleep 5; E="$(errs)"; [ "${E:-0}" -gt 0 ] && break; done
        # объективная подпись из чёрного ящика: при зависании канал в GR (eng0=0x002640) и 0x400700 застывают на одном
        # значении, при здоровой нагрузке они меняются каждую секунду. 15 одинаковых строк подряд = зависание.
        SIG="$(tail -n 15 /var/log/gpu-blackbox/current.txt 2>/dev/null | grep -oE 'gr700=[0-9a-f]+ eng0=[0-9a-f]+' | sort -u | wc -l)"
        if [ "${E:-0}" -gt 0 ]; then hung="$hung; ядро подтвердило: $(journalctl -k -b 0 --no-pager --since "$T0" | grep -m1 -oE 'failed to idle[^$]*|SCHED_ERROR[^$]*' | cut -c1-80)"
        elif [ "$SIG" = 1 ]; then hung="$hung; подпись ящика подтвердила: eng0/gr700 застыли ($(tail -n1 /var/log/gpu-blackbox/current.txt | grep -oE 'gr700=[0-9a-f]+ eng0=[0-9a-f]+')) 15 с"
        elif [ "$(gr)" -lt 999 ] 2>/dev/null; then echo "$(date +%T) ложная тревога: GR освободился, подпись не застыла — продолжаю" | tee -a "$LOG"; hung=""; pstate 07; sleep 2; DONE=$c; continue
        else hung="$hung; ни ядро, ни подпись ящика за 90 с не подтвердили (GR 1000‰, но eng0/gr700 меняются) — НЕ ЗАСЧИТЫВАТЬ"; fi
    fi
    if [ -n "$hung" ]; then
        HUNG=1
        { echo "=== ЗАВИСАНИЕ ВОСПРОИЗВЕДЕНО на подъёме $c (нагрузка $LOAD): $hung"
          echo "    Нагрузка оставлена, lab_gov=0."
          echo "    Снимок регистров: /var/log/gpu-blackbox/hang-*.txt (чёрный ящик). Журнал: journalctl -k -b 0 --since '$T0'"
          echo "    Если экран замер: Alt+PrtSc, затем S, U, B. После перезагрузки: bash ~/Home/nouveau-fix/lab/blackbox.sh show"; } | tee -a "$LOG"; sync
        exit 2
    fi
    pstate 07; sleep 2; DONE=$c
    case "$(ac)" in *"memory 324 MHz"*) ;; *) echo "$(date +%T) СТОП: после спуска не 324 МГц: $(ac)" | tee -a "$LOG"; break;; esac
done
if [ "$DONE" -eq "$N" ]; then echo "=== $N подъёмов без зависания (нагрузка $LOAD). Лог: $LOG" | tee -a "$LOG"
else echo "=== Тест прерван после $DONE из $N подъёмов (см. причину выше). Лог: $LOG" | tee -a "$LOG"; fi
