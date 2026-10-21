#!/bin/bash
# НОВОЕ ЯДРО: подготовить оба наших драйвера под новое ядро ДО перезагрузки — потом одна перезагрузка.
#   ~/nouveau-fix/newkernel.sh                 — самое новое установленное ядро
#   ~/nouveau-fix/newkernel.sh 7.0.0-40-generic — конкретное ядро
# Шаг 1: стабильный драйвер (только исправление гонки) — резерв, на который можно откатиться (lab.sh restore).
# Шаг 2: рабочий драйвер (исправление гонки + частоты/память) — поверх стабильного.
# При любой ошибке ничего не ставится, текущее ядро не трогается. Пароль — только на шагах установки, после твоего «y».
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="${1:-$(ls -1 /lib/modules | sort -V | tail -n 1)}"
echo "=== Новое ядро: $KVER (сейчас работает $(uname -r))"
[ -d "/lib/modules/$KVER" ] || { echo "Ядро $KVER не установлено."; exit 1; }
[ -e "/lib/modules/$KVER/build/Makefile" ] || { echo "Нет заголовков ядра $KVER. Поставь: sudo apt install linux-headers-$KVER"; exit 1; }
echo; echo "############ Шаг 1 из 2: стабильный драйвер (резерв) ############"
"$HERE/rebuild.sh" "$KVER"
[ -e "/lib/modules/$KVER/updates/nouveau-fix/nouveau.ko" ] || { echo "--- Стабильный драйвер для $KVER не установлен — дальше не иду."; exit 1; }
echo; echo "############ Шаг 2 из 2: рабочий драйвер (частоты и память) ############"
KVER="$KVER" "$HERE/lab/lab.sh" install
echo
echo "=== Для ядра $KVER стоит: $(modinfo -k "$KVER" -n nouveau)"
modinfo -k "$KVER" -p nouveau 2>/dev/null | grep -q lab_mem_replay && echo "=== Это рабочий драйвер (lab_mem_replay есть) ✅" || echo "!!! Это НЕ рабочий драйвер — частоты после перезагрузки управляться не будут"
sudo rm -f "/var/lib/nouveau-fix/pending-$KVER" 2>/dev/null || true
echo "Перезагрузись. После неё: ~/nouveau-fix/daily/autoclock.sh status"
