#!/bin/bash
# НОЧНАЯ СЕРИЯ ТЕСТОВ (24.10; вторая ночь: 19b, 20, 21 — тест 19 сделан в первую). Запуск из терминала в графическом сеансе, окно браузера с нагрузкой будет на экране:
#   bash ~/Home/nouveau-fix/lab/night.sh
# Один раз пароль sudo (дальше его держит сам hangtest: sudo вызывается каждые несколько секунд).
# Экран не гаснет и система не засыпает (gnome-session-inhibit; проверяется перед стартом). Тесты по очереди, по 60
# подъёмов; каждый — база (боевая конфигурация: память, PCIe, напряжение по таблице, скобка по признаку) + свои отличия.
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
if [ "$DRY" = 1 ]; then SUDO="echo [dry-sudo]"; else SUDO="sudo"; fi
if [ -z "${NIGHT_INHIBITED:-}" ]; then
    rm -f "$FLAG"
    exec env NIGHT_INHIBITED=1 gnome-session-inhibit --inhibit idle --inhibit suspend --inhibit logout \
         --reason "nouveau night tests" bash "$0" "$@"
fi
if [ "$DRY" != 1 ]; then
    for p in lab_therm_div lab_clk_mmu_lock lab_therm_real; do
        [ -e "$PRM/$p" ] || { echo "Нет параметра $p — загружен не тот драйвер"; exit 1; }
    done
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
              lab_therm_real=0 lab_therm_div=1 lab_clk_mmu_lock=0; }
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
run() {   # run ИМЯ НИЗ-ВЕРХ [параметр=значение ...]
    local name="$1" lv="$2"; shift 2
    base; [ "$#" -gt 0 ] && setp "$@"
    say "=== тест $name: уровни $lv; отличия от базы: ${*:-нет}"
    local t0 R="" rc=0 pid kerr k w; t0="$(date '+%Y-%m-%d %H:%M:%S')"; touch "$MARK"; sleep 1
    LOW="${lv%%-*}" HIGH="${lv##*-}" bash "$HT" 60 & pid=$!
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
systemctl is-active -q gpu-blackbox && grep "### blackbox start" /var/log/gpu-blackbox/current.txt 2>/dev/null | tail -n1 | grep -q " v4" \
    || say "⚠ чёрный ящик не v4 или не запущен — температуры процессора в ящике не будет"
say "ночная серия: драйвер $(modinfo -n nouveau 2>/dev/null), ядро $(uname -r), POWEROFF=$POWEROFF WAITMIN=$WAITMIN DRY=$DRY"
# Тест 19 (03↔07 с этой базой) прошёл в первую ночь: зависание на 32-м подъёме, машина встала целиком.
# Порядок — от меньшего риска встать намертво к большему: зависание обрывает серию.
run 19b 07-0f                                   # база на проверенной паре 07↔0f (240 подъёмов без lab_therm_div) — не сломал ли её lab_therm_div
run 20  03-07 lab_therm=0                       # контроль: скобки нет совсем (lab_therm=0 выключает и стадию 4), как до 24.10
run 21  03-07 lab_clk_mmu_lock=1                # база + блокировка MMU на время стадий частот
setp lab_therm=1 lab_therm_div=1 lab_clk_mmu_lock=1
say "=== серия закончена без зависаний; параметры по умолчанию, регулятор оставлен выключенным"
finish_night clean
