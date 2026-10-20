#!/bin/bash
# ЛАБОРАТОРИЯ: опыты с частотами карты. НЕ для повседневной работы.
#   lab.sh install   — собрать и поставить экспериментальный драйвер (исправление гонки +
#                      разрешение смены частот + подробные сообщения "LAB ..." в журнале).
#                      Стабильный драйвер сохраняется в резервную копию.
#   lab.sh pstate 07 — переключить карту в режим 07 (или 0f, 03). Действует до перезагрузки.
#                      Результат пишется в ~/nouveau-fix/results/ и сразу сбрасывается на диск.
#   lab.sh try 07 0f — ОПЫТ СО СТРАХОВКОЙ: по очереди переключает режимы и после каждого ждёт
#                      15 с, пока ты нажмёшь Enter («вижу экран»). Нет нажатия → возвращает 03;
#                      снова нет → сам сохраняет журнал и перезагружает компьютер.
#   lab.sh exp A|B|C|D [07|0f] — опыты «по одному параметру», каждый = try <режим> 03 (по умолчанию 0f):
#                      A — только напряжение; B — напряжение + память; C — напряжение + ядро;
#                      D — всё вместе (напряжение поднимается первым).
#   lab.sh exp E|F [07|0f] — «только ядро» по рецепту twilight0, карта ОСТАЁТСЯ в режиме для нагрузки:
#                      E — ядро без узлов вывода (hub), напряжение по таблице карты;
#                      F — то же + напряжение не ниже 1,075 В (как у самой карты в 0f).
#   lab.sh load [мин] — тяжёлая нагрузка glmark2 1600x900 (по умолчанию 10 мин) с записью в results/.
#   lab.sh bench 03 07 0f — замер: в каждом режиме ~1 мин glmark2, счёт, температура, реальные частоты.
#                      HEAVY=1 перед командой — тяжёлый замер (окно 1600x900, сцены, нагружающие карту).
#   lab.sh at ЯДРО ROP [HUB07 HUB06 HUB01] — свои частоты в МГц (0 = узел не трогать): ставит их,
#                      переключает в 0f, делает замер, затем возвращает 07 по таблице карты.
#                      Выше заводских значений 0f драйвер не поднимет (1800/1907/1907/1645/1645).
#   lab.sh ladder [N] — ЛЕСТНИЦА: все узлы, кроме памяти, по ступенькам от меньшего риска к большему.
#                      DIRECT=1 перед командой — каждая ступенька прыжком 03 → 0f, без промежуточного 07.
#   lab.sh table 07|0f [мин] — режим ЦЕЛИКОМ по заводской таблице BIOS (все узлы), замер + нагрузка.
#   lab.sh hold ЯДРО ROP [HUB07 HUB06 HUB01] — поставить свои частоты в 0f и оставить (для чтения регистров).
#   lab.sh home      — вернуть рабочий 07 (ядро/ROP 810, hub на стартовых), lab_gpc_fix = 0.
#   GPCCOEF=0x00PPNNMM [GPCREF=кГц] перед at/hold — PLL ядра с заданными коэффициентами (опора по гипотезе).
#   GPCFIX=1|2|3|4 перед at/hold — опыт с PLL ядра (1: снять 0x1000 в 0x137120 до переключения;
#                      2: снять 0x200000 в 0x137008; 4: снять 0x1000 ПОСЛЕ переключения на PLL). В at — только на шаге 2.
#   GPCSEQ=биты перед at/hold/calib — PLL как у NVIDIA 390: 1 ядро без бита 0x10; 2 ядро 0x1371d0=..06 до PLL;
#                      4 ВСЕ PLL без бита 0x10; 8 опора PLL hubk06 через его делитель (405). Пример: GPCSEQ=13.
#   ALU=1 [ALUSTEPS=2000] перед bench/at/calib — честный замер ядра (цикл вычислений вне экрана), важнее CORE=1.
#   lab.sh mem07     — ПАМЯТЬ 135 -> 324 (03 -> 07) повтором скрипта NVIDIA, снимки до/после и сравнение с NVIDIA.
#   lab.sh mem0f     — ПАМЯТЬ 324 -> 2004 (07 -> 0f, узлы как в H11) повтором скрипта NVIDIA; только после mem07.
#   lab.sh memdown 07|03 — ПАМЯТЬ ВНИЗ (2004 -> 324 или 324 -> 135) повтором скриптов NVIDIA.
#   lab.sh memcycle [N] — N циклов всех переходов с памятью (03/07/0f, вверх, вниз и прыжками).
#   lab.sh calib [МГц …] — калибровка ядра: скорость вычислений на заданных частотах (по умолчанию 8 точек).
#   lab.sh pllcmp    — ядро на одинаковой частоте через делитель и через PLL (P = 1, 2, 3, 4).
#   lab.sh flags     — показать текущие переключатели лабораторного драйвера.
#   lab.sh disp 0|1|2 — как ставить на паузу вывод изображения при смене частоты памяти.
#   lab.sh restore   — вернуть стабильный драйвер из резервной копии (потом перезагрузка).
# Частота сама НЕ поднимается: после перезагрузки карта всегда на исходных 50 МГц.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(dirname "$HERE")"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
SLOT="/lib/modules/$KVER/updates/nouveau-fix/nouveau.ko"
BACKUP="$HOME/nouveau-build/stable-$KVER-nouveau.ko"
WORK="$HOME/nouveau-build/lab-$KVER"

preflight() {  # $1 = ожидаемая маска, $2..$6 = ожидаемые частоты gpc rop hub07 hub06 hub01 (кГц)
    local P=/sys/module/nouveau/parameters ok=1 a
    chk() { a="$(cat "$P/$1" 2>/dev/null || echo НЕТ)"
            if [ "$a" = "$2" ]; then printf '  ✓ %-16s = %s\n' "$1" "$a"; else printf '  ✗ %-16s = %s (нужно %s)\n' "$1" "$a" "$2"; ok=0; fi; }
    echo "--- Проверка окружения ---"
    echo "  скрипт lab.sh: $(md5sum "$0" | cut -c1-8)"
    if [ "$(modinfo -n nouveau)" = "$SLOT" ] && [ -e "$P/lab_gpc_khz" ]; then echo "  ✓ лабораторный драйвер загружен"; else echo "  ✗ лабораторный драйвер НЕ загружен"; ok=0; fi
    chk lab_mem N; chk lab_pcie N; chk lab_core Y; chk lab_volt_first Y; chk lab_volt_min_uv 0
    chk lab_eng_mask "$1"; chk lab_gpc_khz "$2"; chk lab_rop_khz "$3"
    chk lab_hub07_khz "$4"; chk lab_hub06_khz "$5"; chk lab_hub01_khz "$6"
    if [ -e "$P/lab_gpc_ref_khz" ]; then chk lab_gpc_ref_khz "${EXPREF:-0}"; elif [ "${EXPREF:-0}" != 0 ]; then echo "  ✗ lab_gpc_ref_khz нет в драйвере (нужен lab.sh install)"; ok=0; fi
    if [ -e "$P/lab_gpc_coef" ]; then chk lab_gpc_coef "${EXPCOEF:-0}"; elif [ "${EXPCOEF:-0}" != 0 ]; then echo "  ✗ lab_gpc_coef нет в драйвере (нужен lab.sh install)"; ok=0; fi
    if [ -e "$P/lab_gpc_fix" ]; then chk lab_gpc_fix "${EXPFIX:-0}"; elif [ "${EXPFIX:-0}" != 0 ]; then echo "  ✗ lab_gpc_fix нет в драйвере (нужен lab.sh install)"; ok=0; fi
    if [ -e "$P/lab_gpc_seq" ]; then chk lab_gpc_seq "${EXPSEQ:-0}"; elif [ "${EXPSEQ:-0}" != 0 ]; then echo "  ✗ lab_gpc_seq нет в драйвере (нужен lab.sh install)"; ok=0; fi
    if [ "$(sysctl -n kernel.hardlockup_panic 2>/dev/null)" = 1 ] && lsmod | grep -q '^ramoops'; then echo "  ✓ ловушка: ramoops + остановка при жёстком зависании"
    else echo "  ✗ ловушка не готова (нужно: sudo sysctl -w kernel.hardlockup_panic=1)"; ok=0; fi
    [ -z "$(sudo ls -A /var/lib/systemd/pstore 2>/dev/null)" ] || echo "  ⚠ в /var/lib/systemd/pstore лежит старый улов — сохрани его, иначе перепутаем"
    [ -w "$KIT/results" ] && echo "  ✓ results/ доступна для записи" || { echo "  ✗ results/ недоступна"; ok=0; }
    echo "  режим сейчас: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    [ "$ok" = 1 ] || { echo "--- СТОП: окружение не то. Опыт не запускаю."; exit 1; }
    echo "--- Окружение верное"
}

case "${1:-}" in
install)
    command -v git >/dev/null || { echo "Нет git: sudo apt install git"; exit 1; }
    [ -e "$KBUILD/Makefile" ] || { echo "Нет заголовков ядра: sudo apt install linux-headers-$KVER"; exit 1; }
    UPV="$(make -s -C "$KBUILD" kernelversion 2>/dev/null | tail -n 1 || true)"
    if ! [[ "$UPV" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        MF="/usr/src/linux-headers-${KVER%-generic}/Makefile"; [ -r "$MF" ] || MF="$KBUILD/Makefile"
        UPV="$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{if(v!="") print v"."p"."s}' "$MF")"
    fi
    TAG="v${UPV%.0}"
    echo "=== Ядро $KVER, основа Linux $UPV"
    rm -rf "$WORK"; mkdir -p "$WORK"
    git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$TAG" https://github.com/gregkh/linux.git "$WORK/src"
    git -C "$WORK/src" sparse-checkout set drivers/gpu/drm/nouveau
    git -C "$WORK/src" checkout -q
    cp -r "$WORK/src/drivers/gpu/drm/nouveau" "$WORK/nouveau"; rm -rf "$WORK/src"
    cd "$WORK/nouveau"
    git apply -p1 "$KIT/patches/0001-nouveau-abi16-idle-channel-before-engobj-del.patch"
    git apply -p1 "$HERE/0002-LAB-fermi-reclock-instrumented.patch"
    echo "=== Исправление гонки + лабораторный патч наложены. Собираю (несколько минут)..."
    if ! make -C "$KBUILD" M="$WORK/nouveau" -j"$(nproc)" modules > "$WORK/build.log" 2>&1; then
        echo "Сборка НЕ удалась, ничего не установлено. Лог: $WORK/build.log"; tail -n 20 "$WORK/build.log"; exit 3
    fi
    if [ ! -e "$BACKUP" ]; then
        [ -e "$SLOT" ] || { echo "Нет стабильного драйвера в $SLOT. Сначала запусти ~/nouveau-fix/rebuild.sh"; exit 1; }
        cp "$SLOT" "$BACKUP"
        echo "=== Стабильный драйвер сохранён: $BACKUP"
    fi
    read -r -p "Поставить ЛАБОРАТОРНЫЙ драйвер вместо стабильного? Пароль. [y/N] " ans
    case "$ans" in y|Y|д|Д) ;; *) echo "Не ставлю."; exit 0 ;; esac
    sudo install -m 644 "$WORK/nouveau/nouveau.ko" "$SLOT"
    sudo depmod -a "$KVER"; sudo update-initramfs -u -k "$KVER"
    echo "=== Готово. Перезагрузись. Вернуть стабильный: ~/nouveau-fix/lab/lab.sh restore"
    ;;
pstate)
    P="${2:-}"; [[ "$P" =~ ^(03|07|0f)$ ]] || { echo "Укажи режим: 03, 07 или 0f"; exit 1; }
    mkdir -p "$KIT/results"
    OUT="$KIT/results/pstate-$P-$(date +%Y%m%d-%H%M%S).txt"
    echo "Переключаю карту в режим $P. Если экран встанет: Alt+PrtSc, затем S, U, B."
    sudo sh -c "f=\$(ls /sys/kernel/debug/dri/*/pstate | head -n1); echo $P > \"\$f\"; cat \"\$f\" > '$OUT'; sync"
    cat "$OUT"
    ;;
disp)
    M="${2:-}"; [[ "$M" =~ ^[012]$ ]] || { echo "Режим паузы дисплея: 0 (не трогать), 1 (снять биты 0x30), 2 (чужое 0x3300)"; exit 1; }
    sudo sh -c "echo $M > /sys/module/nouveau/parameters/lab_disp_pause"
    echo "lab_disp_pause = $(cat /sys/module/nouveau/parameters/lab_disp_pause)"
    ;;
flags|exp)
    PRM=/sys/module/nouveau/parameters
    [ -e "$PRM/lab_core" ] || { echo "Лабораторный драйвер не загружен (нет $PRM/lab_core). Сначала: lab.sh install и перезагрузка."; exit 1; }
    if [ "$1" = flags ]; then
        for f in lab_pcie lab_mem lab_core lab_volt_first lab_disp_pause lab_eng_mask lab_volt_min_uv; do [ -e "$PRM/$f" ] && echo "$f = $(cat "$PRM/$f")"; done
        exit 0
    fi
    E="${2:-}"
    case "$E" in
        A) F="0 0 0 1 65535 0"; D="только напряжение (без PCIe, памяти и ядра)";;
        B) F="0 1 0 1 65535 0"; D="напряжение + память";;
        C) F="0 0 1 1 65535 0"; D="напряжение + ядро";;
        D) F="1 1 1 1 65535 0"; D="всё: PCIe + напряжение + память + ядро";;
        E) F="0 0 1 1 65147 0"; D="только ядро, узлы вывода (hub) не трогаем, напряжение по таблице";;
        F) F="0 0 1 1 65147 1075000"; D="только ядро без hub + напряжение не ниже 1,075 В";;
        *) echo "Укажи опыт: A, B, C, D, E или F"; exit 1;;
    esac
    [ -e "$PRM/lab_eng_mask" ] || { echo "Загружен старый лабораторный драйвер без lab_eng_mask. Сначала: lab.sh install и перезагрузка."; exit 1; }
    T="${3:-0f}"; [[ "$T" =~ ^(07|0f)$ ]] || { echo "Режим опыта: 07 или 0f"; exit 1; }
    [ "$(id -u)" -eq 0 ] || exec sudo "$0" exp "$E" "$T"
    read -r PC ME CO VF EM VM <<<"$F"
    echo "$PC" > "$PRM/lab_pcie"; echo "$ME" > "$PRM/lab_mem"
    echo "$CO" > "$PRM/lab_core"; echo "$VF" > "$PRM/lab_volt_first"
    echo "$EM" > "$PRM/lab_eng_mask"; echo "$VM" > "$PRM/lab_volt_min_uv"
    echo "=== Опыт $E ($T): $D"
    for f in lab_pcie lab_mem lab_core lab_volt_first lab_eng_mask lab_volt_min_uv; do echo "    $f = $(cat "$PRM/$f")"; done
    case "$E" in
        E|F) echo "=== Карта останется в режиме $T. Дальше нагрузка: ~/nouveau-fix/lab/lab.sh load"
             exec "$0" try "$T" ;;
        *)   exec "$0" try "$T" 03 ;;
    esac
    ;;
try)
    # Опыт со страховкой: переключить режим(ы) и ждать подтверждения «вижу экран».
    # Нет подтверждения → вернуть 03; всё ещё нет → сохранить журнал и перезагрузиться самому.
    shift
    [ "$#" -ge 1 ] || { echo "Укажи режимы, например: lab.sh try 07 0f"; exit 1; }
    for P in "$@"; do [[ "$P" =~ ^(03|07|0f)$ ]] || { echo "Неизвестный режим: $P"; exit 1; }; done
    [ "$(id -u)" -eq 0 ] || exec sudo "$0" try "$@"
    mkdir -p "$KIT/results"
    RES="$KIT/results/try-$(date +%Y%m%d-%H%M%S).txt"
    PS="$(ls /sys/kernel/debug/dri/*/pstate | head -n 1)"
    note() { echo "$(date +%T) $*" | tee -a "$RES"; [ -w /dev/pmsg0 ] && echo "LABTRY $(date +%T) $*" > /dev/pmsg0 2>/dev/null; sync; }
    temp() {  # температура GPU и вентилятор (если драйвер их сообщает)
        local h; h="$(ls -d /sys/class/drm/card*/device/hwmon/hwmon* 2>/dev/null | head -n 1)"
        [ -n "$h" ] || { echo "датчик не найден"; return; }
        echo "GPU $(( $(cat "$h/temp1_input" 2>/dev/null || echo 0) / 1000 ))°C, вентилятор $(cat "$h/fan1_input" 2>/dev/null || echo '?') об/мин, pwm $(cat "$h/pwm1" 2>/dev/null || echo '?')"
    }
    confirm() {  # $1 = секунды
        local n
        echo
        echo ">>> ЕСЛИ ТЫ ВИДИШЬ ЭТОТ ТЕКСТ — НАЖМИ Enter (есть $1 с) <<<"
        # Сбросить случайно нажатое заранее.
        while read -r -t 0.1 -n 10000 _; do :; done
        for ((n=$1; n>0; n--)); do
            printf '\r  осталось %2d с ' "$n"
            if read -r -t 1 _; then echo; return 0; fi
        done
        echo; return 1
    }
    rescue() {
        note "НЕТ ПОДТВЕРЖДЕНИЯ после режима $1. Пробую вернуть режим 03."
        ( echo 03 > "$PS" ) & sleep 8
        if confirm 15; then
            note "Возврат в 03 спас ситуацию. Режим 03 сейчас: $(grep '^AC' "$PS" 2>/dev/null)"
            exit 0
        fi
        note "Карта не отвечает. Сохраняю журнал и перезагружаюсь сам."
        timeout 15 journalctl -k -b 0 --no-pager -o short-precise 2>/dev/null \
            | grep -E 'LAB|nouveau|WARNING|timeout' | tail -n 400 >> "$RES" || true
        sync; sleep 2
        echo s > /proc/sysrq-trigger; sleep 3
        echo u > /proc/sysrq-trigger; sleep 3
        echo b > /proc/sysrq-trigger
        exit 1
    }
    if [ -w /dev/pmsg0 ]; then  # «чёрный ящик» (trap.sh): журнал ядра на лету в память, переживающую Reset
        dmesg -W > /dev/pmsg0 2>/dev/null & PM=$!
        trap 'kill $PM 2>/dev/null || true' EXIT
        note "Чёрный ящик: журнал пишется в /dev/pmsg0"
    fi
    note "Опыт: режимы $* (драйвер: $(modinfo -n nouveau))"
    for f in /sys/module/nouveau/parameters/lab_*; do [ -e "$f" ] && note "  $(basename "$f") = $(cat "$f")"; done
    note "Исходно: $(grep '^AC' "$PS"); $(temp)"
    for P in "$@"; do
        note "Переключаю в режим $P..."
        ( echo "$P" > "$PS" ) &
        W=$!
        for i in $(seq 1 20); do kill -0 "$W" 2>/dev/null || break; sleep 1; done
        kill -0 "$W" 2>/dev/null && note "Команда переключения всё ещё выполняется спустя 20 с."
        note "Сейчас: $(timeout 5 grep '^AC' "$PS" 2>/dev/null || echo 'не читается'); $(timeout 5 bash -c "$(declare -f temp); temp")"
        confirm 15 || rescue "$P"
        note "Режим $P: экран живой, подтверждено. $(temp)"
    done
    note "Все режимы прошли. Карта остаётся в режиме ${*: -1} до перезагрузки."
    echo "Результат: $RES"
    ;;
load)
    # Нагрузка для проверки стабильности в текущем режиме. Запускать БЕЗ sudo.
    M="${2:-10}"; [[ "$M" =~ ^[0-9]+$ ]] || { echo "Укажи минуты числом"; exit 1; }
    command -v glmark2-wayland >/dev/null || command -v glmark2 >/dev/null || { echo "Нет glmark2: sudo apt install glmark2-wayland"; exit 1; }
    G="$(command -v glmark2-wayland || command -v glmark2)"
    mkdir -p "$KIT/results"; [ -w "$KIT/results" ] || { echo "Папка results принадлежит root. Выполни: sudo chown -R $USER: $KIT/results"; exit 1; }
    OUT="$KIT/results/load-$(date +%Y%m%d-%H%M%S).txt"
    PS="$(ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n 1 || true)"
    { echo "Нагрузка $M мин (ТЯЖЁЛАЯ: 1600x900, 5 сцен по кругу), начало $(date +%T)"; sudo -n cat "$PS" 2>/dev/null | grep '^AC' || true; } | tee "$OUT"; sync
    END=$(( $(date +%s) + M * 60 )); N=0
    while [ "$(date +%s)" -lt "$END" ]; do
        N=$((N+1)); echo "$(date +%T) прогон $N" | tee -a "$OUT"; sync
        # Тяжёлая нагрузка: окно 1600x900, те же 5 тяжёлых сцен, что в HEAVY-замере, по кругу.
        "$G" --run-forever -s 1600x900 -b shading:shading=phong -b bump:bump-render=high-poly -b effect2d:kernel=0,1,0\;1,-4,1\;0,1,0\; -b shadow -b refract >/dev/null 2>&1 & GP=$!
        sleep 60; kill "$GP" 2>/dev/null || true; wait "$GP" 2>/dev/null || true
        H="$(ls -d /sys/class/drm/card*/device/hwmon/hwmon* 2>/dev/null | head -n 1)"
        [ -n "$H" ] && echo "    GPU $(( $(cat "$H/temp1_input" 2>/dev/null || echo 0) / 1000 ))°C" | tee -a "$OUT"; sync
    done
    echo "$(date +%T) Нагрузка $M мин пройдена без зависания ✅" | tee -a "$OUT"; sync
    ;;
bench)
    # Сравнение режимов. Переключатели лабораторного драйвера (опыт E/F) должны быть уже выставлены.
    shift; [ "$#" -ge 1 ] || set -- 03 07 0f
    for P in "$@"; do [[ "$P" =~ ^(03|07|0f)$ ]] || { echo "Неизвестный режим: $P"; exit 1; }; done
    G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "Нет glmark2"; exit 1; }
    mkdir -p "$KIT/results"; [ -w "$KIT/results" ] || { echo "Выполни: sudo chown -R $USER: $KIT/results"; exit 1; }
    OUT="$KIT/results/bench-$(date +%Y%m%d-%H%M%S).txt"
    if [ "$(cat /sys/module/nouveau/parameters/lab_mem 2>/dev/null)" = Y ] && [[ " $* " == *" 0f "* || " $* " == *" 07 "* ]]; then
        echo "СТОП: lab_mem=Y — смена режима потащит за собой память, а она у нас вешает систему."
        echo "Сначала выставь опыт: lab.sh exp E 07 (или используй lab.sh at ...)."; exit 1
    fi
    sudo -v
    PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
    H="$(ls -d /sys/class/drm/card*/device/hwmon/hwmon* 2>/dev/null | head -n 1)"
    t() { [ -n "$H" ] && echo "$(( $(cat "$H/temp1_input" 2>/dev/null || echo 0) / 1000 ))°C" || echo "?"; }
    { echo "Замер $(date '+%F %T') ($([ "${ALU:-0}" = 1 ] && echo "ЧЕСТНОЕ ЯДРО: цикл ${ALUSTEPS:-2000} шагов, вне экрана" || { [ "${CORE:-0}" = 1 ] && echo 'ЯДРО: 400x300, вычисления'; } || { [ "${QUICK:-0}" = 1 ] && echo 'БЫСТРЫЙ ТЯЖЁЛЫЙ, 1600x900, 3 сцены' || { [ "${HEAVY:-0}" = 1 ] && echo 'ТЯЖЁЛЫЙ, 1600x900' || echo 'обычный, 800x600'; }; }))"; for f in /sys/module/nouveau/parameters/lab_*; do echo "  $(basename "$f") = $(cat "$f")"; done; } | tee "$OUT"
    for P in "$@"; do
        sudo sh -c "echo $P > $PS"; sleep 3
        echo "=== Режим $P: $(sudo grep '^AC' "$PS"), $(t)" | tee -a "$OUT"; sync
        if [ "${ALU:-0}" = 1 ]; then  # ЧЕСТНЫЙ замер ядра: тяжёлый цикл вычислений, вне экрана — кадров мало, память почти не нужна
            GA=(--off-screen -s 400x300 -b "loop:fragment-steps=${ALUSTEPS:-2000}:fragment-loop=true")
        elif [ "${CORE:-0}" = 1 ]; then  # замер ЯДРА: маленькое окно, чистые вычисления, память почти не нужна
            GA=(-s 400x300 -b loop:fragment-steps=20:fragment-loop=true -b function:fragment-steps=20:fragment-complexity=high)
        elif [ "${QUICK:-0}" = 1 ]; then  # быстрый тяжёлый замер для лестницы: 3 сцены, ~30 с
            GA=(-s 1600x900 -b shading:shading=phong -b effect2d:kernel=0,1,0\;1,-4,1\;0,1,0\; -b refract)
        elif [ "${HEAVY:-0}" = 1 ]; then  # тяжёлый замер: большое окно, сцены, упирающиеся в карту
            GA=(-s 1600x900 -b shading:shading=phong -b bump:bump-render=high-poly -b effect2d:kernel=0,1,0\;1,-4,1\;0,1,0\; -b shadow -b refract)
        else
            GA=(-b build:use-vbo=true -b texture -b shading:shading=phong -b refract -b desktop)
        fi
        SC="$("$G" "${GA[@]}" 2>&1 | tee -a "$OUT" | grep -o 'Score: [0-9]*' | tail -n 1)"
        [ -n "$SC" ] || echo "!!! glmark2 не выдал счёт — см. полный вывод (возможно, нет --off-screen)" | tee -a "$OUT"
        echo "=== Режим $P: glmark2 $SC, после теста $(t)" | tee -a "$OUT"; sync
    done
    echo; grep '^=== ' "$OUT"
    echo "Карта осталась в режиме ${*: -1}. Полный вывод: $OUT"
    ;;
at)
    shift; [ "$#" -ge 2 ] || { echo "Пример: lab.sh at 1080 810   (ядро и ROP в МГц; 0 = не трогать)"; exit 1; }
    PRM=/sys/module/nouveau/parameters
    [ -e "$PRM/lab_gpc_khz" ] || { echo "Нужен новый лабораторный драйвер: lab.sh install и перезагрузка."; exit 1; }
    for v in "$@"; do [[ "$v" =~ ^[0-9]+$ ]] || { echo "Частоты числами в МГц"; exit 1; }; done
    NAMES=(gpc rop hub07 hub06 hub01); BITS=(1 2 4 128 256)
    MASK=$((0xffff & ~(1|2|4|128|256)))   # все узлы, кроме ядра, ROP и hub — их включаем по запросу
    A=("$@" 0 0 0 0 0)
    for i in 0 1 2 3 4; do [ "${A[$i]}" -gt 0 ] && MASK=$((MASK | BITS[i])); done
    sudo -v
    # Шаг 0: только ядро/узлы — память и PCIe НЕ трогаем, напряжение первым, свои частоты сброшены.
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv"
    [ -e "$PRM/lab_gpc_fix" ] && sudo sh -c "echo ${EXPFIX:-0} > $PRM/lab_gpc_fix"
    [ -e "$PRM/lab_gpc_seq" ] && sudo sh -c "echo ${EXPSEQ:-0} > $PRM/lab_gpc_seq"
    [ -e "$PRM/lab_gpc_coef" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_coef"
    [ -e "$PRM/lab_gpc_ref_khz" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_ref_khz"
    for n in "${NAMES[@]}"; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 65147 > $PRM/lab_eng_mask"
    echo "=== Шаг 1: контрольный замер в 07 по таблице (ядро/ROP 810, hub не трогаем)"
    preflight 65147 0 0 0 0 0
    # Драйвер не перестраивает частоты, если режим не меняется, поэтому 07 «с нуля» — через 03.
    "$0" pstate 03 >/dev/null
    if [ "${DIRECT:-0}" = 1 ]; then echo "    ПРЯМОЙ ПРЫЖОК: остаёмся в 03, в 0f пойдём прямо отсюда (без 07)"
    elif [ "${NOCONTROL:-0}" = 1 ]; then "$0" pstate 07 >/dev/null; echo "    (контрольный замер пропущен — он сделан в начале лестницы)"; else "$0" bench 07; fi
    # Шаг 2: свои частоты и переход в 0f.
    for i in 0 1 2 3 4; do sudo sh -c "echo $((A[i]*1000)) > $PRM/lab_${NAMES[$i]}_khz"; done
    sudo sh -c "echo $MASK > $PRM/lab_eng_mask"
    if [ "${GPCFIX:-0}" != 0 ]; then EXPFIX="$GPCFIX"; sudo sh -c "echo $EXPFIX > $PRM/lab_gpc_fix"; echo "=== Опыт с битами PLL ядра: lab_gpc_fix = $EXPFIX"; fi
    if [ "${GPCSEQ:-0}" != 0 ]; then [ -e "$PRM/lab_gpc_seq" ] || { echo "Нет lab_gpc_seq: нужен lab.sh install и перезагрузка"; exit 1; }; EXPSEQ="$GPCSEQ"; sudo sh -c "echo $EXPSEQ > $PRM/lab_gpc_seq"; echo "=== PLL ядра как у NVIDIA: lab_gpc_seq = $EXPSEQ"; fi
    if [ -n "${GPCREF:-}" ]; then EXPREF=$((GPCREF)); sudo sh -c "echo $EXPREF > $PRM/lab_gpc_ref_khz"; echo "=== PLL ядра: опора по гипотезе $GPCREF кГц"; fi
    if [ -n "${GPCCOEF:-}" ]; then EXPCOEF=$((GPCCOEF)); sudo sh -c "echo $EXPCOEF > $PRM/lab_gpc_coef"; echo "=== PLL ядра: принудительно коэффициенты $GPCCOEF"; fi
    echo "=== Шаг 2: 0f со своими частотами: ядро ${A[0]} МГц, ROP ${A[1]} МГц, hub ${A[2]}/${A[3]}/${A[4]} МГц (0 = не трогаем)"
    preflight "$MASK" $((A[0]*1000)) $((A[1]*1000)) $((A[2]*1000)) $((A[3]*1000)) $((A[4]*1000))
    [ "${NOCONFIRM:-0}" = 1 ] || read -r -p "Всё верно? Enter — запустить, Ctrl+C — отмена " _
    "$0" bench 0f || true
    # Шаг 3: обратно в 07 по таблице. Сначала 03 — там таблица карты = стартовые частоты hub,
    # и тронутые в опыте hub разрешено перестроить (иначе они остались бы на опытных частотах).
    for n in "${NAMES[@]}"; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    RM=65147; for i in 2 3 4; do [ "${A[$i]}" -gt 0 ] && RM=$((RM | BITS[i])); done
    echo "=== Шаг 3: возвращаю 03 (hub на стартовые), затем 07 по таблице карты"
    [ -e "$PRM/lab_gpc_fix" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_fix"   # вернуть исходные биты PLL ядра
    [ -e "$PRM/lab_gpc_seq" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_seq"; EXPSEQ=0
    [ -e "$PRM/lab_gpc_coef" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_coef"
    [ -e "$PRM/lab_gpc_ref_khz" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_ref_khz"; EXPCOEF=0; EXPFIX=0
    sudo sh -c "echo $RM > $PRM/lab_eng_mask"
    "$0" pstate 03 >/dev/null
    sudo sh -c "echo 65147 > $PRM/lab_eng_mask"
    "$0" pstate 07
    echo "--- Узлы после возврата (по журналу драйвера):"
    journalctl -k -b 0 --no-pager | grep -E 'LAB calc idx 0[01278] ' | tail -n 5 | sed -E 's/.*(LAB calc)/  \1/; s/ ssel.*//'
    ;;
ladder)
    # ЛЕСТНИЦА: все узлы, кроме памяти, по ступенькам от меньшего риска к большему.
    # Каждая ступенька: 07 (через 03) → 0f со своими частотами → быстрый тяжёлый замер → возврат 07.
    # Частоты — только те, что делитель даёт точно (3240 / n МГц), PLL не используется.
    # lab.sh ladder [N] — начать со ступеньки N (после зависания — продолжить со следующей).
    STEPS=(
        "1620 810 0 0 0|ядро 1620 (≈эталон NVIDIA 1644), остальное как в 07"
        "1620 1620 0 0 0|ядро и ROP 1620"
        "810 810 810 0 0|hubk07 810 (значение таблицы 07)"
        "810 810 0 810 0|hubk06 810 (значение таблицы 07)"
        "810 810 0 0 810|hubk01 810 (значение таблицы 07)"
        "810 810 810 810 810|весь 07 по таблице: все узлы 810 (вчера под нагрузкой висло)"
        "1080 1080 1080 1080 1080|все узлы 1080"
        "1620 1620 1620 1620 1620|все узлы 1620 (≈эталон NVIDIA, выше только заводской разгон)"
    )
    FROM="${2:-1}"; [[ "$FROM" =~ ^[1-8]$ ]] || { echo "Ступенька 1..8"; exit 1; }
    mkdir -p "$KIT/results"; LOG="$KIT/results/ladder-$(date +%Y%m%d-%H%M%S).txt"
    echo "=== ЛЕСТНИЦА (память не трогаем; напряжение 0f = 1,075 В)$([ "${DIRECT:-0}" = 1 ] && echo '. ПРЯМЫЕ ПРЫЖКИ 03 → 0f, без 07'). План:"
    for i in "${!STEPS[@]}"; do n=$((i+1)); [ "$n" -ge "$FROM" ] && echo "  $n) ${STEPS[$i]#*|}   [ядро ROP hub07 hub06 hub01 = ${STEPS[$i]%%|*}]"; done
    echo "Каждая ступенька ~1,5 мин. При зависании: подожди минуту, Reset, затем lab.sh ladder <номер+1>."
    read -r -p "Начинаем? Enter — да, Ctrl+C — отмена " _
    sudo -v
    { echo "Лестница $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), с $FROM, прямые прыжки: ${DIRECT:-0}"; } | tee "$LOG"; sync
    echo "=== Контрольный замер 07" | tee -a "$LOG"
    PRM=/sys/module/nouveau/parameters
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv; echo 65147 > $PRM/lab_eng_mask"
    [ -e "$PRM/lab_gpc_fix" ] && sudo sh -c "echo ${EXPFIX:-0} > $PRM/lab_gpc_fix"
    [ -e "$PRM/lab_gpc_seq" ] && sudo sh -c "echo ${EXPSEQ:-0} > $PRM/lab_gpc_seq"
    [ -e "$PRM/lab_gpc_coef" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_coef"
    [ -e "$PRM/lab_gpc_ref_khz" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_ref_khz"
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    "$0" pstate 03 >/dev/null
    { QUICK=1 "$0" bench 07 | grep '^=== Режим' | tail -n 1 || true; } | tee -a "$LOG"; sync
    for i in "${!STEPS[@]}"; do
        n=$((i+1)); [ "$n" -ge "$FROM" ] || continue
        F="${STEPS[$i]%%|*}"
        echo "=== Ступенька $n НАЧАТА $(date +%T): ${STEPS[$i]#*|}" | tee -a "$LOG"; sync
        # shellcheck disable=SC2086
        R="$(QUICK=1 NOCONTROL=1 NOCONFIRM=1 "$0" at $F 2>&1 | tee /dev/stderr | grep -E '^=== Режим 0f: glmark2|^  ✗|^--- СТОП' | tail -n 3 || true)"
        echo "$R" | sed 's/^/    /' | tee -a "$LOG"
        if grep -q 'СТОП\|✗' <<<"$R"; then echo "=== Ступенька $n: окружение не то — лестница остановлена" | tee -a "$LOG"; sync; exit 1; fi
        echo "=== Ступенька $n ПРОЙДЕНА $(date +%T), система жива" | tee -a "$LOG"; sync
    done
    echo "=== Лестница пройдена целиком ✅  Итог: $LOG" | tee -a "$LOG"
    grep -E 'Ступенька|Режим' "$LOG"
    ;;
table)
    # Режим ЦЕЛИКОМ по заводской таблице BIOS: все узлы (и hub) перестраиваются, свои частоты выключены,
    # память и PCIe не трогаем. Переход прямо из 03, тяжёлый замер, затем нагрузка, затем возврат.
    T="${2:-}"; [[ "$T" =~ ^(07|0f)$ ]] || { echo "Укажи режим: lab.sh table 07  или  lab.sh table 0f [минуты нагрузки]"; exit 1; }
    M="${3:-5}"; [[ "$M" =~ ^[0-9]+$ ]] || { echo "Минуты числом"; exit 1; }
    PRM=/sys/module/nouveau/parameters
    sudo -v
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv"
    [ -e "$PRM/lab_gpc_fix" ] && sudo sh -c "echo ${EXPFIX:-0} > $PRM/lab_gpc_fix"
    [ -e "$PRM/lab_gpc_seq" ] && sudo sh -c "echo ${EXPSEQ:-0} > $PRM/lab_gpc_seq"
    [ -e "$PRM/lab_gpc_coef" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_coef"
    [ -e "$PRM/lab_gpc_ref_khz" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_ref_khz"
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 65535 > $PRM/lab_eng_mask"
    echo "=== Режим $T ЦЕЛИКОМ по таблице BIOS (все узлы, включая hub; память не трогаем), из 03"
    preflight 65535 0 0 0 0 0
    [ "$T" = 0f ] && echo "!!! 0f по таблице: ядро 1800, ROP/hubk07 1907, hubk06/hubk01 1645 — через PLL. Вчера так система вставала мгновенно."
    [ "${NOCONFIRM:-0}" = 1 ] || read -r -p "Всё верно? Enter — запустить, Ctrl+C — отмена " _
    "$0" pstate 03 >/dev/null
    HEAVY=1 "$0" bench "$T" || true
    echo "=== Нагрузка $M мин в режиме $T по таблице"
    "$0" load "$M" || true
    echo "=== Возврат: 03 по таблице (hub на стартовые), затем рабочий 07 (hub не трогаем)"
    "$0" pstate 03 >/dev/null
    sudo sh -c "echo 65147 > $PRM/lab_eng_mask"
    "$0" pstate 07
    echo "--- Узлы после возврата (по журналу драйвера):"
    journalctl -k -b 0 --no-pager | grep -E 'LAB calc idx 0[01278] ' | tail -n 5 | sed -E 's/.*(LAB calc)/  \1/; s/ ssel.*//'
    ;;
hold)
    # Поставить свои частоты в 0f и ОСТАВИТЬ карту так (без замера и возврата) — для чтения регистров.
    shift; [ "$#" -ge 2 ] || { echo "Пример: lab.sh hold 1215 1215 1215 1215 1620"; exit 1; }
    PRM=/sys/module/nouveau/parameters
    for v in "$@"; do [[ "$v" =~ ^[0-9]+$ ]] || { echo "Частоты числами в МГц"; exit 1; }; done
    NAMES=(gpc rop hub07 hub06 hub01); BITS=(1 2 4 128 256)
    MASK=$((0xffff & ~(1|2|4|128|256))); A=("$@" 0 0 0 0 0)
    for i in 0 1 2 3 4; do [ "${A[$i]}" -gt 0 ] && MASK=$((MASK | BITS[i])); done
    sudo -v
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv"
    [ -e "$PRM/lab_gpc_fix" ] && sudo sh -c "echo ${EXPFIX:-0} > $PRM/lab_gpc_fix"
    [ -e "$PRM/lab_gpc_seq" ] && sudo sh -c "echo ${EXPSEQ:-0} > $PRM/lab_gpc_seq"
    [ -e "$PRM/lab_gpc_coef" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_coef"
    [ -e "$PRM/lab_gpc_ref_khz" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_ref_khz"
    for i in 0 1 2 3 4; do sudo sh -c "echo $((A[i]*1000)) > $PRM/lab_${NAMES[$i]}_khz"; done
    sudo sh -c "echo $MASK > $PRM/lab_eng_mask"
    "$0" pstate 03 >/dev/null   # сначала 03 с заводской настройкой PLL ядра
    if [ "${GPCFIX:-0}" != 0 ]; then EXPFIX="$GPCFIX"; sudo sh -c "echo $EXPFIX > $PRM/lab_gpc_fix"; echo "=== Опыт с битами PLL ядра: lab_gpc_fix = $EXPFIX"; fi
    if [ "${GPCSEQ:-0}" != 0 ]; then [ -e "$PRM/lab_gpc_seq" ] || { echo "Нет lab_gpc_seq: нужен lab.sh install и перезагрузка"; exit 1; }; EXPSEQ="$GPCSEQ"; sudo sh -c "echo $EXPSEQ > $PRM/lab_gpc_seq"; echo "=== PLL ядра как у NVIDIA: lab_gpc_seq = $EXPSEQ"; fi
    if [ -n "${GPCREF:-}" ]; then EXPREF=$((GPCREF)); sudo sh -c "echo $EXPREF > $PRM/lab_gpc_ref_khz"; echo "=== PLL ядра: опора по гипотезе $GPCREF кГц"; fi
    if [ -n "${GPCCOEF:-}" ]; then EXPCOEF=$((GPCCOEF)); sudo sh -c "echo $EXPCOEF > $PRM/lab_gpc_coef"; echo "=== PLL ядра: принудительно коэффициенты $GPCCOEF"; fi
    echo "=== Держим 0f: ядро ${A[0]}, ROP ${A[1]}, hub ${A[2]}/${A[3]}/${A[4]} МГц (0 = не трогаем)"
    preflight "$MASK" $((A[0]*1000)) $((A[1]*1000)) $((A[2]*1000)) $((A[3]*1000)) $((A[4]*1000))
    "$0" pstate 0f
    echo "=== Карта держится в этом режиме. Вернуть рабочий 07: ~/nouveau-fix/lab/lab.sh home"
    ;;
mem07)
    # ПАМЯТЬ, первый шаг: 135 -> 324 МГц повтором скрипта NVIDIA (шаг A из записи) при переходе 03 -> 07.
    # Узлы — по таблице карты для 07 (как в проверенном «table 07»), память — после узлов, как у NVIDIA.
    # До и после — снимок регистров (только чтение, проверенные диапазоны) и сравнение с эталоном NVIDIA в 07.
    PRM=/sys/module/nouveau/parameters
    REF="$KIT/results/snap-nvidia/snap2-20261020-143554/regs.txt"
    [ -e "$PRM/lab_mem_replay" ] || { echo "Нужен новый лабораторный драйвер (lab_mem_replay): lab.sh install и перезагрузка."; exit 1; }
    [ -e "$REF" ] || { echo "Нет эталона NVIDIA: $REF"; exit 1; }
    mkdir -p "$KIT/results"; SN="$KIT/results/mem07-$(date +%Y%m%d-%H%M%S).txt"
    sudo -v
    # Шаг 0: всё лабораторное — в исходное, память пока не трогаем.
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv; echo 65535 > $PRM/lab_eng_mask"
    for f in lab_gpc_fix lab_gpc_seq lab_gpc_coef lab_gpc_ref_khz; do [ -e "$PRM/$f" ] && sudo sh -c "echo 0 > $PRM/$f"; done
    EXPFIX=0; EXPSEQ=0; EXPCOEF=0; EXPREF=0
    echo "=== Шаг 1: режим 03 (память не трогаем)"
    "$0" pstate 03
    AC="$(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    case "$AC" in *"memory 135 MHz"*) ;; *) echo "--- СТОП: память сейчас не 135 МГц ($AC). Нужна перезагрузка (после неё память 135)."; exit 1;; esac
    preflight 65535 0 0 0 0 0
    sudo python3 "$HERE/regsnap.py" "nouveau 03 до опыта (память 135)" "$SN"
    echo "    снимок «до» записан"
    # Шаг 2: включаем повтор только шага A и порядок «узлы, потом память».
    sudo sh -c "echo 1 > $PRM/lab_mem_replay; echo 1 > $PRM/lab_mem_order; echo 1 > $PRM/lab_mem"
    echo "=== Шаг 2: 03 -> 07, память 135 -> 324 скриптом NVIDIA (шаг A)"
    echo "  lab_mem=$(cat $PRM/lab_mem) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_mem_order=$(cat $PRM/lab_mem_order) lab_eng_mask=$(cat $PRM/lab_eng_mask) lab_disp_pause=$(cat $PRM/lab_disp_pause)"
    [ "$(cat $PRM/lab_mem_replay)" = 1 ] && [ "$(cat $PRM/lab_mem)" = Y ] && [ "$(cat $PRM/lab_mem_order)" = Y ] || { echo "--- СТОП: переключатели памяти не встали"; sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay"; exit 1; }
    [ "${NOCONFIRM:-0}" = 1 ] || read -r -p "Всё верно? Enter — запустить, Ctrl+C — отмена " _
    sync
    "$0" pstate 07 || true
    # Сразу запретить любые дальнейшие смены памяти.
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order"
    echo "--- Журнал драйвера (память):"
    journalctl -k -b 0 --no-pager --since "-2min" | grep -E 'LAB (replay|ram calc|ram prog|pstate [0-9]+: (memory|подъём|done))|WAIT VBLANK|fault|timeout|error' | tail -n 25 | sed -E 's/.*nouveau [^ ]+ //'
    sleep 3
    sudo python3 "$HERE/regsnap.py" "nouveau 07 после шага A" "$SN"
    echo "=== Сравнение с NVIDIA в 07:"
    python3 "$HERE/memcmp.py" "$SN" "$REF" "07 B" | tee -a "$SN.cmp"
    echo "=== Шаг 3: быстрый тяжёлый замер (видеопамять под нагрузкой)"
    QUICK=1 "$0" bench 07 || true
    echo "Снимки: $SN, сравнение: $SN.cmp"
    ;;
mem0f)
    # ПАМЯТЬ, второй шаг: 324 -> 2004 МГц повтором скрипта NVIDIA (шаг B) при переходе 07 -> 0f.
    # Узлы — по таблице карты для 0f (1800 / 1907 / 1907 / 1645 / 1645) с исправлениями PLL (lab_gpc_seq=13), как в H11.
    # Перед этим память должна быть 324 после mem07 в ЭТОЙ загрузке. Обратно скриптом не спускаемся: возврат — перезагрузка.
    PRM=/sys/module/nouveau/parameters
    REF="$KIT/results/snap-nvidia/snap2-20261020-143554/regs.txt"
    [ -e "$PRM/lab_mem_replay" ] || { echo "Нужен лабораторный драйвер v10: lab.sh install и перезагрузка."; exit 1; }
    [ -e "$REF" ] || { echo "Нет эталона NVIDIA: $REF"; exit 1; }
    NA="$(journalctl -k -b 0 --no-pager | grep -c 'LAB replay A 135->324: выполнен, ret 0' || true)"
    [ "${NA:-0}" -gt 0 ] || { echo "--- СТОП: в этой загрузке не было удачного mem07. Сначала: lab.sh mem07"; exit 1; }
    echo "=== В этой загрузке удачный mem07 найден ($NA)"
    AC="$(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    case "$AC" in *"memory 324 MHz"*) ;; *) echo "--- СТОП: память сейчас не 324 МГц ($AC)."; exit 1;; esac
    mkdir -p "$KIT/results"; SN="$KIT/results/mem0f-$(date +%Y%m%d-%H%M%S).txt"
    sudo -v
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv; echo 65535 > $PRM/lab_eng_mask"
    for f in lab_gpc_fix lab_gpc_coef lab_gpc_ref_khz; do [ -e "$PRM/$f" ] && sudo sh -c "echo 0 > $PRM/$f"; done
    sudo sh -c "echo 13 > $PRM/lab_gpc_seq"
    EXPFIX=0; EXPSEQ=13; EXPCOEF=0; EXPREF=0
    echo "=== Шаг 1: проверка, снимок «до» (07, память 324)"
    preflight 65535 0 0 0 0 0
    sudo python3 "$HERE/regsnap.py" "nouveau 07 до шага B (память 324)" "$SN"
    echo "    снимок «до» записан"
    sudo sh -c "echo 2 > $PRM/lab_mem_replay; echo 1 > $PRM/lab_mem_order; echo 1 > $PRM/lab_mem"
    echo "=== Шаг 2: 07 -> 0f: напряжение, узлы по таблице 0f (PLL как у NVIDIA), затем память 324 -> 2004 скриптом NVIDIA (шаг B)"
    echo "  lab_mem=$(cat $PRM/lab_mem) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_mem_order=$(cat $PRM/lab_mem_order) lab_eng_mask=$(cat $PRM/lab_eng_mask) lab_gpc_seq=$(cat $PRM/lab_gpc_seq) lab_disp_pause=$(cat $PRM/lab_disp_pause)"
    [ "$(cat $PRM/lab_mem_replay)" = 2 ] && [ "$(cat $PRM/lab_mem)" = Y ] && [ "$(cat $PRM/lab_mem_order)" = Y ] && [ "$(cat $PRM/lab_gpc_seq)" = 13 ] || { echo "--- СТОП: переключатели не встали"; sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay"; exit 1; }
    [ "${NOCONFIRM:-0}" = 1 ] || read -r -p "Всё верно? Enter — запустить, Ctrl+C — отмена " _
    sync
    "$0" pstate 0f || true
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order"
    echo "--- Журнал драйвера (узлы и память):"
    journalctl -k -b 0 --no-pager --since "-2min" | grep -E 'LAB (replay|ram calc|ram prog|pstate [0-9]+: (memory|подъём|done)|calc idx 0[0-8] dom|prog_3 idx|gpc_seq)|WAIT VBLANK|SWITCH|NOT LOCKED|FAULT|fault|ERROR|timeout' | tail -n 30 | sed -E 's/.*nouveau [^ ]+ //'
    sleep 3
    sudo python3 "$HERE/regsnap.py" "nouveau 0f после шага B" "$SN"
    echo "=== Сравнение с NVIDIA в 0f:"
    python3 "$HERE/memcmp.py" "$SN" "$REF" "07 A" | tee -a "$SN.cmp"
    echo "=== Шаг 3: быстрый тяжёлый замер в 0f"
    QUICK=1 "$0" bench 0f || true
    echo "Снимки: $SN, сравнение: $SN.cmp"
    echo "Карта остаётся в 0f с памятью 2004. home НЕ запускать (спуск памяти ещё не проверен) — вернуться можно перезагрузкой."
    ;;
memdown)
    # ПАМЯТЬ ВНИЗ повтором скриптов NVIDIA: lab.sh memdown 07 (2004 -> 324: C + D) или lab.sh memdown 03 (324 -> 135: D + E).
    # Порядок как у NVIDIA при спуске: сначала память, потом узлы. Каждый шаг разрешается своим битом.
    T="${2:-}"; [[ "$T" =~ ^(07|03)$ ]] || { echo "Укажи: lab.sh memdown 07  или  lab.sh memdown 03"; exit 1; }
    PRM=/sys/module/nouveau/parameters
    REF="$KIT/results/snap-nvidia/snap2-20261020-143554/regs.txt"
    [ -e "$PRM/lab_mem_replay" ] || { echo "Нужен лабораторный драйвер v10."; exit 1; }
    AC="$(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    if [ "$T" = 07 ]; then NEED="memory 2004 MHz"; BIT=4; else NEED="memory 324 MHz"; BIT=8; fi
    case "$AC" in *"$NEED"*) ;; *) echo "--- СТОП: для memdown $T память должна быть ${NEED#memory } сейчас: $AC"; exit 1;; esac
    mkdir -p "$KIT/results"; SN="$KIT/results/memdown$T-$(date +%Y%m%d-%H%M%S).txt"
    sudo -v
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv; echo 65535 > $PRM/lab_eng_mask"
    for f in lab_gpc_fix lab_gpc_coef lab_gpc_ref_khz; do [ -e "$PRM/$f" ] && sudo sh -c "echo 0 > $PRM/$f"; done
    sudo sh -c "echo 13 > $PRM/lab_gpc_seq"
    EXPFIX=0; EXPSEQ=13; EXPCOEF=0; EXPREF=0
    preflight 65535 0 0 0 0 0
    sudo python3 "$HERE/regsnap.py" "nouveau до спуска в $T" "$SN"
    sudo sh -c "echo $BIT > $PRM/lab_mem_replay; echo 1 > $PRM/lab_mem_order; echo 1 > $PRM/lab_mem"
    echo "=== Спуск в $T: сначала память скриптами NVIDIA, потом узлы по таблице $T"
    echo "  lab_mem=$(cat $PRM/lab_mem) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_mem_order=$(cat $PRM/lab_mem_order) lab_eng_mask=$(cat $PRM/lab_eng_mask) lab_gpc_seq=$(cat $PRM/lab_gpc_seq)"
    [ "$(cat $PRM/lab_mem_replay)" = "$BIT" ] && [ "$(cat $PRM/lab_mem)" = Y ] && [ "$(cat $PRM/lab_mem_order)" = Y ] || { echo "--- СТОП: переключатели не встали"; sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay"; exit 1; }
    [ "${NOCONFIRM:-0}" = 1 ] || read -r -p "Всё верно? Enter — запустить, Ctrl+C — отмена " _
    sync
    "$0" pstate "$T" || true
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order"
    echo "--- Журнал драйвера (память и узлы):"
    journalctl -k -b 0 --no-pager --since "-2min" | grep -E 'LAB (replay|ram calc|ram prog|pstate [0-9]+: (memory|подъём|done))|WAIT VBLANK|SWITCH|NOT LOCKED|FAULT|fault|ERROR|timeout' | tail -n 30 | sed -E 's/.*nouveau [^ ]+ //'
    sleep 3
    sudo python3 "$HERE/regsnap.py" "nouveau после спуска в $T" "$SN"
    if [ "$T" = 07 ]; then echo "=== Сравнение с NVIDIA в 07 (его снимок тоже сделан после спуска из 0f):"; python3 "$HERE/memcmp.py" "$SN" "$REF" "07 B" | tee -a "$SN.cmp"; fi
    echo "=== Быстрый тяжёлый замер в $T"
    QUICK=1 "$0" bench "$T" || true
    echo "Снимки: $SN"
    ;;
memcycle)
    # ЦИКЛЫ СМЕНЫ РЕЖИМОВ с памятью (все пути скриптов NVIDIA): 03 -> 07 -> 0f -> 07 -> 03 -> 0f (прыжок) -> 03 (прыжок).
    # После каждого перехода — проверка частоты памяти и ошибок в журнале; в 0f — быстрый тяжёлый замер.
    N="${2:-3}"; [[ "$N" =~ ^[0-9]+$ ]] || { echo "Число циклов"; exit 1; }
    PRM=/sys/module/nouveau/parameters
    [ -e "$PRM/lab_mem_replay" ] || { echo "Нужен лабораторный драйвер v10."; exit 1; }
    AC="$(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
    case "$AC" in *"memory 135 MHz"*) ;; *) echo "--- СТОП: начинать с памяти 135 (режим 03). Сейчас: $AC. Сначала: lab.sh memdown 03 (или перезагрузка)"; exit 1;; esac
    mkdir -p "$KIT/results"; LOG="$KIT/results/memcycle-$(date +%Y%m%d-%H%M%S).txt"
    sudo -v
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv; echo 65535 > $PRM/lab_eng_mask"
    for f in lab_gpc_fix lab_gpc_coef lab_gpc_ref_khz; do [ -e "$PRM/$f" ] && sudo sh -c "echo 0 > $PRM/$f"; done
    sudo sh -c "echo 13 > $PRM/lab_gpc_seq"
    EXPFIX=0; EXPSEQ=13; EXPCOEF=0; EXPREF=0
    preflight 65535 0 0 0 0 0
    sudo sh -c "echo 15 > $PRM/lab_mem_replay; echo 1 > $PRM/lab_mem_order; echo 1 > $PRM/lab_mem"
    echo "  lab_mem=$(cat $PRM/lab_mem) lab_mem_replay=$(cat $PRM/lab_mem_replay) lab_mem_order=$(cat $PRM/lab_mem_order) lab_gpc_seq=$(cat $PRM/lab_gpc_seq)"
    echo "=== $N циклов: 03 -> 07 -> 0f -> 07 -> 03 -> 0f -> 03, в каждом 0f замер. Ошибки журнала считаются после каждого шага."
    [ "${NOCONFIRM:-0}" = 1 ] || read -r -p "Всё верно? Enter — запустить, Ctrl+C — отмена " _
    { echo "Циклы $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), циклов $N"; } | tee "$LOG"; sync
    E0="$(journalctl -k -b 0 --no-pager | grep -cE 'nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT)' || true)"
    ok=1
    for c in $(seq 1 "$N"); do
      for P in 07 0f 07 03 0f 03; do
        case $P in 03) WANT=135;; 07) WANT=324;; 0f) WANT=2004;; esac
        sudo sh -c "f=\$(ls /sys/kernel/debug/dri/*/pstate | head -n1); echo $P > \"\$f\""; sleep 2
        AC="$(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')"
        E="$(journalctl -k -b 0 --no-pager | grep -cE 'nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT)' || true)"
        R="?"; case "$AC" in *"memory $WANT MHz"*) R="✓";; *) R="✗"; ok=0;; esac
        [ "$E" -gt "$E0" ] && { R="$R ошибки журнала: $((E - E0))"; ok=0; }
        echo "$(date +%T) цикл $c -> $P: ${AC#*AC: } $R" | tee -a "$LOG"; sync
        [ "$ok" = 1 ] || break 2
        if [ "$P" = 0f ]; then   # замер в 0f с памятью 2004; на время замера смены памяти запрещены
          sudo sh -c "echo 0 > $PRM/lab_mem"
          SC="$(QUICK=1 "$0" bench 0f 2>&1 | grep -E '^=== Режим 0f: glmark2' | tail -n 1)"
          sudo sh -c "echo 1 > $PRM/lab_mem"
          echo "    замер в 0f: ${SC#=== Режим 0f: }" | tee -a "$LOG"; sync
        fi
      done
    done
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_mem_replay; echo 0 > $PRM/lab_mem_order"
    echo "$(date +%T) режим сейчас: $(sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1')" | tee -a "$LOG"
    [ "$ok" = 1 ] && echo "=== Все переходы прошли ✅" | tee -a "$LOG" || echo "=== СТОП: переход не удался — см. выше и журнал" | tee -a "$LOG"
    echo "Лог: $LOG"
    ;;
home)
    # Вернуть рабочий 07: свои частоты сброшены, через 03 (hub на стартовые), затем 07 (hub не трогаем).
    PRM=/sys/module/nouveau/parameters
    sudo -v
    for n in gpc rop hub07 hub06 hub01; do sudo sh -c "echo 0 > $PRM/lab_${n}_khz"; done
    sudo sh -c "echo 0 > $PRM/lab_mem; echo 0 > $PRM/lab_pcie; echo 1 > $PRM/lab_volt_first; echo 1 > $PRM/lab_core; echo 0 > $PRM/lab_volt_min_uv; echo 65535 > $PRM/lab_eng_mask"
    [ -e "$PRM/lab_gpc_fix" ] && sudo sh -c "echo ${EXPFIX:-0} > $PRM/lab_gpc_fix"
    [ -e "$PRM/lab_gpc_seq" ] && sudo sh -c "echo ${EXPSEQ:-0} > $PRM/lab_gpc_seq"
    [ -e "$PRM/lab_gpc_coef" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_coef"
    [ -e "$PRM/lab_gpc_ref_khz" ] && sudo sh -c "echo 0 > $PRM/lab_gpc_ref_khz"
    "$0" pstate 03 >/dev/null
    sudo sh -c "echo 65147 > $PRM/lab_eng_mask"
    "$0" pstate 07
    echo "--- Узлы (по журналу драйвера):"
    journalctl -k -b 0 --no-pager | grep -E 'LAB calc idx 0[01278] ' | tail -n 5 | sed -E 's/.*(LAB calc)/  \1/; s/ ssel.*//'
    ;;
calib)
    # КАЛИБРОВКА ЯДРА: скорость чистых вычислений при ядре на делителе (известная частота)
    # и на PLL (частота под вопросом). ROP 810, hub стартовые, память не трогаем.
    if [ "$#" -gt 1 ]; then shift; PTS=(); for f in "$@"; do [[ "$f" =~ ^[0-9]+$ ]] || { echo "Частоты числами"; exit 1; }; PTS+=("$f ?"); done
    else PTS=("405 делитель" "540 делитель" "810 делитель" "1080 делитель" "1620 делитель" "607 PLL" "1215 PLL" "1800 PLL"); fi
    mkdir -p "$KIT/results"; LOG="$KIT/results/calib-$(date +%Y%m%d-%H%M%S).txt"
    echo "=== КАЛИБРОВКА ЯДРА: ${#PTS[@]} точек по ~40 с, ROP 810, hub стартовые, память не трогаем. Ядро на PLL: lab_gpc_seq=${GPCSEQ:-0}. Замер: $([ "${ALU:-0}" = 1 ] && echo "ЧЕСТНЫЙ (цикл ${ALUSTEPS:-2000})" || echo 'быстрый 400x300')."
    read -r -p "Начинаем? Enter — да, Ctrl+C — отмена " _
    sudo -v
    echo "Калибровка $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), lab_gpc_seq=${GPCSEQ:-0}, ALU=${ALU:-0} ALUSTEPS=${ALUSTEPS:-2000}" | tee "$LOG"; sync
    for p in "${PTS[@]}"; do
        F="${p%% *}"; W="${p#* }"; [ "$W" = "?" ] && W="(источник см. ssel)"
        echo "=== Точка: ядро $F ($W) НАЧАТА $(date +%T)" | tee -a "$LOG"; sync
        R="$(GPCFIX=0 CORE=1 NOCONTROL=1 NOCONFIRM=1 "$0" at "$F" 810 2>&1 | tee /dev/stderr | grep -E '^=== Режим 0f: glmark2|^  ✗|^--- СТОП' | tail -n 1 || true)"
        L="$(journalctl -k -b 0 --no-pager | grep -E "LAB calc idx 00 dom 19: want ${F}000 " | tail -n 1 | grep -oE 'got [0-9]+ ssel [0-9a-f]+' || true)"
        T="$(journalctl -k -b 0 --no-pager --since '-2min' | grep -c 'prog_3 idx 00 SWITCH TIMEOUT' || true)"
        printf '  ядро %-5s %-9s | %s | драйвер: %s | сбой переключения ядра: %s\n' "$F" "$W" "${R#=== Режим 0f: }" "$L" "$T" | tee -a "$LOG"; sync
        grep -q 'СТОП\|✗' <<<"$R" && { echo "=== Окружение не то — остановлено" | tee -a "$LOG"; exit 1; }
    done
    echo "=== Калибровка завершена ✅"; grep '^  ядро' "$LOG"
    ;;
pllcmp)
    # «ОДНА ЧАСТОТА — ДВА ПУТИ»: ядро на делителе и на PLL с одинаковой частотой.
    # PLL: опора 405, M=5 (81 МГц на входе), N=20 (VCO 1620), меняется только выходной делитель P.
    PTS=("810 -" "810 0x00021405" "540 -" "540 0x00031405" "405 -" "405 0x00041405" "1620 -" "1620 0x00011405" "1215 0x00010f05")
    mkdir -p "$KIT/results"; LOG="$KIT/results/pllcmp-$(date +%Y%m%d-%H%M%S).txt"
    echo "=== ОДНА ЧАСТОТА — ДВА ПУТИ: ${#PTS[@]} точек по ~40 с (замер ядра 400x300). ROP 810, hub стартовые, память не трогаем."
    read -r -p "Начинаем? Enter — да, Ctrl+C — отмена " _
    sudo -v
    echo "Сравнение $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8)" | tee "$LOG"; sync
    for p in "${PTS[@]}"; do
        F="${p%% *}"; C="${p#* }"
        if [ "$C" = "-" ]; then W="делитель"; E=(); else W="PLL $C"; E=(GPCCOEF="$C"); fi
        echo "=== Точка: ядро $F ($W) НАЧАТА $(date +%T)" | tee -a "$LOG"; sync
        R="$(env "${E[@]}" GPCFIX=0 CORE=1 NOCONTROL=1 NOCONFIRM=1 "$0" at "$F" 810 2>&1 | tee /dev/stderr | grep -E '^=== Режим 0f: glmark2|^  ✗|^--- СТОП' | tail -n 1 || true)"
        L="$(journalctl -k -b 0 --no-pager --since '-2min' | grep -E 'LAB calc idx 00 (FORCED|dom 19)' | tail -n 1 | grep -oE 'got [0-9]+ ssel [0-9a-f]+|coef [0-9a-f]+ \(N=[0-9]+ M=[0-9]+ P=[0-9]+\).*ssel [0-9a-f]+' || true)"
        T="$(journalctl -k -b 0 --no-pager --since '-2min' | grep -cE 'idx 00 SWITCH TIMEOUT|idx 00 PLL NOT LOCKED|gpc_coef .*игнорирую' || true)"
        printf '  ядро %-5s %-16s | %s | драйвер: %s | сбоев: %s\n' "$F" "$W" "${R#=== Режим 0f: }" "$L" "$T" | tee -a "$LOG"; sync
        grep -q 'СТОП\|✗' <<<"$R" && { echo "=== Окружение не то — остановлено" | tee -a "$LOG"; exit 1; }
    done
    echo "=== Сравнение завершено ✅"; grep '^  ядро' "$LOG"
    ;;
restore)
    [ -e "$BACKUP" ] || { echo "Нет резервной копии $BACKUP. Стабильный драйвер можно пересобрать: ~/nouveau-fix/rebuild.sh"; exit 1; }
    sudo install -m 644 "$BACKUP" "$SLOT"
    sudo depmod -a "$KVER"; sudo update-initramfs -u -k "$KVER"
    echo "=== Стабильный драйвер возвращён. Перезагрузись и проверь: ~/nouveau-fix/check.sh"
    ;;
*)
    sed -n '2,41p' "$0"; exit 1 ;;
esac
