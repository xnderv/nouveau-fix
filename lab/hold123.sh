#!/bin/bash
# ОПЫТ 123 (25.11), модуль 1124a, наша GF114: СТОЯНКА ПО УЗЛАМ ТАКТА.
# Что известно (опыт 122, часть 5, docs/2026-11-25/hang-122.md): при узлах ядра на верхнем уровне и памяти на 135 МГц
# графический блок (GR) встаёт на смене контекста через 12–23 с, без единого переключения. Вопрос: какой узел такта для
# этого нужен.
# Способ: память весь опыт стоит на нижней частоте (lab_mem=0). С нижнего уровня узлы ядра поднимаются на верхний не все
# сразу, а ступенями (lab_eng_mask — какие узлы перепрограммировать); после подъёма — стоянка HOLD секунд под glxgears;
# затем спуск на нижний уровень всеми узлами и следующая ступень. Соседние ступени отличаются одним узлом:
#   1 — наверху всё, кроме LTC2CLK и XBAR2CLK (маска 0xfff9)
#   2 — добавлен LTC2CLK, внизу один XBAR2CLK (0xfffb): проход NVIDIA на подъёме, остановленный перед шагом памяти
#   3 — добавлен XBAR2CLK, наверху всё (0xffff): наш проход по умолчанию; то же сочетание, что зависало в опыте 122
#   4 — только если 1–3 чисты: путь части 5 опыта 122 (обычный подъём, затем «только память» вниз) — контроль пути
# Порядок ступеней — как вложены узлы у NVIDIA на GF114 (подъём: SYS2CLK, HUB2CLK, GPC2CLK, LTC2CLK, память, XBAR2CLK):
# каждое состояние ступеней 1–3 драйвер NVIDIA сам проходит на подъёме, только за микросекунды.
# Ступени «без GPC2CLK» нет: при замаскированном GPC2CLK модуль считает переход спуском и переключает SYS2CLK и HUB2CLK в
# обратном порядке (gf100_clk_prog: направление берётся по цели GPC2CLK).
# HOLD по умолчанию 600 с: зависания приходили через 12, 20 и 23 с (среднее 18 с); даже если истинное среднее — 67 с
# (верхняя граница по трём случаям, 95 %), шанс не увидеть зависание за 600 с меньше 0,02 %.
# Признак зависания: glxgears 15 с не выдаёт кадров И 10 строк чёрного ящика подряд одинаковы не в состоянии покоя
# (0x400700 и 0x002640 застыли). На зависании опыт останавливается и карту больше не трогает (после зависания GR нужен
# перезапуск розеткой); улики — в results/hang-ДАТА/.
# Запуск по SSH внутри screen:   screen -S hold123 bash ~/Home/nouveau-fix/lab/hold123.sh [HOLD=600]
#   XBAR=1 (или 2) — на время опыта включить ключ lab_xbar: порты шины XBAR после подъёма как у NVIDIA (3 вместо наших 2);
#          28.11: у зависшего блока занята одна часть HUB с признаком «выход забит» — проверяем порты шины. В конце ключ возвращается.
#   STEPS=5 — (28.11) средний уровень целиком над нижней памятью: шина XBAR2CLK 810 МГц, память 135 МГц. Отношение частот
#          шины и памяти 6,0 — как у чистого сочетания 1909 / 324; у виснущего 1909 / 135 оно 14,1.
#   STEPS=6 — (28.11) наверху всё, кроме HUB2CLK (он остаётся на частоте нижнего уровня): нужен ли для зависания быстрый хаб.
#   XKHZ=1350000 — (28.11) на время опыта задать шине XBAR2CLK на верхнем уровне свою частоту, кГц (ключ lab_hub07_khz;
#          у шины свой PLL, остальные узлы — как обычно). Поиск границы: при каком отношении «шина / память» начинается
#          зависание. Вместе со STEPS=3. В конце ключ возвращается.
#   HKHZ=1350000 — (28.11) то же для хаба: HUB2CLK своего PLL не имеет и идёт от PLL узла SYS2CLK, поэтому частота
#          задаётся обоим (ключи lab_hub06_khz и lab_hub01_khz, потолок 1645000). Какие частоты встали на деле — печатается.
#   STEPS=7 — (28.11, вопрос владельца) шина МЕДЛЕННЕЕ памяти при быстром хабе: память переводится на средний уровень
#          (режим «только память»), затем наверх идут все узлы, кроме XBAR2CLK (он остаётся на нижней частоте).
#   STEPS="2 3" — только две ступени (по возрастанию; ступень 4 — всегда последней)
# Пароль sudo — один раз в начале; потом Ctrl-a d (отцепиться). Итог — results/test123-*.txt.
#   bash lab/hold123.sh --selftest ФАЙЛ   — проверить признак зависания на записи чёрного ящика (карта не нужна)
set -uo pipefail
KIT=~/Home/nouveau-fix; LAB="$KIT/lab"; PRM=/sys/module/nouveau/parameters
BOX="${BOX:-/var/log/gpu-blackbox/current.txt}"

# Застыл ли GR по чёрному ящику: последние 10 строк состояния одинаковы по паре 0x400700 / 0x002640, и это не покой
# (покой — 0x400700 = 0 и 0x002640 = 8001xxxx: канал загружен, смены контекста нет). Печатает застывшую пару.
frozen() {
    # в ящике между строками состояния бывают строки событий ядра — берём последние 10 строк состояния из последних 60
    local s; s="$(tail -n 60 "${1:-$BOX}" 2>/dev/null | grep -oE 'gr700=[0-9a-f]+ eng0=[0-9a-f]+' | tail -n 10 | sort | uniq -c)"
    [ "$(echo "$s" | wc -l)" = 1 ] || return 1
    echo "$s" | grep -qE '^ *10 ' || return 1
    echo "$s" | grep -qE 'gr700=00000000 ' && return 1    # 28.11: блок свободен — не зависание, каким бы ни был признак движка
                                                         # (после убитого канала он 00000005: опыт 12:19 был записан как зависание)
    echo "$s" | sed -E 's/^ *10 //'
}
# Когда GR встал: время первой строки ящика в последнем непрерывном ряду строк с этой парой
hangtime() { tail -n 150 "$BOX" | grep 'gr700=' | awk -v p="$1" 'index($0, p) { if (!run) { t = substr($0, 1, 8); run = 1 } next } { run = 0 } END { print t }'; }

if [ "${1:-}" = --selftest ]; then
    [ -r "${2:-}" ] || { echo "bash lab/hold123.sh --selftest ФАЙЛ_ЯЩИКА"; exit 1; }
    tmp="$(mktemp)"; n="$(wc -l < "$2")"; hits=0; first=""
    for i in $(seq 10 "$n"); do
        head -n "$i" "$2" > "$tmp"
        if f="$(frozen "$tmp")"; then hits=$((hits + 1)); [ -n "$first" ] || first="$(tail -n 1 "$tmp" | cut -c1-8) ($f)"; fi
    done
    rm -f "$tmp"; echo "строк $n; окон с признаком «застыл» $hits; первое: ${first:-нет}"; exit 0
fi

HOLD="${1:-600}"; STEPS="${STEPS:-1 2 3 4}"
[[ "$HOLD" =~ ^[0-9]+$ ]] || { echo "HOLD — число секунд"; exit 1; }
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"; export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
[ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
scr() { gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver."$@" 2>&1; }
for p in lab_eng_mask lab_mem lab_mem_only lab_gov lab_perf_gr; do
    [ -e "$PRM/$p" ] || { echo "В модуле нет $p — нужен лабораторный модуль 1124a"; exit 1; }
done
command -v glxgears >/dev/null || { echo "Нет glxgears — нагрузки не будет"; exit 1; }
[ -r "$BOX" ] && [ $(( $(date +%s) - $(stat -c %Y "$BOX") )) -le 5 ] || { echo "Чёрный ящик не пишет ($BOX) — признака зависания не будет (lab/blackbox.sh install)"; exit 1; }
if [ -z "${HOLD123_INH:-}" ]; then
    scr SetActive false >/dev/null; sleep 2
    exec env HOLD123_INH=1 gnome-session-inhibit --inhibit idle --inhibit suspend --reason "nouveau hold123" bash "$0" "$@"
fi
mkdir -p "$KIT/results"; OUT="$KIT/results/test123-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
# 28.11: след исполнения в файл (опыт 12:13 оборвался через 5 с без единой строки в итоге — причина не видна)
exec 9>"$OUT.trace"; BASH_XTRACEFD=9; PS4='+ $(date +%T) ${LINENO}: '; set -x
trap 'echo "$(date +%T) сигнал HUP" >> "$OUT"' HUP
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n 1')"
[ -n "$PS" ] || { echo "Нет debugfs pstate (sudo mount -t debugfs none /sys/kernel/debug)"; kill $KEEP; exit 1; }
ac()     { sudo cat "$PS" | grep -m1 '^AC:' | sed 's/^AC: *//'; }
pstate() { sudo sh -c "echo $1 > $PS"; }
lv()     { sudo cat "$PS" | grep -m1 "^$1:" | grep -oE "$2 [0-9]+ MHz"; }
LEVELS=($(sudo cat "$PS" | grep -oE '^[0-9a-f]{2}:' | tr -d ':')); BOT="${LEVELS[0]}"; TOP="${LEVELS[-1]}"
CB="$(lv "$BOT" core)"; MB="$(lv "$BOT" memory)"; CT="$(lv "$TOP" core)"; MT="$(lv "$TOP" memory)"
MID="${LEVELS[1]:-}"; CM="$(lv "${MID:-$BOT}" core)"
G0="$(cat $PRM/lab_gov)"; M0="$(cat $PRM/lab_mem)"; E0="$(cat $PRM/lab_eng_mask)"; X0="$(cat $PRM/lab_xbar 2>/dev/null || echo 0)"; XBAR="${XBAR:-}"; K0="$(cat $PRM/lab_hub07_khz 2>/dev/null || echo 0)"; XKHZ="${XKHZ:-}"
H60="$(cat $PRM/lab_hub06_khz 2>/dev/null || echo 0)"; H10="$(cat $PRM/lab_hub01_khz 2>/dev/null || echo 0)"; HKHZ="${HKHZ:-}"
# 28.11: OKERR — строки журнала, которые ошибкой опыта не считаются (например, при шине 135 МГц регистр порта шины
# 0x13c054 не читается, и чёрный ящик раз в секунду даёт строку об ошибке шины): OKERR='FAULT at 13c054'
OKERR="${OKERR:-^$}"
ERRPAT='Xid|FAULT|TRAP|DATA_ERROR|ТАЙМ-АУТ|не переключилась|отклон|failed to idle|SCHED_ERROR|ОСТАЛСЯ НА PLL|fifo: fault|killed|нет пути|не годится'
GP=""; HUNG=0; WHY=""; GEARS=/dev/null; H0=""; HS=0; GMIN=0; GMAX=0; T00="$(date '+%F %T')"

# Вернуть карту в обычный режим (только если GR жив): все узлы, память по уровням, регулятор как был
restore() {
    [ -n "$GP" ] && kill "$GP" 2>/dev/null; GP=""
    if [ "$(cat $PRM/lab_mem_only)" = Y ]; then    # ступень 4: ядро наверху, память внизу — обычный переход вернёт всё по уровню
        w lab_mem_only 0; w lab_mem 1; w lab_eng_mask 65535; pstate "$TOP"; sleep 2
    else                                            # ступени 1–3: ядро вниз всеми узлами; память и так внизу
        w lab_mem 1                                 # (ступень 7: память выше нижней частоты — спуск вернёт и её)
        w lab_eng_mask 65535; pstate "$BOT"; sleep 2
    fi
    w lab_eng_mask "$E0"; w lab_mem "$M0"; w lab_gov "$G0"; [ -n "$XBAR" ] && w lab_xbar "$X0"; [ -n "$XKHZ" ] && w lab_hub07_khz "$K0"; [ -n "$HKHZ" ] && { w lab_hub06_khz "$H60"; w lab_hub01_khz "$H10"; }
    say "ключи возвращены: lab_gov=$G0 lab_mem=$M0 lab_eng_mask=$E0; режим: $(ac)"
}
finish() { kill $KEEP 2>/dev/null; [ "$HUNG" = 0 ] && restore; sync; }
trap finish EXIT
trap 'say "прервано"; exit 1' INT TERM

# Стоянка: 0 — чисто, 2 — зависание, 1 — прочее (ошибка в журнале без зависания, пропала нагрузка). $1 — начало окна журнала
hold() {
    local t0=$SECONDS last=$SECONDS n0=0 n f e g
    GMIN=1000; GMAX=0; H0="$(date +%T)"; HS="$(date +%s)"
    while [ $((SECONDS - t0)) -lt "$HOLD" ]; do
        sleep 1
        n="$(wc -l < "$GEARS" 2>/dev/null || echo 0)"; [ "$n" != "$n0" ] && { n0="$n"; last=$SECONDS; }
        g="$(cat $PRM/lab_perf_gr 2>/dev/null || echo 0)"
        [ "$g" -lt "$GMIN" ] 2>/dev/null && GMIN="$g"; [ "$g" -gt "$GMAX" ] 2>/dev/null && GMAX="$g"
        if f="$(frozen)" && [ $((SECONDS - last)) -ge 15 ]; then
            WHY="GR застыл ($f), кадров нет $((SECONDS - last)) с; по ящику GR встал в $(hangtime "$f"), стоянка шла с $H0"; return 2
        fi
        if [ $(( (SECONDS - t0) % 10 )) -eq 0 ]; then
            e="$(sudo journalctl -k -b 0 --no-pager --since "$1" | grep -E "$ERRPAT" | grep -vE "$OKERR" | head -n 1 | sed -E 's/^.*kernel: //' | cut -c1-150)"
            if [ -n "$e" ]; then
                # Ошибка шины в журнале бывает следствием зависания: на 5-й секунде чёрный ящик читает регистры зависшего GR, и
                # ядро печатает старую отметку ошибки. Признаку «застыл» нужно 10 строк ящика — ждём его до 20 с и только тогда
                # решаем (25.11, опыт 123: без этого ожидания зависание на ступени 3 было принято за ошибку, ключи возвращены).
                for _ in $(seq 1 20); do frozen >/dev/null && break; sleep 1; done
                if f="$(frozen)"; then WHY="ошибка в журнале ($e), и GR застыл ($f); по ящику GR встал в $(hangtime "$f"), стоянка шла с $H0"; return 2; fi
                WHY="ошибка в журнале без признака зависания: $e"; return 1
            fi
        fi
        kill -0 "$GP" 2>/dev/null || { WHY="glxgears завершился сам"; return 1; }
        [ $((SECONDS - last)) -ge 30 ] && ! frozen >/dev/null && { WHY="нагрузка пропала: glxgears 30 с не выдаёт кадров, а GR не застыл"; return 1; }
    done
    return 0
}
# Улики по зависанию: только чтение. Снимок регистров — от чёрного ящика, а если он свой не сделал — lab/grsnap.py
evidence() {
    local d snap; d="$KIT/results/hang-$(date +%Y%m%d-%H%M)"; mkdir -p "$d"
    snap="$(sudo sh -c 'ls -t /var/log/gpu-blackbox/hang-*.txt 2>/dev/null | head -n 1')"
    if [ -n "$snap" ] && [ "$(sudo stat -c %Y "$snap")" -ge "$HS" ]; then
        sudo cat "$snap" > "$d/$(basename "$snap")"; say "    снимок регистров: чёрный ящик, $(basename "$snap")"
    elif sudo python3 -I "$LAB/grsnap.py" "опыт 123, ступень $1" > "$d/grsnap-$(date +%H%M%S).txt"; then
        say "    снимок регистров: снят сценарием (ящик свой не сделал)"
    else say "    снимок регистров не получился"; fi
    # 28.11: на каком шаге стоит прошивка GR (только чтение; 5 чтений через 0,5 с и ещё 5 через 10 с)
    if sudo python3 -I "$LAB/grstuck.py" 5 0.5 > "$d/grstuck.txt" 2>&1; then
        sleep 10; sudo python3 -I "$LAB/grstuck.py" 5 0.5 >> "$d/grstuck.txt" 2>&1
        grep -A8 '^ВЫВОД' "$d/grstuck.txt" | head -n 9 | sed 's/^/    прошивка GR: /' | tee -a "$OUT"
    else say "    grstuck.py не отработал: $(tail -n 1 "$d/grstuck.txt")"; fi
    tail -n 900 "$BOX" > "$d/blackbox-tail.txt"
    sudo journalctl -k -b 0 --no-pager -o short-precise --since "$T00" > "$d/journal.txt"
    cp "$OUT" "$OUT".gears* "$d/" 2>/dev/null
    say "    улики: $d"
}
# Разбор исхода стоянки. $1 — ступень, $2 — код hold, $3 — начало окна журнала
after() {
    local n="$1" rc="$2" e fps
    fps="$(grep -oE '= *[0-9.]+ FPS' "$GEARS" | grep -oE '[0-9.]+' | sort -n | sed -n '1p;$p' | tr '\n' ' ')"
    if [ "$rc" = 2 ]; then
        HUNG=1
        say "=== ЗАВИСАНИЕ на ступени $n: $WHY"
        say "    кадров/с glxgears до зависания (мин и макс за 5 с): ${fps:-нет}; загрузка GR $GMIN–$GMAX‰"
        evidence "$n"
        say "    Карту больше не трогаю: нагрузка оставлена, lab_gov=0, lab_mem=$(cat $PRM/lab_mem), lab_eng_mask=$(cat $PRM/lab_eng_mask). Нужен перезапуск розеткой."
        say "=== конец опыта 123: зависание на ступени $n"
        exit 2
    fi
    [ "$rc" = 0 ] || { say "    СТОП: $WHY"; return 1; }
    kill "$GP" 2>/dev/null; GP=""
    e="$(sudo journalctl -k -b 0 --no-pager --since "$3" | grep -E "$ERRPAT" | grep -cvE "$OKERR")"
    say "    итог ступени $n: чисто, $HOLD с (с $H0); кадров/с glxgears (мин и макс за 5 с): ${fps:-нет}; загрузка GR $GMIN–$GMAX‰; ошибок в журнале $e"
    [ "$e" = 0 ] || { sudo journalctl -k -b 0 --no-pager --since "$3" | grep -E "$ERRPAT" | grep -vE "$OKERR" | head -n 3 | sed -E 's/^.*kernel: //' | cut -c1-150 | tee -a "$OUT"; say "    СТОП"; return 1; }
    return 0
}
# Ступень 1–3. $1 — номер, $2 — маска узлов, $3 — узлы, которые обязаны остаться внизу, $4 — описание
step() {
    local n="$1" mask="$2" low="$3" T j names mux
    say "--- ступень $n: $4 (lab_eng_mask=$(printf '0x%04x' "$mask")), стоянка $HOLD с"
    w lab_eng_mask "$mask"; T="$(date '+%F %T')"
    pstate "$TOP"; sleep 2
    j="$(sudo journalctl -k -b 0 --no-pager --since "$T")"
    names="$(echo "$j" | grep -oE 'LAB calc [A-Za-z0-9]+\([0-9a-f]+\) dom [0-9]+: SKIPPED' | sed -E 's/LAB calc ([A-Za-z0-9]+)\(.*/\1/' | awk '!s[$0]++' | tr '\n' ' ' | sed 's/ $//')"
    mux="$(tail -n 40 "$BOX" | grep -oE '137100=[0-9a-f]+' | tail -n 1)"
    say "    узлы по журналу: $(echo "$j" | grep -oE 'LAB calc (XBAR2CLK|LTC2CLK|GPC2CLK|SYS2CLK|HUB2CLK)\([0-9a-f]+\) dom [0-9]+: want [0-9]+ got [0-9]+' | sed -E 's/LAB calc ([A-Z0-9]+)\(.*got ([0-9]+)/\1 \2 кГц/' | awk '!s[$0]++' | tr '\n' ';')"
    say "    порты шины XBAR после подъёма (ящик: 0x13c054/0x13c844/0x13ec14): $(tail -n 5 "$BOX" | grep -oE 'xbar=[0-9a-f/]+' | tail -n 1); lab_xbar=$(cat $PRM/lab_xbar 2>/dev/null)"
    say "    подъём: $(ac); не тронуты узлы: ${names:-нет} ($(echo "$j" | grep -oE 'stays [0-9]+ kHz \(wanted [0-9]+\)' | awk '!s[$0]++' | tr '\n' ' ' | sed 's/ $//')); переключатель источников $mux"
    echo "$j" | grep -qE 'LAB pstate [0-9]+: done ret 0' || { say "    СТОП: подъём не завершился с ret 0"; return 1; }
    echo "$j" | grep -q 'memory SKIPPED (lab_mem=0)' || { say "    СТОП: память не была пропущена"; return 1; }
    [ "$names" = "$low" ] || { say "    СТОП: внизу должны остаться «$low», а остались «$names»"; return 1; }
    case "$(ac)" in "$CT $MB"*) ;; *) say "    СТОП: ждали «$CT $MB»"; return 1;; esac
    GEARS="$OUT.gears$n"; stdbuf -oL glxgears > "$GEARS" 2>&1 & GP=$!
    hold "$T"; after "$n" $? "$T" || return 1
    w lab_eng_mask 65535; pstate "$BOT"; sleep 3
    case "$(ac)" in "$CB $MB"*) ;; *) say "    СТОП: после спуска ждали «$CB $MB», а стоит: $(ac)"; return 1;; esac
    return 0
}
# Ступень 5 (28.11): средний уровень целиком при памяти на нижней частоте — стоянка
step5() {
    local T j
    [ -n "$MID" ] && [ "$MID" != "$TOP" ] || { say "    СТОП: у карты нет среднего уровня"; return 1; }
    say "--- ступень 5: уровень $MID целиком (все узлы ядра) над памятью нижнего уровня, стоянка $HOLD с"
    w lab_eng_mask 65535; T="$(date '+%F %T')"
    pstate "$MID"; sleep 2
    j="$(sudo journalctl -k -b 0 --no-pager --since "$T")"
    say "    узлы: $(echo "$j" | grep -oE 'LAB calc (XBAR2CLK|LTC2CLK|GPC2CLK|SYS2CLK|HUB2CLK)\([0-9a-f]+\) dom [0-9]+: want [0-9]+ got [0-9]+' | sed -E 's/LAB calc ([A-Z0-9]+)\(.*got ([0-9]+)/\1 \2 кГц/' | awk '!s[$0]++' | tr '\n' ';')"
    say "    подъём: $(ac); порты шины XBAR (ящик): $(tail -n 5 "$BOX" | grep -oE 'xbar=[0-9a-f/]+' | tail -n 1)"
    echo "$j" | grep -qE 'LAB pstate [0-9]+: done ret 0' || { say "    СТОП: переход не завершился с ret 0"; return 1; }
    echo "$j" | grep -q 'memory SKIPPED (lab_mem=0)' || { say "    СТОП: память не была пропущена"; return 1; }
    case "$(ac)" in "$CM $MB"*) ;; *) say "    СТОП: ждали «$CM $MB»"; return 1;; esac
    GEARS="$OUT.gears5"; stdbuf -oL glxgears > "$GEARS" 2>&1 & GP=$!
    hold "$T"; after 5 $? "$T" || return 1
    pstate "$BOT"; sleep 3
    case "$(ac)" in "$CB $MB"*) ;; *) say "    СТОП: после спуска ждали «$CB $MB», а стоит: $(ac)"; return 1;; esac
    return 0
}
# Ступень 7 (28.11, вопрос владельца): шина МЕДЛЕННЕЕ памяти при быстром хабе. Нужен XKHZ (частота шины на верхнем уровне).
# Путь: обычный подъём на верхний уровень вместе с памятью — шина при этом сразу встаёт на заданную частоту, остальные
# узлы наверху; затем «только память» вниз до среднего уровня (этот режим драйвер включает только с верхнего уровня).
# Напряжение всё время верхнего уровня. Спуска отдельных узлов нет: при спуске драйвер снижает напряжение, а оставлять
# быстрые узлы на низком напряжении нельзя.
step7() {
    local T j MM
    [ -n "$XKHZ" ] || { say "    СТОП: ступени 7 нужен XKHZ"; return 1; }
    [ -n "$MID" ] && [ "$MID" != "$TOP" ] || { say "    СТОП: у карты нет среднего уровня"; return 1; }
    MM="$(lv "$MID" memory)"
    say "--- ступень 7: наверху всё, шина XBAR2CLK $XKHZ кГц, память на уровне $MID; стоянка $HOLD с"
    w lab_mem 1; w lab_eng_mask 65535; T="$(date '+%F %T')"; pstate "$TOP"; sleep 3
    j="$(sudo journalctl -k -b 0 --no-pager --since "$T")"
    say "    узлы по журналу: $(echo "$j" | grep -oE 'LAB calc (XBAR2CLK|LTC2CLK|GPC2CLK|SYS2CLK|HUB2CLK)\([0-9a-f]+\) dom [0-9]+: want [0-9]+ got [0-9]+' | sed -E 's/LAB calc ([A-Z0-9]+)\(.*got ([0-9]+)/\1 \2 кГц/' | awk '!s[$0]++' | tr '\n' ';')"
    case "$(ac)" in "$CT $MT"*) ;; *) say "    СТОП: уровень $TOP не встал: $(ac)"; return 1;; esac
    echo "$j" | grep -qE "LAB calc XBAR2CLK\\([0-9a-f]+\\) dom [0-9]+: want $XKHZ got" || { say "    СТОП: шина не получила заданную частоту"; return 1; }
    w lab_mem_only 1; pstate "$MID"; sleep 2; w lab_mem_only 0; w lab_mem 0
    case "$(ac)" in "$CT $MM"*) ;; *) say "    СТОП: ждали «$CT $MM» после шага «только память», а стоит: $(ac)"; w lab_mem 1; return 1;; esac
    say "    состояние: $(ac); переключатель источников $(tail -n 5 "$BOX" | grep -oE '137100=[0-9a-f]+' | tail -n 1)"
    GEARS="$OUT.gears7"; stdbuf -oL glxgears > "$GEARS" 2>&1 & GP=$!
    hold "$T"; after 7 $? "$T" || return 1
    w lab_mem 1; w lab_eng_mask 65535; pstate "$BOT"; sleep 3; w lab_mem 0
    case "$(ac)" in "$CB $MB"*) ;; *) say "    СТОП: после спуска ждали «$CB $MB», а стоит: $(ac)"; return 1;; esac
    return 0
}
# Ступень 4: путь части 5 опыта 122 — обычный подъём вместе с памятью, glxgears, «только память» вниз, стоянка
step4() {
    local T
    say "--- ступень 4: путь части 5 опыта 122 — обычный подъём на $TOP вместе с памятью, затем «только память» вниз; стоянка $HOLD с"
    w lab_mem 1; w lab_eng_mask 65535; T="$(date '+%F %T')"; pstate "$TOP"; sleep 3
    case "$(ac)" in "$CT $MT"*) ;; *) say "    СТОП: уровень $TOP не встал: $(ac)"; return 1;; esac
    w lab_mem_only 1
    GEARS="$OUT.gears4"; stdbuf -oL glxgears > "$GEARS" 2>&1 & GP=$!; sleep 2
    pstate "$BOT"; sleep 1
    say "    вход: $(ac); шагов повтора памяти с начала ступени: $(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -c 'LAB replay .*: выполнен за')"
    case "$(ac)" in "$CT $MB"*) ;; *) say "    СТОП: ждали «$CT $MB»"; return 1;; esac
    hold "$T"; after 4 $? "$T" || return 1
    return 0
}

say "опыт 123: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), $(sudo journalctl -k -b 0 --no-pager | grep -m1 -oE 'LAB build: .*'), загрузка $(uptime -s); стоянка $HOLD с, ступени: $STEPS"
say "уровни ${LEVELS[*]}: низ $BOT ($CB, $MB), верх $TOP ($CT, $MT); ключи при старте: lab_gov=$G0 lab_mem=$M0 lab_eng_mask=$E0 lab_nv_xbarmem=$(cat $PRM/lab_nv_xbarmem) lab_order=$(cat $PRM/lab_order)"
a="$(scr GetActive)"; say "экран погашен: $a"
case "$a" in *false*) ;; *) say "СТОП: экран не разбудился — нагрузки не будет"; exit 1;; esac
[ -n "$XBAR" ] && { w lab_xbar "$XBAR"; say "ключ lab_xbar на время опыта: $XBAR (был $X0)"; }
if [ -n "$XKHZ" ]; then
    [[ "$XKHZ" =~ ^[0-9]+$ ]] && [ "$XKHZ" -ge 100000 ] && [ "$XKHZ" -le 1907000 ] || { say "СТОП: XKHZ — частота шины в кГц, от 100000 до 1907000"; exit 1; }
    w lab_hub07_khz "$XKHZ"; say "частота шины XBAR2CLK на верхнем уровне на время опыта: $XKHZ кГц (ключ lab_hub07_khz, был $K0)"
fi
if [ -n "$HKHZ" ]; then
    [[ "$HKHZ" =~ ^[0-9]+$ ]] && [ "$HKHZ" -ge 600000 ] && [ "$HKHZ" -le 1645000 ] || { say "СТОП: HKHZ — частота хаба в кГц, от 600000 до 1645000"; exit 1; }
    w lab_hub06_khz "$HKHZ"; w lab_hub01_khz "$HKHZ"
    say "частота SYS2CLK и HUB2CLK на верхнем уровне на время опыта: $HKHZ кГц (ключи lab_hub06_khz, lab_hub01_khz; были $H60, $H10)"
fi
w lab_gov 0; w lab_mem 1; w lab_eng_mask 65535; pstate "$BOT"; sleep 3
# 28.11: если память осталась выше нижней частоты (после прерванной ступени 7 драйвер считает, что уровень уже нижний,
# и ничего не делает), сходить на средний уровень и обратно — спуск вернёт память
case "$(ac)" in "$CB $MB"*) ;; *) [ -n "$MID" ] && { say "память не на нижней частоте ($(ac)) — возвращаю через уровень $MID"; pstate "$MID"; sleep 3; pstate "$BOT"; sleep 3; };; esac
case "$(ac)" in "$CB $MB"*) ;; *) say "СТОП: исходный уровень $BOT не встал: $(ac)"; exit 1;; esac
w lab_mem 0
say "исходное состояние: уровень $BOT целиком ($(ac)); дальше память не меняется (lab_mem=0)"
if [ -r "$LAB/grstuck.py" ]; then     # 28.11: то же чтение на живой карте — с чем сравнивать снимок после зависания
    sudo python3 -I "$LAB/grstuck.py" 20 0.05 > "$OUT.grstuck-before" 2>&1
    grep -A6 '^ВЫВОД' "$OUT.grstuck-before" | head -n 7 | sed 's/^/    прошивка GR до опыта: /' | tee -a "$OUT"
fi
for s in $STEPS; do
    case "$s" in
        1) step 1 $((0xfff9)) "LTC2CLK XBAR2CLK" "наверху всё, кроме LTC2CLK и XBAR2CLK" ;;
        2) step 2 $((0xfffb)) "XBAR2CLK" "добавлен LTC2CLK, внизу один XBAR2CLK (проход NVIDIA на подъёме)" ;;
        3) step 3 $((0xffff)) "" "добавлен XBAR2CLK, наверху всё (наш проход по умолчанию)" ;;
        4) step4 ;;
        5) step5 ;;
        7) step7 ;;
        6) step 6 $((0xfeff)) "HUB2CLK" "наверху всё, включая шину XBAR2CLK, внизу один HUB2CLK" ;;
        *) say "СТОП: нет ступени «$s»"; false ;;
    esac || { say "=== конец опыта 123: остановлен на ступени $s без зависания"; exit 1; }
done
say "=== конец опыта 123: зависаний нет, ступени $STEPS чисты"
