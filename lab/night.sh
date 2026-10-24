#!/bin/bash
# СЕРИЯ ТЕСТОВ БЕЗ ПРИСМОТРА (24.10 вечер, быстрая серия Г: 40–42 — застревающий переключатель GPC при частых переходах:
# база, защита lab_mux_guard, lab_pll_keep под защитой; прежние серии — в истории git).
# Запуск из терминала в графическом сеансе, окно браузера с нагрузкой будет на экране:
#   POWEROFF=0 bash ~/Home/nouveau-fix/lab/night.sh       (днём: машину в конце не выключать)
# Один раз пароль sudo (дальше его держит сам hangtest: sudo вызывается каждые несколько секунд).
# Экран не гаснет и система не засыпает (gnome-session-inhibit; проверяется перед стартом). Тесты по очереди, по 60
# подъёмов; каждый — база (боевая конфигурация службы gpu-autoclock: память, PCIe, скобка по признаку, GPC на 03 на делителе,
# PMU 202,5 МГц; новые ключи 0) + свои отличия. Тест 30г — регулятор сам (lab_gov=2): нагрузка браузера включается и
# снимается, время переходов — в results/gov-*.txt. В конце чистой серии параметры и регулятор — как у службы.
# На первом зависании: копия журнала ядра, ящика и нового снимка в results/, sync; дальнейшие тесты не идут.
# Итог — results/night-*.txt. В конце (и при зависании) серия ЖДЁТ разрешения на выключение: файл
# ~/Home/nouveau-archive/night-poweroff.ok (его создаёт ассистент после разбора), но не дольше WAITMIN (60) минут;
# sudo в это время продлевается. Затем выключение: после чистой серии — systemctl poweroff -i (запасной путь SysRq),
# после зависания — SysRq S, U, O. POWEROFF=0 — не выключать.
# Сухой прогон (без sudo, без карты): NIGHT_DRY=1 NIGHT_HT=заглушка NIGHT_RES=каталог NIGHT_STUCK=сек ... (см. ниже).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; PRM=/sys/module/nouveau/parameters
POWEROFF="${POWEROFF:-1}"; WAITMIN="${WAITMIN:-60}"
FLAG="${NIGHT_FLAG:-$HOME/Home/nouveau-archive/night-poweroff.ok}"
RES="${NIGHT_RES:-$KIT/results}"          # куда пишут hangtest и серия
HT="${NIGHT_HT:-$HERE/hangtest.sh}"        # сам тест
STUCK="${NIGHT_STUCK:-240}"                # журнал теста не растёт столько секунд — тест застрял
GRACE="${NIGHT_GRACE:-100}"                # после подписи зависания в ядре дать тесту и ящику записать своё
WAITSTEP="${NIGHT_WAITSTEP:-10}"           # шаг ожидания разрешения, с
DRY="${NIGHT_DRY:-0}"
GOV_N="${NIGHT_GOV_N:-3}"; GOV_ON="${NIGHT_GOV_ON:-20}"; GOV_OFF="${NIGHT_GOV_OFF:-30}"   # тест регулятора: циклы, нагрузка, без неё (с)
if [ "$DRY" = 1 ]; then SUDO="echo [dry-sudo]"; else SUDO="sudo"; fi
if [ -z "${NIGHT_INHIBITED:-}" ]; then
    rm -f "$FLAG"
    exec env NIGHT_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend --inhibit logout \
         --reason "nouveau night tests" bash "$0" "$@"
fi
if [ "$DRY" != 1 ]; then
    for p in lab_therm_div lab_gpc_div lab_pmu_div lab_gpc_pre405 lab_nv_hubpost lab_nv_pcie_late lab_nv_hub07mem lab_gov_nv lab_volt_wait_us lab_nv_22680 lab_nv_divb lab_nv_disphold lab_mux_guard lab_mux_timeouts; do
        [ -e "$PRM/$p" ] || { echo "Нет параметра $p — загружен не тот драйвер (lab.sh install и перезагрузка)"; exit 1; }
    done
    [ "$(cat $PRM/lab_perf_ticks)" -gt 0 ] || { echo "Замеры загрузки PMU выключены (lab_perf_ticks=0) — служба gpu-autoclock не отработала"; exit 1; }
    INH="$(gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager \
           --method org.gnome.SessionManager.IsInhibited 8 2>&1)"
    [ "$INH" = "(true,)" ] || { echo "Запрет гашения экрана не работает ($INH) — экран погаснет, тесты будут без нагрузки. Не запускаю."; exit 1; }
    sudo -v || exit 1
    # подстраховка к запрету: гашение экрана GNOME «никогда» на время серии, ваше значение вернётся перед выключением
    # исходное значение — в файл: если машина встанет намертво, вернуть его некому (24.10 осталось 0); следующий запуск возьмёт из файла
    IDLE_SAVE="$(dirname "$FLAG")/night-idle-delay.saved"
    [ -s "$IDLE_SAVE" ] || gsettings get org.gnome.desktop.session idle-delay > "$IDLE_SAVE" 2>/dev/null
    OLD_IDLE="$(cat "$IDLE_SAVE")"
    gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
fi
restore_idle() { [ -n "${OLD_IDLE:-}" ] && gsettings set org.gnome.desktop.session idle-delay "${OLD_IDLE#uint32 }" 2>/dev/null && rm -f "${IDLE_SAVE:-}"; OLD_IDLE=""; }
trap restore_idle EXIT
mkdir -p "$RES"; LOG="$RES/night-$(date +%Y%m%d-%H%M%S).txt"; MARK="$RES/.night-mark"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; sync; }
setp() { local kv; for kv in "$@"; do $SUDO sh -c "echo ${kv#*=} > $PRM/${kv%%=*}"; done; }
base() { setp lab_gov=0 lab_mem=1 lab_pcie=1 lab_volt_min_uv=0 lab_therm=1 lab_therm_wait=1 lab_therm_wait_us=0 \
              lab_therm_real=0 lab_therm_div=1 lab_clk_mmu_lock=0 lab_gpc_div=1 lab_pmu_div=1 \
              lab_gpc_pre405=0 lab_nv_hubpost=0 lab_nv_pcie_late=0 lab_nv_hub07mem=0 lab_gov_nv=0 lab_perf_ms=1000 lab_perf_log=0 \
              lab_volt_wait_us=0 lab_nv_22680=0 lab_nv_divb=0 lab_nv_disphold=0 lab_e9e0=0 lab_order=0 lab_pll_keep=0 lab_mux_guard=0; }
GOV_START="$(cat $PRM/lab_gov 2>/dev/null || echo 0)"; NT0="$(date '+%Y-%m-%d %H:%M:%S')"
finish_night() {   # $1 = clean | hung
    [ "$POWEROFF" = 1 ] || { restore_idle; say "POWEROFF=0 — машину не выключаю"; exit 0; }
    say "СЕРИЯ ЗАВЕРШЕНА ($1). Жду разрешения на выключение ($FLAG), не дольше $WAITMIN мин"
    local m=0 lim=$(( WAITMIN * 60 / WAITSTEP ))
    while [ ! -e "$FLAG" ] && [ $m -lt $lim ]; do
        sleep "$WAITSTEP"; m=$((m + 1))
        [ $(( m * WAITSTEP % 300 )) -lt "$WAITSTEP" ] && $SUDO -n -v 2>/dev/null
    done
    if [ -e "$FLAG" ]; then say "разрешение получено"; else say "разрешения нет $WAITMIN мин — выключаю"; fi
    restore_idle; say "гашение экрана GNOME возвращено: $(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null)"
    sync
    if [ "$1" = hung ]; then
        say "выключение через SysRq (S, U, O)"
        $SUDO sh -c 'echo s > /proc/sysrq-trigger; sleep 3; echo u > /proc/sysrq-trigger; sleep 2; echo o > /proc/sysrq-trigger'
    else
        say "выключение: systemctl poweroff -i"
        $SUDO systemctl poweroff -i || $SUDO sh -c 'echo s > /proc/sysrq-trigger; sleep 3; echo u > /proc/sysrq-trigger; sleep 2; echo o > /proc/sysrq-trigger'
    fi
    exit 0
}
hung() {   # $1 = имя теста
    local T f; T="$(date +%Y%m%d-%H%M%S)"
    say "ЗАВИСАНИЕ в тесте $1 — сохраняю журнал ядра, ящик и новые снимки"
    journalctl -b 0 -o short-precise --no-pager > "$RES/night-journal-$T.txt" 2>/dev/null
    tail -n 400 /var/log/gpu-blackbox/current.txt > "$RES/night-blackbox-$T.txt" 2>/dev/null
    for f in /var/log/gpu-blackbox/hang-*.txt; do [ "$f" -nt "$MARK" ] && cp "$f" "$RES/"; done 2>/dev/null
    sync
    finish_night hung
}
run() {   # run ИМЯ НИЗ-ВЕРХ[-СЕРЕДИНА] [параметр=значение ...]; с серединой спуск идёт через неё
    local name="$1" lv="$2"; shift 2
    base; [ "$#" -gt 0 ] && setp "$@"
    say "=== тест $name: уровни $lv, подъёмов ${RUNS:-60}; отличия от базы: ${*:-нет}"
    local t0 R="" rc=0 pid kerr k w; t0="$(date '+%Y-%m-%d %H:%M:%S')"; touch "$MARK"; sleep 1
    local lo hi mid; IFS=- read -r lo hi mid <<< "$lv"
    LOW="$lo" HIGH="$hi" MID="$mid" bash "$HT" "${RUNS:-60}" & pid=$!
    # журнал именно этого теста: созданный после метки (ждём до 60 с)
    for k in $(seq 1 60); do
        R="$(find "$RES" -maxdepth 1 -name 'hangtest-*.txt' -newer "$MARK" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-)"
        [ -n "$R" ] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    [ -n "$R" ] || { say "тест $name: журнал теста не появился"; wait "$pid"; finish_night clean; }
    say "тест $name: журнал $(basename "$R")"
    # сторож: тест сам может застрять (карта пропала с шины — тест 18); журнал теста растёт каждые ~12 с
    while kill -0 "$pid" 2>/dev/null; do
        sleep 10
        kill -0 "$pid" 2>/dev/null || break          # тест уже закончился — оценим его итог ниже
        kerr="$(journalctl -k -b 0 --no-pager --since "$t0" 2>/dev/null | grep -cE 'intr.c:191|vmmgf100.c|g84_bar_flush|failed to idle' || true)"
        if [ "${kerr:-0}" -gt 0 ]; then
            say "тест $name: в журнале ядра подпись зависания ($kerr строк) — жду ${GRACE} с, чтобы тест и ящик записали своё"
            w=0; while kill -0 "$pid" 2>/dev/null && [ $w -lt "$GRACE" ]; do sleep 5; w=$((w+5)); done
            tail -n 3 "$R" >> "$LOG"; hung "$name"
        fi
        if [ $(( $(date +%s) - $(stat -c %Y "$R") )) -gt "$STUCK" ]; then
            say "тест $name: журнал теста не растёт ${STUCK} с — считаю зависанием"; tail -n 3 "$R" >> "$LOG"; hung "$name"
        fi
    done
    wait "$pid"; rc=$?
    say "тест $name: закончился, код $rc"; tail -n 3 "$R" >> "$LOG"; sync
    grep -q "ЗАВИСАНИЕ ВОСПРОИЗВЕДЕНО" "$R" && hung "$name"
    grep -q "подъёмов без зависания" "$R" || { say "тест $name не дошёл до конца (код $rc) — серия остановлена"; finish_night clean; }
}
gsleep() {   # gsleep СЕК ИМЯ — пауза теста регулятора; каждые 5 с журнал ядра с начала серии на подписи зависания
    local s=0 k
    while [ "$s" -lt "$1" ]; do
        sleep 5; s=$((s + 5))
        k="$(journalctl -k -b 0 --no-pager --since "$NT0" 2>/dev/null | grep -cE 'intr.c:191|vmmgf100.c|g84_bar_flush|failed to idle' || true)"
        if [ "${k:-0}" -gt 0 ]; then
            say "тест $2: в журнале ядра подпись зависания ($k строк) — жду ${GRACE} с, чтобы ящик записал своё"
            sleep "$GRACE"; hung "$2"
        fi
    done
}
gov() {   # gov ИМЯ [параметр=значение ...] — регулятор переключает сам: GOV_N раз нагрузка GOV_ON с, без неё GOV_OFF с
    local name="$1" B PROF LP c f; shift
    base; [ "$#" -gt 0 ] && setp "$@"
    B="$(command -v yandex-browser || command -v chromium || command -v google-chrome || true)"
    [ -n "$B" ] || { say "тест $name: браузер не найден — пропущен"; return; }
    PROF="$HOME/.cache/nouveau-hangtest-profile"
    f="$RES/gov-$name-$(date +%Y%m%d-%H%M%S).txt"
    say "=== тест $name: регулятор сам (lab_gov=2), $GOV_N x (нагрузка $GOV_ON с, без неё $GOV_OFF с); отличия от базы: ${*:-нет}"
    local gt0; gt0="$(date '+%Y-%m-%d %H:%M:%S')"
    setp lab_perf_log=1 lab_gov=2
    logger -t labgov "$name: регулятор включён, без нагрузки $GOV_OFF с"
    gsleep "$GOV_OFF" "$name"
    for c in $(seq 1 "$GOV_N"); do
        if [ "$DRY" = 1 ]; then sleep 1000 & LP=$!
        else
            rm -rf "$PROF"; mkdir -p "$PROF"
            "$B" --user-data-dir="$PROF" --no-first-run --no-default-browser-check --disable-sync --new-window \
                 --app="file://$HERE/hangload.html" >/dev/null 2>&1 & LP=$!
        fi
        logger -t labgov "$name: нагрузка $c ВКЛ (браузер запущен)"; say "тест $name: нагрузка $c вкл"
        gsleep "$GOV_ON" "$name"
        kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
        logger -t labgov "$name: нагрузка $c ВЫКЛ (браузер закрыт)"; say "тест $name: нагрузка $c выкл"
        gsleep "$GOV_OFF" "$name"
    done
    setp lab_gov=0 lab_perf_log=0
    journalctl -b 0 -o short-precise --no-pager --since "$gt0" 2>/dev/null | grep -E 'LAB (gov|perf):|labgov' > "$f"
    grep -E 'LAB gov:|labgov' "$f" | sed 's/^/    /' >> "$LOG"
    say "тест $name: закончился; переключений регулятора $(grep -c 'LAB gov: ->' "$f"), подробно (с загрузкой по замерам) — $(basename "$f")"
}
systemctl is-active -q gpu-blackbox && grep "### blackbox start" /var/log/gpu-blackbox/current.txt 2>/dev/null | tail -n1 | grep -q " v4" \
    || say "⚠ чёрный ящик не v4 или не запущен — температуры процессора в ящике не будет"
say "серия: драйвер $(modinfo -n nouveau 2>/dev/null), ядро $(uname -r), POWEROFF=$POWEROFF WAITMIN=$WAITMIN DRY=$DRY"
# Быстрая серия Г (24.10 вечер, идея пользователя: участить переходы). Переключатель GPC застревает примерно в 1 % спусков
# с PLL на делитель; при цикле ~3 с (hangtest FAST=1: пауза 0,2–0,8 с, 1 с на 0f, по 0,5 с на 07 и 03) это ~1200 спусков в
# час против ~250 в обычном темпе. 40 — база (сколько тайм-аутов на частых переходах, снимки состояния), 41 — защита,
# 42 — lab_pll_keep под защитой, только если в 41 защита сработала.
NV="lab_gpc_pre405=1 lab_nv_hubpost=1 lab_nv_pcie_late=1 lab_nv_hub07mem=1 lab_gov_nv=1"
export FAST=1
RUNS=800
run 40  03-0f-07 $NV                            # база, частые переходы
T41="$(date '+%Y-%m-%d %H:%M:%S')"
run 41  03-0f-07 $NV lab_mux_guard=1            # защита
if journalctl -k -b 0 --no-pager --since "$T41" 2>/dev/null | grep -q "LAB mux_guard idx"; then
    run 42  03-0f-07 $NV lab_mux_guard=1 lab_pll_keep=1   # 34б под защитой
else
    say "=== тест 42 пропущен: в тесте 41 защита ни разу не сработала — lab_pll_keep под ней проверять рано"
fi
unset FAST; RUNS=60
base; setp lab_gov="$GOV_START"
say "=== серия закончена без зависаний; параметры как у службы, регулятор lab_gov=$GOV_START"
finish_night clean
