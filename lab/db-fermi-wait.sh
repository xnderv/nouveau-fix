#!/bin/bash
# Разбор трасс NVIDIA по Fermi из базы nouveau_vbios_trace (частная, вне репозитория): для каждой трассы — карта (PCI id),
# есть ли скобка FSRM (запись 0x0201a0/0x0201a4), есть ли цикл ожидания по таймеру и его порог (trace/trace-dwell-bound.py),
# значение 0x020130; дата добавления файла в базу — оценка эпохи драйвера. Авторы не выводятся (участник = номер).
# Низкий приоритет, по одной трассе: не мешать тестам на этой же машине.
#   bash lab/db-fermi-wait.sh [КАТАЛОГ_БАЗЫ] > отчёт.txt
DB="${1:-$HOME/Home/nouveau-archive/nouveau_vbios_trace}"; KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DB" || exit 1
declare -A WHO; n=0
stream() {   # распаковать трассу в stdout (xz, xz внутри xz, tar.gz с трассой внутри)
    case "$1" in
        *.tar.gz) tar -xOzf "$1" --wildcards '*' 2>/dev/null ;;
        *.xz) if xz -dc "$1" 2>/dev/null | head -c 16 | grep -q 'VERSION'; then xz -dc "$1"; else xz -dc "$1" | xz -dc 2>/dev/null; fi ;;
        *) cat "$1" ;;
    esac
}
for f in $(git ls-files 'nvc*' 'nvd*' | grep -iE 'mmio|downclock|trace' | grep -iE '\.(xz|gz)$'); do
    chip="${f%%/*}"; who="$(echo "$f" | cut -d/ -f2)"
    [ -n "${WHO[$who]:-}" ] || { n=$((n+1)); WHO[$who]="участник $n"; }
    added="$(git log --diff-filter=A --format=%ad --date=short -- "$f" | tail -n 1)"
    # BAR0 — первое отображение размером 16 МБ (регистры карты); PCI id — строка PCIDEV с этим же BAR0 (если есть)
    bar="$(stream "$f" | grep -m1 -E '^MAP [0-9.]+ [0-9]+ 0x[0-9a-f]+ 0x[0-9a-f]+ 0x1000000 ' | awk '{print substr($4,3)}')"
    dev="$(stream "$f" | head -n 3000 | awk -v b="$bar" '$1=="PCIDEV" && substr($3,1,4)=="10de" && index($5, b)==1 {print substr($3,5,4); exit}')"
    echo "=== $chip | ${WHO[$who]} | $(basename "$f") | добавлен $added | PCI 10de:$dev | BAR0 ${bar:-?}"
    [ -n "$bar" ] || { echo "    нет отображения регистров карты (MAP 16 МБ) — пропуск"; continue; }
    b=$((16#$bar)); b=$(( b & ~0xf )); bh=$(printf '0x%x' $b)
    stream "$f" | nice -n 19 ionice -c3 python3 -I "$KIT/trace/trace-dwell-bound.py" - "$bh" 2>&1 | sed 's/^/    /'
    cnt="$(stream "$f" | grep -cE "^W [0-9]+ [0-9.]+ [0-9]+ 0x$(printf '%x' $((b + 0x0201a0))) ")"
    echo "    записей FSRM_4 (вход в скобку GPC): $cnt"
done
