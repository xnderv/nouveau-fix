#!/bin/bash
# СЕРИЯ ТЕСТОВ БЕЗ ПРИСМОТРА. Сейчас (25.10): тест 49 — делитель ядра как у NVIDIA (lab_nv_div_late). 49а — контроль без
# ключа до 2 тайм-аутов (не больше 600 подъёмов, ~25 мин): плохая ли сессия; если был хоть один — 49б с ключом, 1500 подъёмов
# (~65 мин). TEST=50 — для ХОРОШЕЙ сессии: 50а с ключом 1500 подъёмов, 50б без ключа 600 (испортит ли ключ сессию).
# TEST=51 — как 49, но ключ lab_nv_divb (поле B делителя как у NVIDIA). TEST=52 — как 49, оба ключа сразу (полный рецепт
# NVIDIA для делителя ядра). TEST=53 — «линии»: поле B ядра 02 → 03 (÷5) → 1e (÷32) → 02, в любой сессии (нужна сборка
# с lab_divb_force). TEST=54 — сессия с полем B, не затёртым с загрузки (служба по файлу /etc/gpu-autoclock.divb): хорошая
# или плохая; итог по загрузкам копится в results/test54-sessions.txt. TEST=55 — в одной сессии туда и обратно: команда
# (смена поля A перед переключателем) с линией NVIDIA ÷32 → без ключей → команда с «неправильной» линией ÷5 → снова ÷32.
# TEST=56 — что держит починку: команда + ÷32 → без команды и без смены поля B → команда с обычным полем B (02).
# TEST=57 (27.10) — выдержка после входа в скобку как у NVIDIA 390 (lab_therm_wait_us, WAITUS=6|2), без команды; lspci плохой
# сессии. TEST=58 — то же значение делителя внутри скобки (lab_nv_div_same, сборка 27.10). Прежние серии — в git.
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
"$KIT/daily/check-driver.sh" --banner 2>/dev/null   # 28.10: штатное ядро/новое ядро без драйвера
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
    for p in lab_therm_div lab_gpc_div lab_pmu_div lab_gpc_pre405 lab_nv_hubpost lab_nv_pcie_late lab_nv_hub07mem lab_gov_nv lab_volt_wait_us lab_nv_22680 lab_nv_divb lab_nv_disphold lab_mux_guard lab_mux_timeouts lab_boot_snap lab_nv_mux_release lab_nv_div_late; do
        [ -e "$PRM/$p" ] || { echo "Нет параметра $p — загружен не тот драйвер (lab.sh install и перезагрузка)"; exit 1; }
    done
    if { [ "${TEST:-49}" = 53 ] || [ "${TEST:-49}" = 55 ] || [ "${TEST:-49}" = 56 ]; } && [ ! -e "$PRM/lab_divb_force" ]; then
        echo "Нет параметра lab_divb_force — для теста ${TEST} нужна новая сборка (lab.sh install и перезагрузка)"; exit 1
    fi
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
              lab_volt_wait_us=0 lab_nv_22680=0 lab_nv_divb=0 lab_nv_disphold=0 lab_e9e0=0 lab_order=0 lab_pll_keep=0 lab_mux_guard=0 lab_nv_mux_release=0 lab_nv_div_late=0
        [ -e "$PRM/lab_divb_force" ] && setp lab_divb_force=0
        [ -e "$PRM/lab_nv_div_same" ] && setp lab_nv_div_same=0 lab_pll_off_in_bracket=0
        [ -e "$PRM/lab_therm_gpc_factor" ] && setp lab_therm_gpc_factor=10 lab_therm_hub_factor=2; true; }   # в старых сборках этих ключей нет
MTF="${NIGHT_MTF:-$PRM/lab_mux_timeouts}"   # счётчик тайм-аутов переключателя (сухой прогон подставляет свой файл)
mt() { cat "$MTF" 2>/dev/null || echo 0; }
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
    say "тест $name: журнал $(basename "$R")"; HTLOG="$R"
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
# 25.10: до тестов — снимок регистров этой загрузки против сохранённых снимков плохих загрузок (lab/bootsnap.sh)
for REF in $(ls -t "$RES"/bootsnap-*-bad.txt 2>/dev/null); do
    say "снимок этой загрузки ($(uptime -s)) против $(basename "$REF"): $(bash "$HERE/bootsnap.sh" 0 "$REF" 2>&1 | tail -n 1)"
done
bash "$HERE/bootsnap.sh" 0 "$(ls -t "$RES"/bootsnap-*-bad.txt 2>/dev/null | head -n1)" 2>&1 | grep -v '^сравнено' | sed 's/^/    /' >> "$LOG"
# Тест 49 (25.10). Тайм-ауты переключателя ядра PLL → делитель бывают в одних сессиях (~0,3–1 %) и не бывают в других;
# регистры загрузок при этом одинаковые. У NVIDIA (записи t1/t2) делитель ядра меняется прямо перед переключением (внутри
# скобки, за ~2 мкс до 0x137100), на 0f простаивает на 06; у нас он стоит 81200202 с первого перехода после загрузки.
# Гипотеза: внутреннее состояние делителя складывается раз на сессию, а NVIDIA его обновляет на каждом переключении.
# 49а — контроль, ключ 0: до 2 тайм-аутов, не больше 600 подъёмов (~25 мин). Нет ни одного — сессия хорошая, 49б не идёт
#       (ничего бы не доказал): перезагрузиться и запустить снова.
# 49б — lab_nv_div_late=1 в той же сессии, 1500 подъёмов (~65 мин). Ключ включается на ходу: первый спуск после включения
#       пишет 02 поверх 02, со следующего подъёма — как у NVIDIA. Снимок регистров загрузки — в results/bootsnap-*.
# Тест 51 (25.10) — та же схема, ключ lab_nv_divb=1. По rnndb (gf100_div_ctrl) поле B (биты 8–13) — «делитель в режиме PLL»,
# поле A — «в режиме делителя» (для пост-делителей так его читает и nouveau; для 0x1371d0 — тот же тип, «TODO: Verify»).
# У NVIDIA B ≠ A (ядро: B = 1e, значение включения, A = 02): если поле B действует, делитель меняет темп B → A ровно в момент
# переключения — железо само перезапускает его в нужную точку. У нас B = A = 02 — менять нечего, делитель идёт с того
# положения, в котором оказался после загрузки. Ключ ставит в поле B значение самого низкого уровня (ядро 1e, ROP/hubk07 0a),
# как у NVIDIA. На карте ключ запускается впервые (тест 35 серии В 24.10 не дошёл: серия встала на 34б).
# Тест 52 (25.10) — та же схема, оба ключа: lab_nv_divb=1 и lab_nv_div_late=1. Делитель ядра тогда ровно как у NVIDIA:
# 81201e06 на 0f, 81201e02 на 07 (поле B = 1e постоянно, поле A меняется внутри скобки прямо перед переключателем).
# Гипотеза «черты»: выравнивание делителя запускает запись (A), а длину общей черты задаёт поле B (÷32 у NVIDIA — в неё
# укладываются все делители ядра: ÷4, ÷8, опора ÷8); у нас B = ÷4, и опора ÷8 может встать в одну из двух половин.
NV="lab_gpc_pre405=1 lab_nv_hubpost=1 lab_nv_pcie_late=1 lab_nv_hub07mem=1 lab_gov_nv=1"
BOOT="$(date -d "$(uptime -s)" +%Y%m%d-%H%M)"
export FAST=1
TEST="${TEST:-49}"
if [ "$TEST" = 50 ]; then
# Тест 50 (25.10) — в сессии, которую тест 49а признал ХОРОШЕЙ (0 на 600 без ключа). Если состояние сидит в делителе ядра,
# ключ, перезаписывая его на каждом переходе (06 на 0f, 02 перед переключателем), заново «бросает кости».
# 50а — ключ lab_nv_div_late=1, 1500 подъёмов (~65 мин; при 5 тайм-аутах — стоп, ответ уже есть).
# 50б — ключ 0, 600 подъёмов (~25 мин): осталась ли сессия хорошей после периода с ключом.
RUNS=1500
MT0="$(mt)"
export STOPMUX=5
run 50а 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_late=1   # делитель перезаписывается на каждом переходе
unset STOPMUX
MT1="$(mt)"; T50A=$((MT1 - MT0)); N50A="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 50а (lab_nv_div_late=1, сессия была хорошей): тайм-аутов $T50A на $N50A подъёмов"
RUNS=600
run 50б 03-0f-07 $NV lab_mux_guard=1                     # контроль: ключ 0, как в 49а
MT2="$(mt)"; T50B=$((MT2 - MT1)); N50B="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 50б (ключ 0): тайм-аутов $T50B на $N50B подъёмов; до теста 50 без ключа было 0 на 600 (49а)"
if [ "$T50A" -gt 0 ]; then
    say "=== С КЛЮЧОМ в хорошей сессии появились тайм-ауты ($T50A на $N50A): перезапись делителя меняет его состояние, порядок NVIDIA сам не защищает"
    if [ "$T50B" -gt 0 ]; then say "=== и после выключения ключа сессия ИСПОРЧЕНА ($T50B на $N50B)"
    else say "=== после выключения ключа — снова чисто (0 на $N50B)"; fi
elif [ "$T50B" -gt 0 ]; then
    say "=== СЕССИЯ ИСПОРЧЕНА: с ключом 0 на $N50A, а после его выключения $T50B на $N50B (до этого 0 на 600) — ключ перебросил делитель и, пока был включён, защищал"
else
    say "=== оба чистые (0 на $N50A с ключом, 0 на $N50B без) — про делитель не узнали; перезагрузка и тест 49 заново"
fi
KIND=""
elif [ "$TEST" = 53 ]; then
# Тест 53 (25.10) — гипотеза «линии»: делитель ядра при каждой записи выравнивается по черте, длину которой задаёт поле B.
# Держим в поле B ядра заданное значение (lab_divb_force, драйвер пишет его при каждой записи делителя):
# 53а — 02 (÷4, как сейчас), 300 подъёмов — какая сессия; 53б — 03 (÷5: не делится на 4 и не делит 4 — «неправильная»
# линия), 600 (стоп на 10 тайм-аутах) — по гипотезе ломает в любой сессии; 53в — 1e (÷32, линия NVIDIA), 600 (стоп на 10) —
# по гипотезе лечит; 53г — снова 02, 300. Поле B у ядра неактивно (0x137160 бит 8 = 0): такт ядра от него не зависит.
RUNS=300
MT0="$(mt)"
run 53а 03-0f-07 $NV lab_mux_guard=1
MT1="$(mt)"; TA=$((MT1 - MT0)); NA="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 53а (поле B ядра 02 = ÷4, как сейчас): тайм-аутов $TA на $NA подъёмов"
RUNS=600; export STOPMUX=10
run 53б 03-0f-07 $NV lab_mux_guard=1 lab_divb_force=0x03
MT2="$(mt)"; TB=$((MT2 - MT1)); NB="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 53б (поле B 03 = ÷5, «неправильная» линия): тайм-аутов $TB на $NB подъёмов"
run 53в 03-0f-07 $NV lab_mux_guard=1 lab_divb_force=0x1e
unset STOPMUX
MT3="$(mt)"; TC=$((MT3 - MT2)); NC="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 53в (поле B 1e = ÷32, линия NVIDIA): тайм-аутов $TC на $NC подъёмов"
RUNS=300
run 53г 03-0f-07 $NV lab_mux_guard=1
MT4="$(mt)"; TD=$((MT4 - MT3)); ND="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 53г (снова 02): тайм-аутов $TD на $ND подъёмов"
if [ "$TB" -gt 0 ] && [ "$TC" -eq 0 ]; then
    say "=== ЛИНИЯ РЕШАЕТ: с ÷5 тайм-ауты ($TB на $NB), с ÷32 как у NVIDIA — 0 на $NC (контроль: $TA/$NA до, $TD/$ND после)"
elif [ "$TB" -eq 0 ]; then
    say "=== «неправильная» линия ÷5 не ломает (0 на $NB) — поле B на выравнивание, похоже, не влияет (контроль: $TA/$NA, $TD/$ND; ÷32: $TC/$NC)"
else
    say "=== тайм-ауты и с ÷5 ($TB на $NB), и с ÷32 ($TC на $NC) — линия NVIDIA не лечит (контроль: $TA/$NA до, $TD/$ND после)"
fi
KIND=""; [ "$TA" -gt 0 ] && KIND=bad
elif [ "$TEST" = 57 ]; then
# Тест 57 (27.10, переоценка: docs/2026-10-27/reassessment.md, гипотеза Г1) — выдержка после входа в скобку, как у NVIDIA 390.
# 390 после записи FSRM ждёт ~8 мкс по таймеру (6 чтений PTIMER 0x009400 в try7) и только потом пишет делитель и
# переключатель; у нас — признак замедления (~2,2 мкс) + чтение переключателя (~1 мкс). «Команда» (lab_nv_div_late)
# добавляет перед переключателем ещё чтение и запись делителя (~2 мкс) — и лечит; что именно лечит — смена значения или
# лишние микросекунды — не разделено. Драйвер 2011 года (270.41.06) без выдержки по таймеру не застревал (0 на 451), но
# под записью его выдержка ~130 мкс. Здесь: ключ lab_therm_wait_us=6 (запас ПОСЛЕ признака, итого ≈ 8 мкс; действует и
# у hubk06, у которого NVIDIA ждёт 4–5 мкс), без команды.
# 57о — контроль без ключей, до 2 тайм-аутов, не больше 600 подъёмов: плохая ли сессия (иначе стоп: перезагрузка, снова);
#       в плохой сессии — lspci карты и корневого порта в results/lspci-<загрузка>-bad.txt (опыт Е7, только чтение);
# 57а — lab_therm_wait_us=6, без команды, 1500 подъёмов (стоп на 5); WAITUS=2 (порог: столько добавляет команда) — тот же
#       тест с другим запасом;
# 57б — контроль без ключей, 300 (стоп на 3): сессия всё ещё плохая?
RUNS=600; MT00="$(mt)"; export STOPMUX=2
run 57о 03-0f-07 $NV lab_mux_guard=1
T0C=$(( $(mt) - MT00 )); N0C="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 57о (контроль, без ключей): тайм-аутов $T0C на $N0C подъёмов"
if [ "$T0C" -eq 0 ]; then
    say "=== сессия сейчас ХОРОШАЯ (0 на $N0C без ключей) — 57а ничего не докажет; серия остановлена: перезагрузка и снова"
    base; setp lab_gov="$GOV_START"; setp lab_nv_div_late=1 lab_mux_guard=1; [ -e /etc/gpu-autoclock.divb ] && setp lab_nv_divb=1
    finish_night clean
fi
{ $SUDO lspci -vvv -s 01:00.0; echo; $SUDO lspci -vvv -s 00:01.0; } > "$RES/lspci-$BOOT-bad.txt" 2>&1 && say "=== lspci плохой сессии: results/lspci-$BOOT-bad.txt (сравнить с lspci-1447-good.txt)"
RUNS=1500; MT0="$(mt)"; export STOPMUX=5
WAITUS="${WAITUS:-6}"
run 57а 03-0f-07 $NV lab_mux_guard=1 lab_therm_wait_us=$WAITUS
MT1="$(mt)"; T1=$((MT1 - MT0)); N1="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 57а (выдержка +$WAITUS мкс после признака, без команды): тайм-аутов $T1 на $N1 подъёмов"
RUNS=300; export STOPMUX=3
run 57б 03-0f-07 $NV lab_mux_guard=1
unset STOPMUX
MT2="$(mt)"; T2=$((MT2 - MT1)); N2="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 57б (контроль, без ключей): тайм-аутов $T2 на $N2 подъёмов"
if [ "$T1" -eq 0 ] && [ "$T2" -gt 0 ]; then
    say "=== ВЫДЕРЖКА ЛЕЧИТ: с +$WAITUS мкс 0 на $N1, без неё до ($T0C/$N0C) и после ($T2/$N2) тайм-ауты есть — команда могла действовать временем; дальше порог (WAITUS=2) и тест 58"
elif [ "$T1" -eq 0 ]; then
    say "=== с +$WAITUS мкс 0 на $N1, но и контроль после чист ($T2/$N2) — сессия могла стать хорошей; неразделимо, повторить в другой плохой сессии"
else
    say "=== выдержка +$WAITUS мкс НЕ лечит ($T1 на $N1; контроль $T0C/$N0C, $T2/$N2) — дальше тест 58 (то же значение в скобке)"
fi
KIND=bad
elif [ "$TEST" = 61 ]; then
# Тест 61 (28.10, опыт Е14) — коэффициент замедления GPC в скобке: NVIDIA на GF114 ставит /6 (код 0xa), на GF106 — /2 (код 2).
# Имена и кодировка — из открытого кода NVIDIA для Tegra (therm_clk_slowdown idle_factor, код = 2·делитель − 2).
# Вопрос: зависит ли застревание переключателя (и нужная выдержка) от глубины замедления. База — как у NVIDIA: /6, ожидание
# по признаку, запас 0 мкс (lab_therm_wait_us=0), без команды. 61о — контроль (до 2 тайм-аутов, не больше 600: плохая ли
# сессия); 61а — GPC /2 (код 2), 1500 (стоп на 5); 61б — GPC /8 (код 0xe = 14), 1500 (стоп на 5); 61в — контроль, 300 (стоп на 3).
# Сторож и чёрный ящик обязательны: при /2 ядро в скобке идёт быстрее (900 вместо 300 МГц на спуске с 0f).
[ -e "$PRM/lab_therm_gpc_factor" ] || { say "СТОП: в этой сборке нет ключа lab_therm_gpc_factor — нужна сборка 28.10 (lab.sh install)"; finish_night clean; }
RUNS=600; MT00="$(mt)"; export STOPMUX=2
run 61о 03-0f-07 $NV lab_mux_guard=1
T0C=$(( $(mt) - MT00 )); N0C="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 61о (контроль, /6, без ключей): тайм-аутов $T0C на $N0C подъёмов"
if [ "$T0C" -eq 0 ]; then
    if [ "${GOODRUN:-0}" = 1 ]; then
        say "=== сессия сейчас ХОРОШАЯ (0 на $N0C без ключей); GOODRUN=1 — продолжаю 61а/61б/61в как проверку «не портит ли код /2 или /8 хорошую сессию»"
    else
        say "=== сессия сейчас ХОРОШАЯ (0 на $N0C без ключей) — 61а/61б ничего не докажут; серия остановлена: перезагрузка и снова (или GOODRUN=1)"
        base; setp lab_gov="$GOV_START"; setp lab_nv_div_late=1 lab_mux_guard=1; [ -e /etc/gpu-autoclock.divb ] && setp lab_nv_divb=1
        finish_night clean
    fi
fi
RUNS=1500; MT0="$(mt)"; export STOPMUX=5
run 61а 03-0f-07 $NV lab_mux_guard=1 lab_therm_gpc_factor=2
MT1="$(mt)"; T1=$((MT1 - MT0)); N1="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 61а (GPC /2 в скобке, код 2): тайм-аутов $T1 на $N1 подъёмов"
RUNS=1500; export STOPMUX=5
run 61б 03-0f-07 $NV lab_mux_guard=1 lab_therm_gpc_factor=14
MT2="$(mt)"; T2=$((MT2 - MT1)); N2="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 61б (GPC /8 в скобке, код 0xe): тайм-аутов $T2 на $N2 подъёмов"
RUNS=300; export STOPMUX=3
run 61в 03-0f-07 $NV lab_mux_guard=1
unset STOPMUX
MT3="$(mt)"; T3=$((MT3 - MT2)); N3="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 61в (контроль, /6): тайм-аутов $T3 на $N3 подъёмов"
say "=== ИТОГ Е14 ($([ "$T0C" -eq 0 ] && echo "хорошая сессия" || echo "плохая сессия")): /6 (контроль) $T0C/$N0C и $T3/$N3; /2 $T1/$N1; /8 $T2/$N2 — если /2 и /8 расходятся с /6, глубина замедления входит в условие; если все одинаковы — выдержка не зависит от коэффициента"
base; setp lab_gov="$GOV_START"; setp lab_nv_div_late=1 lab_mux_guard=1; [ -e /etc/gpu-autoclock.divb ] && setp lab_nv_divb=1
finish_night clean
elif [ "$TEST" = 58 ]; then
# Тест 58 (27.10, переоценка, опыт Е1) — то же значение делителя ядра внутри скобки прямо перед переключателем, без 06 на 0f
# (ключ lab_nv_div_same, сборка 27.10). Команда пишет 06 -> 02 и лечит; этот ключ пишет 02 -> 02: та же запись и те же
# ~2 мкс, но без смены значения. Лечит — дело в записи или во времени; не лечит — в смене значения.
# 58о — контроль без ключей, до 2 тайм-аутов, не больше 600: плохая ли сессия; 58а — lab_nv_div_same=1, 1500 (стоп на 5);
# 58б — контроль, 300 (стоп на 3).
[ -e "$PRM/lab_nv_div_same" ] || { say "СТОП: в этой сборке нет ключа lab_nv_div_same — нужна сборка 27.10 (lab.sh install)"; finish_night clean; }
RUNS=600; MT00="$(mt)"; export STOPMUX=2
run 58о 03-0f-07 $NV lab_mux_guard=1
T0C=$(( $(mt) - MT00 )); N0C="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 58о (контроль, без ключей): тайм-аутов $T0C на $N0C подъёмов"
if [ "$T0C" -eq 0 ]; then
    say "=== сессия сейчас ХОРОШАЯ (0 на $N0C без ключей) — 58а ничего не докажет; серия остановлена: перезагрузка и снова"
    base; setp lab_gov="$GOV_START"; setp lab_nv_div_late=1 lab_mux_guard=1; [ -e /etc/gpu-autoclock.divb ] && setp lab_nv_divb=1
    finish_night clean
fi
RUNS=1500; MT0="$(mt)"; export STOPMUX=5
run 58а 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_same=1
MT1="$(mt)"; T1=$((MT1 - MT0)); N1="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 58а (то же значение делителя внутри скобки, без смены): тайм-аутов $T1 на $N1 подъёмов"
RUNS=300; export STOPMUX=3
run 58б 03-0f-07 $NV lab_mux_guard=1
unset STOPMUX
MT2="$(mt)"; T2=$((MT2 - MT1)); N2="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 58б (контроль, без ключей): тайм-аутов $T2 на $N2 подъёмов"
if [ "$T1" -eq 0 ] && [ "$T2" -gt 0 ]; then
    say "=== ТО ЖЕ ЗНАЧЕНИЕ ЛЕЧИТ (0 на $N1; контроль $T0C/$N0C, $T2/$N2) — важна запись или время, не смена значения"
elif [ "$T1" -eq 0 ]; then
    say "=== 0 на $N1, но и контроль после чист ($T2/$N2) — неразделимо, повторить в другой плохой сессии"
else
    say "=== то же значение НЕ лечит ($T1 на $N1; контроль $T0C/$N0C, $T2/$N2) — важна смена значения 06 -> 02"
fi
KIND=bad
elif [ "$TEST" = 56 ]; then
# Тест 56 (25.10) — что держит починку. Тест 55: с командой (lab_nv_div_late: смена поля A делителя ядра внутри скобки
# прямо перед переключателем) тайм-аутов нет при поле B и 1e, и 03; без неё (55б) — снова есть, но там же один раз
# поменялось поле B (1e -> 02 на стадии 0). Ключи меняются, пока карта стоит на 03 (A = 02), так что смена ключа сама
# ничего в делителе не меняет.
# 56о — контроль без ключей, до 2 тайм-аутов, не больше 300 подъёмов: плохая ли сейчас сессия (56б и 56в имеют смысл
#       только в плохой; если тайм-аутов нет — стоп);
# 56а — команда + поле B 1e, 300 подъёмов (стоп на 3): вылечить;
# 56б — без команды, поле B то же 1e (ничего не меняется), 600 (стоп на 3): держится ли починка без команд;
# 56в — команда + обычное поле B 02, 600 (стоп на 3): лечит ли команда без особого поля B.
RUNS=300; MT00="$(mt)"; export STOPMUX=2
run 56о 03-0f-07 $NV lab_mux_guard=1
T0C=$(( $(mt) - MT00 )); N0C="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 56о (контроль, без ключей): тайм-аутов $T0C на $N0C подъёмов"
if [ "$T0C" -eq 0 ]; then
    say "=== сессия сейчас ХОРОШАЯ (0 на $N0C без ключей) — 56б и 56в ничего не докажут; серия остановлена"
    base; setp lab_gov="$GOV_START"; setp lab_nv_div_late=1 lab_mux_guard=1; [ -e /etc/gpu-autoclock.divb ] && setp lab_nv_divb=1
    finish_night clean
fi
RUNS=300; MT0="$(mt)"; export STOPMUX=3
run 56а 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_late=1 lab_divb_force=0x1e
MT1="$(mt)"; T1=$((MT1 - MT0)); N1="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 56а (команда + поле B 1e): тайм-аутов $T1 на $N1 подъёмов"
RUNS=600
run 56б 03-0f-07 $NV lab_mux_guard=1 lab_divb_force=0x1e
MT2="$(mt)"; T2=$((MT2 - MT1)); N2="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 56б (без команды, поле B то же 1e): тайм-аутов $T2 на $N2 подъёмов"
run 56в 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_late=1
unset STOPMUX
MT3="$(mt)"; T3=$((MT3 - MT2)); N3="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 56в (команда + обычное поле B 02): тайм-аутов $T3 на $N3 подъёмов"
if [ "$T2" -eq 0 ]; then
    say "=== ПОЧИНКА ДЕРЖИТСЯ без команд, если ничего не менять (56б: 0 на $N2) — положение задаётся один раз"
else
    say "=== без команды тайм-ауты вернулись ($T2 на $N2), хотя ничего не менялось — команда нужна на каждом переключении"
fi
if [ "$T3" -eq 0 ]; then say "=== команда лечит и с обычным полем B (56в: 0 на $N3) — поле B не нужно"
else say "=== с обычным полем B команда не лечит ($T3 на $N3) — поле B всё-таки нужно"; fi
KIND=""
elif [ "$TEST" = 55 ]; then
# Тест 55 (25.10) — «туда и обратно» в одной сессии (лучше в плохой). Гипотеза: поле B задаёт длину линии, а команда
# «встань по линии» — смена поля A делителя ядра внутри скобки прямо перед переключателем (как у NVIDIA: 06 -> 02 на
# спуске); у нас по умолчанию поле A не меняется (02 поверх 02) и пишется до скобки. Команда = lab_nv_div_late=1, линия =
# lab_divb_force (только ядро). 53в дал линию ÷32 без команды — не вылечил.
# 55а — команда + линия NVIDIA ÷32 (1e), 600 подъёмов, стоп на 3 тайм-аутах: чинит ли;
# 55б — без ключей, 300, стоп на 3: держится ли починка без них;
# 55в — команда + «неправильная» линия ÷5 (03), 600, стоп на 5: ломает ли;
# 55г — снова команда + ÷32, 600, стоп на 3: чинит ли снова.
RUNS=600; MT0="$(mt)"; export STOPMUX=3
run 55а 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_late=1 lab_divb_force=0x1e
MT1="$(mt)"; T1=$((MT1 - MT0)); N1="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 55а (команда + линия ÷32): тайм-аутов $T1 на $N1 подъёмов"
RUNS=300
run 55б 03-0f-07 $NV lab_mux_guard=1
MT2="$(mt)"; T2=$((MT2 - MT1)); N2="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 55б (без ключей): тайм-аутов $T2 на $N2 подъёмов"
RUNS=600; export STOPMUX=5
run 55в 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_late=1 lab_divb_force=0x03
MT3="$(mt)"; T3=$((MT3 - MT2)); N3="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 55в (команда + линия ÷5): тайм-аутов $T3 на $N3 подъёмов"
export STOPMUX=3
run 55г 03-0f-07 $NV lab_mux_guard=1 lab_nv_div_late=1 lab_divb_force=0x1e
unset STOPMUX
MT4="$(mt)"; T4=$((MT4 - MT3)); N4="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест 55г (снова команда + линия ÷32): тайм-аутов $T4 на $N4 подъёмов"
if [ "$T1" -eq 0 ] && [ "$T4" -eq 0 ] && [ "$T3" -gt 0 ]; then
    say "=== ТУДА И ОБРАТНО РАБОТАЕТ: команда + ÷32 — чисто дважды ($N1, $N4), команда + ÷5 — тайм-ауты ($T3 на $N3); без ключей между ними: $T2 на $N2"
elif [ "$T1" -eq 0 ] && [ "$T4" -eq 0 ]; then
    say "=== команда + ÷32 — чисто дважды ($N1, $N4), но команда + ÷5 не ломает (0 на $N3); без ключей: $T2 на $N2"
else
    say "=== команда + ÷32 не лечит: 55а $T1/$N1, 55г $T4/$N4 (÷5: $T3/$N3, без ключей: $T2/$N2)"
fi
KIND=""
elif [ "$TEST" = 54 ]; then
# Тест 54 (25.10) — гипотеза «линии», проверка с загрузки. 53в показал: поставить линию ÷32 посреди плохой сессии мало — она
# длиннее, но начало у неё прежнее, сдвинутое. У NVIDIA поле B не меняется с включения (1e — так ставит VBIOS); мы затираем
# его на первом же переключении (02). Здесь служба с файлом /etc/gpu-autoclock.divb ставит lab_nv_divb=1 до первого
# переключения — поле B остаётся как при включении всю сессию. 54а — та же проверка сессии, что 49а (до 2 тайм-аутов, не
# больше 600 подъёмов), с lab_nv_divb=1. Одна загрузка — одна строка в results/test54-sessions.txt; без этого прежде хороших
# было 2 загрузки из 8. По гипотезе плохих сессий быть не должно.
DB="$(journalctl -k -b 0 -o cat --no-pager 2>/dev/null | grep -oE '0x1371d0 [0-9a-f]{8}' | awk '{print substr($2,5,2)}' | sort -u | tr '\n' ' ')"
if [ "$DRY" != 1 ] && { [ ! -e /etc/gpu-autoclock.divb ] || [ "$(cat $PRM/lab_nv_divb)" != 1 ] || [ -n "$(echo $DB | tr ' ' '\n' | grep -v '^1e$')" ]; }; then
    say "=== тест 54 в этой загрузке не имеет смысла: файл /etc/gpu-autoclock.divb $([ -e /etc/gpu-autoclock.divb ] && echo есть || echo НЕТ), lab_nv_divb=$(cat $PRM/lab_nv_divb), поле B ядра в журнале с загрузки: ${DB:-нет записей}"
    say "    нужно: файл есть, служба поставила lab_nv_divb=1 до первого переключения, в журнале только 1e. Перезагрузись."
    finish_night clean
fi
say "поле B ядра с загрузки: ${DB:-записей ещё нет}(только 1e — как при включении)"
RUNS=600
MT0="$(mt)"
export STOPMUX=2
run 54а 03-0f-07 $NV lab_mux_guard=1 lab_nv_divb=1          # поле B как при включении, как в загрузке до теста
unset STOPMUX
MT1="$(mt)"; TA=$((MT1 - MT0)); NA="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
if [ "$TA" -eq 0 ]; then KIND=good; else KIND=bad; fi
echo "$BOOT $(date +%H:%M) тайм-аутов $TA на $NA подъёмов: $KIND" >> "$RES/test54-sessions.txt"
NS="$(grep -c '' "$RES/test54-sessions.txt")"; NG="$(grep -c ': good$' "$RES/test54-sessions.txt")"
say "=== тест 54а (поле B с загрузки как при включении): тайм-аутов $TA на $NA подъёмов — сессия $([ $KIND = good ] && echo ХОРОШАЯ || echo ПЛОХАЯ)"
say "=== всего в тесте 54: загрузок $NS, хороших $NG (results/test54-sessions.txt); без поля B с загрузки было 2 хороших из 8"
else
# 49 и 51 — одна схема для плохой сессии: «а» — контроль без ключа до 2 тайм-аутов, «б» — с ключом, если тайм-аут был
case "$TEST" in
    51) KEY=lab_nv_divb=1;      WHAT="поле B делителя как у NVIDIA" ;;
    52) KEY="lab_nv_divb=1 lab_nv_div_late=1"; WHAT="полный рецепт NVIDIA для делителя: поле B и смена A перед переключателем" ;;
    *)  TEST=49; KEY=lab_nv_div_late=1; WHAT="делитель меняется прямо перед переключателем" ;;
esac
RUNS=600
MT0="$(mt)"
export STOPMUX=2
run "${TEST}а" 03-0f-07 $NV lab_mux_guard=1                # контроль: ключ 0, до 2 тайм-аутов
unset STOPMUX
MT1="$(mt)"; TA=$((MT1 - MT0)); NA="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
say "=== тест ${TEST}а (ключ 0): тайм-аутов $TA на $NA подъёмов"
if [ "$TA" -eq 0 ]; then
    KIND=good
    say "=== сессия ХОРОШАЯ (0 на $NA без ключа) — тест ${TEST}б ничего не докажет; перезагрузись и запусти снова"
else
    KIND=bad
    RUNS=1500
    run "${TEST}б" 03-0f-07 $NV lab_mux_guard=1 $KEY
    MT2="$(mt)"; TB=$((MT2 - MT1)); NB="$(grep -c 'подъём [0-9]*/' "$HTLOG")"
    say "=== тест ${TEST}б ($KEY — $WHAT): тайм-аутов $TB на $NB подъёмов; без ключа в этой сессии было $TA на $NA"
    if [ "$TB" -eq 0 ]; then say "=== сессия ПЛОХАЯ, а с ключом — 0 на $NB: ПОХОЖЕ, ПОМОГАЕТ"
    else say "=== с ключом тайм-ауты есть ($TB на $NB) — один ключ не спасает; сравни частоты: $TA/$NA без ключа и $TB/$NB с ним"; fi
fi
fi
unset FAST HOLD
if [ -n "${KIND:-}" ]; then
    bash "$HERE/bootsnap.sh" 0 > "$RES/bootsnap-$BOOT-$KIND.txt" 2>&1
    say "снимок регистров загрузки: results/bootsnap-$BOOT-$KIND.txt"
fi
RUNS=60
RUNS=60
base; setp lab_gov="$GOV_START"
setp lab_nv_div_late=1 lab_mux_guard=1   # 25.10: служба ставит их по умолчанию (команда перед переключателем, защита)
[ -e /etc/gpu-autoclock.divb ] && setp lab_nv_divb=1   # как ставит служба с этим файлом
say "=== серия закончена без зависаний; параметры как у службы, регулятор lab_gov=$GOV_START"
finish_night clean
