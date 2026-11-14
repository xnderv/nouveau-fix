#!/bin/bash
# Целевые выборки VBIOS с TechPowerUp по поколениям Kepler … Ampere (14.11.2026). Запускает ТОЛЬКО человек: разрешение
# W1zzard от 28.10 выдано автору проекта («small targeted subsets … not everything»), robots.txt сайта закрывает доступ агентам.
# Объём: ~1140 образов; вместе с уже взятыми 403 образами Fermi это около 10 % коллекции (15 374 образа на 14.11).
# По каждой модели берётся не больше указанного числа. Пауза 3 с между запросами, при 403/429 выгрузка останавливается
# (так устроен tools/tpu-vbios-fetch.py). Повторный запуск докачивает недостающее. Образы кладутся вне репозитория.
#   bash ~/Home/nouveau-fix/tools/tpu-subsets.sh [kepler|maxwell|pascal|volta|turing|ampere ...]   (без аргументов — все)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT=~/Home/nouveau-archive/tpu-vbios
declare -A SETS
SETS[kepler]="GTX 650:20|GTX 650 Ti:20|GTX 660:25|GTX 660 Ti:20|GTX 670:25|GTX 680:30|GTX 690:8|GTX 760:20|GTX 770:30|GTX 780:30|GTX 780 Ti:20|GTX TITAN:12|GTX Titan Black:6|GT 640:15|GT 740:2|GTX 680M:7|GTX 780M:6|GTX 880M:8|Tesla K20M:5|Quadro K5000:6"
SETS[maxwell]="GTX 750:9|GTX 750 Ti:25|GTX 950:12|GTX 960:30|GTX 970:45|GTX 980:30|GTX 980 Ti:30|GTX Titan X:10|GTX 970M:4|GTX 980M:5|Quadro M4000:3"
SETS[pascal]="GT 1030:16|GTX 1050:20|GTX 1050 Ti:30|GTX 1060:80|GTX 1060 3GB:3|GTX 1070:50|GTX 1070 Ti:15|GTX 1080:50|GTX 1080 Ti:30|Titan Xp:1|Titan X Pascal:1|Quadro P5000:2"
SETS[volta]="Titan V:6|Quadro GV100:1|Tesla V100:3"
SETS[turing]="GTX 1650:12|GTX 1650 Super:12|GTX 1660:12|GTX 1660 Super:12|GTX 1660 Ti:12|RTX 2060:25|RTX 2060 Super:15|RTX 2070:25|RTX 2070 Super:20|RTX 2080:60|RTX 2080 Super:20|RTX 2080 Ti:25|Titan RTX:2"
SETS[ampere]="RTX 3050:6|RTX 3060:10|RTX 3060 Ti:10|RTX 3070:10|RTX 3080:10|RTX 3080 Ti:6|RTX 3090:8|RTX 3080 Mobile:4"
GENS=("$@"); [ ${#GENS[@]} -gt 0 ] || GENS=(volta pascal turing kepler maxwell ampere)
for g in "${GENS[@]}"; do
  [ -n "${SETS[$g]:-}" ] || { echo "Нет набора «$g»"; exit 1; }
  D="$OUT/2026-11-14-$g"; mkdir -p "$D"
  IFS='|' read -r -a items <<< "${SETS[$g]}"
  for it in "${items[@]}"; do
    m="${it%%:*}"; n="${it##*:}"
    echo "=== $g: $m (не больше $n) $(date +%T)"
    python3 -I "$HERE/tpu-vbios-fetch.py" "$D" --model "$m" --max "$n" --delay 3 || { echo "!!! остановка на «$m» (код $?) — сайт отказал или ошибка; дальше не иду"; exit 1; }
  done
  echo "=== $g готово: $(ls "$D"/*.rom 2>/dev/null | wc -l) образов в $D"
done
