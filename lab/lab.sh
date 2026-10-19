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
#   lab.sh exp A|B|C|D — серия опытов «по одному параметру», каждый = try 0f 03:
#                      A — только напряжение; B — напряжение + память; C — напряжение + ядро;
#                      D — всё вместе (напряжение поднимается первым).
#   lab.sh flags     — показать текущие переключатели лабораторного драйвера.
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
flags|exp)
    PRM=/sys/module/nouveau/parameters
    [ -e "$PRM/lab_core" ] || { echo "Лабораторный драйвер не загружен (нет $PRM/lab_core). Сначала: lab.sh install и перезагрузка."; exit 1; }
    if [ "$1" = flags ]; then
        for f in lab_pcie lab_mem lab_core lab_volt_first; do echo "$f = $(cat "$PRM/$f")"; done
        exit 0
    fi
    E="${2:-}"
    case "$E" in
        A) F="0 0 0 1"; D="только напряжение (без PCIe, памяти и ядра)";;
        B) F="0 1 0 1"; D="напряжение + память";;
        C) F="0 0 1 1"; D="напряжение + ядро";;
        D) F="1 1 1 1"; D="всё: PCIe + напряжение + память + ядро";;
        *) echo "Укажи опыт: A, B, C или D"; exit 1;;
    esac
    [ "$(id -u)" -eq 0 ] || exec sudo -E "$0" exp "$E"
    read -r PC ME CO VF <<<"$F"
    echo "$PC" > "$PRM/lab_pcie"; echo "$ME" > "$PRM/lab_mem"
    echo "$CO" > "$PRM/lab_core"; echo "$VF" > "$PRM/lab_volt_first"
    echo "=== Опыт $E: $D"
    for f in lab_pcie lab_mem lab_core lab_volt_first; do echo "    $f = $(cat "$PRM/$f")"; done
    exec "$0" try 0f 03
    ;;
try)
    # Опыт со страховкой: переключить режим(ы) и ждать подтверждения «вижу экран».
    # Нет подтверждения → вернуть 03; всё ещё нет → сохранить журнал и перезагрузиться самому.
    shift
    [ "$#" -ge 1 ] || { echo "Укажи режимы, например: lab.sh try 07 0f"; exit 1; }
    for P in "$@"; do [[ "$P" =~ ^(03|07|0f)$ ]] || { echo "Неизвестный режим: $P"; exit 1; }; done
    [ "$(id -u)" -eq 0 ] || exec sudo -E "$0" try "$@"
    mkdir -p "$KIT/results"
    RES="$KIT/results/try-$(date +%Y%m%d-%H%M%S).txt"
    PS="$(ls /sys/kernel/debug/dri/*/pstate | head -n 1)"
    note() { echo "$(date +%T) $*" | tee -a "$RES"; sync; }
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
restore)
    [ -e "$BACKUP" ] || { echo "Нет резервной копии $BACKUP. Стабильный драйвер можно пересобрать: ~/nouveau-fix/rebuild.sh"; exit 1; }
    sudo install -m 644 "$BACKUP" "$SLOT"
    sudo depmod -a "$KVER"; sudo update-initramfs -u -k "$KVER"
    echo "=== Стабильный драйвер возвращён. Перезагрузись и проверь: ~/nouveau-fix/check.sh"
    ;;
*)
    sed -n '2,16p' "$0"; exit 1 ;;
esac
