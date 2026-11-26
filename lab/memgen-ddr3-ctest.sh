#!/bin/bash
# СВЕРКА ЯДРА ГЕНЕРАТОРА СКРИПТОВ ПАМЯТИ DDR3 (текст на C из лабораторного драйвера) С ЗАПИСЯМИ NVIDIA (26.11.2026).
# Ядро вырезается из драйвера (fb/ramgf100.c, между метками LAB_G3_CORE_BEGIN и LAB_G3_CORE_END): из рабочего дерева,
# если оно есть, иначе — из патча lab/0002-LAB-fermi-reclock-instrumented.patch. Затем собирается обычным gcc вместе со
# стендом lab/memgen-ddr3-ctest.c и прогоняется по блокам проверочных данных (lab/memgen-ddr3-cases.txt: записанные
# скрипты NVIDIA пяти плат GF108 DDR3 и входные данные к ним; делает «memgen-ddr3.py cases» и lab/db-memgen-ddr3.py).
# Ничего не меняет, железо не трогает.
#   bash lab/memgen-ddr3-ctest.sh [БЛОКИ.txt] [-v]        (SRC=каталог nouveau рабочего дерева драйвера)
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$HOME/Home/nouveau-build/lab-vbios-src/nouveau}"
CASES="$KIT/lab/memgen-ddr3-cases.txt"
if [ $# -gt 0 ] && [ "$1" != "-v" ]; then CASES="$1"; shift; fi
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
F="$SRC/nvkm/subdev/fb/ramgf100.c"
if [ -f "$F" ] && grep -q LAB_G3_CORE_BEGIN "$F"; then
  sed -n '/LAB_G3_CORE_BEGIN/,/LAB_G3_CORE_END/p' "$F" > "$W/g3-core.inc"; echo "ядро генератора: из рабочего дерева драйвера"
else
  sed -n '/^+.*LAB_G3_CORE_BEGIN/,/^+.*LAB_G3_CORE_END/p' "$KIT/lab/0002-LAB-fermi-reclock-instrumented.patch" | sed 's/^+//' > "$W/g3-core.inc"
  echo "ядро генератора: из патча lab/0002-LAB-fermi-reclock-instrumented.patch"
fi
[ -s "$W/g3-core.inc" ] || { echo "СТОП: ядро генератора не найдено"; exit 1; }
echo "строк ядра: $(wc -l < "$W/g3-core.inc"), sha256 $(sha256sum "$W/g3-core.inc" | cut -c1-16)"
gcc -O1 -Wall -Wextra -Wno-unused-function -I"$W" -o "$W/ctest" "$KIT/lab/memgen-ddr3-ctest.c"
"$W/ctest" "$CASES" "$@"
