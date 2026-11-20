#!/bin/bash
# Пересобрать патчи для тестировщиков из рабочего дерева лабораторного драйвера (20.11.2026).
#   0002 (основной, от Linux 7.0.14 — у нас и у rox4d), 0002-v7.2 (ядра, где уже есть две правки nouveau в clk/base.c: 6.12,
#   7.2), 0002-v7.3 (все три правки), 0004 (PMU: прошивка PERF и регулятор). Описание 0004 (шапка письма) сохраняется.
# Проверка: цепочка 0001 → 0002 → 0003 → 0004 → 0005 → 0006 на 7.0.14 = рабочее дерево байт в байт; цепочка тестировщиков
# (0001, 0002 с выбором варианта, 0004, 0006) ложится на 6.12.115, 7.0.14, 7.2.11, 7.3; сборка — на заголовках этой машины.
#   bash lab/regen-patches.sh      — на ноутбуке; исходники nouveau скачиваются (git, ~15 МБ на версию) в каталог W
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$HOME/Home/nouveau-build/lab-vbios-src/nouveau}"
W="${W:-$HOME/Home/nouveau-build/regen}"
KHDR="${KHDR:-/usr/src/linux-headers-7.0.0-42-generic}"
P1="$KIT/patches/0001-nouveau-abi16-idle-channel-before-engobj-del.patch"
P3="$KIT/patches/0003-nouveau-disp-hdmi-without-scdc-below-340mhz.patch"
P4="$KIT/patches/0004-LAB-pmu-perf-load.patch"
P5="$KIT/patches/0005-LAB-hdmi-avi-itc.patch"
P6="$KIT/patches/0006-nouveau-therm-mask-pwm-update-bit-on-read.patch"
F2="nvkm/subdev/clk/base.c nvkm/subdev/clk/gf100.c nvkm/subdev/fb/ramgf100.c nvkm/subdev/volt/base.c"
F4="nvkm/subdev/pmu/fuc/gf100.fuc3.h nvkm/subdev/pmu/fuc/perf.fuc nvkm/subdev/pmu/gf100.c"
mkdir -p "$W"; cd "$W"
fetch() {   # $1 тег → каталог up-$1 с drivers/gpu/drm/nouveau
  [ -d "up-$1" ] && return
  rm -rf "s-$1"; git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$1" https://github.com/gregkh/linux.git "s-$1"
  git -C "s-$1" sparse-checkout set drivers/gpu/drm/nouveau; git -C "s-$1" checkout -q
  cp -r "s-$1/drivers/gpu/drm/nouveau" "up-$1"; rm -rf "s-$1"
}
for t in v7.0.14 v7.2.11 v7.3 v6.12.115; do fetch "$t"; done
mk() {   # $1 основа, $2 выход, $3 файлы, $4 патчи перед основой
  rm -rf B; cp -r "$1" B; for p in $4; do (cd B && patch -p1 -s < "$p"); done
  : > "$2"; for f in $3; do diff -u --label "a/$f" --label "b/$f" "B/$f" "$SRC/$f" >> "$2" || true; done
}
# 0002 и варианты: base.c в рабочем дереве = код лаборатории + три правки nouveau (как в 7.3)
mk up-v7.0.14 p2.patch "$F2" "$P1"
mk up-v7.2.11 p2-72.patch "$F2" "$P1"
mk up-v7.3 p2-73.patch "$F2" "$P1"
# 0004: от 7.0.14 + 0001 + 0002 + 0003; шапка письма — из прежнего 0004
rm -rf B4; cp -r up-v7.0.14 B4; for p in "$P1" "$W/p2.patch" "$P3"; do (cd B4 && patch -p1 -s < "$p"); done
python3 - "$P4" > hdr.txt <<'EOF2'
import sys
s=open(sys.argv[1]).read(); i=s.find('\n--- a/'); print(s[:i+1] if i>=0 else '', end='')
EOF2
{ cat hdr.txt; for f in $F4; do diff -u --label "a/$f" --label "b/$f" "B4/$f" "$SRC/$f" || true; done; } > p4.patch
# проверка 1: полная цепочка = рабочее дерево
rm -rf V; cp -r up-v7.0.14 V; for p in "$P1" "$W/p2.patch" "$P3" "$W/p4.patch" "$P5" "$P6"; do (cd V && patch -p1 -s < "$p"); done
if diff -rq V "$SRC" -x '*.o' -x '*.ko' -x '*.cmd' -x '*.mod*' -x modules.order -x Module.symvers -x '.*' | grep -v "^Only in $SRC" | grep -q .; then
  echo "СТОП: полная цепочка не совпала с рабочим деревом"; diff -rq V "$SRC" -x '*.o' -x '*.ko' -x '*.cmd' -x '*.mod*' -x '.*' | grep -v "^Only in $SRC" | head; exit 1
fi
echo "проверка 1: полная цепочка = рабочее дерево"
# проверка 2: цепочка тестировщиков на каждом ядре (выбор варианта 0002 как в tester-build.sh)
for t in v6.12.115 v7.0.14 v7.2.11 v7.3; do
  rm -rf T; cp -r "up-$t" T; r=""
  for p in "$P1" CHOOSE "$W/p4.patch" "$P6"; do
    if [ "$p" = CHOOSE ]; then
      for c in p2.patch p2-72.patch p2-73.patch; do (cd T && patch -p1 --dry-run -s < "$W/$c" >/dev/null 2>&1) && { p="$W/$c"; break; }; done
    fi
    :
    (cd T && patch -p1 -s < "$p" >/dev/null 2>&1) && r="$r $(basename "$p")" || { r="$r СБОЙ:$(basename "$p")"; }
  done
  echo "проверка 2, $t:$r"
done
# сборка на 7.0.14 (заголовки этой машины)
rm -rf T; cp -r up-v7.0.14 T; for p in "$P1" "$W/p2.patch" "$W/p4.patch" "$P6"; do (cd T && patch -p1 -s < "$p"); done
make -C "$KHDR" M="$W/T" modules -j"$(nproc)" > build.log 2>&1 && echo "сборка 7.0: ок, srcversion $(modinfo -F srcversion T/nouveau.ko)" || { echo "СТОП: сборка"; tail -5 build.log; exit 1; }
cp p2.patch "$KIT/lab/0002-LAB-fermi-reclock-instrumented.patch"
cp p2-72.patch "$KIT/lab/0002-LAB-fermi-reclock-instrumented-v7.2.patch"
cp p2-73.patch "$KIT/lab/0002-LAB-fermi-reclock-instrumented-v7.3.patch"
cp p4.patch "$P4"
grep -liE "/home/[a-z]|$(hostname)|$USER@" "$KIT"/lab/0002-*.patch "$P4" && { echo "СТОП: личные данные в патчах"; exit 1; } || true
echo "патчи обновлены в репозитории"
