#!/bin/bash
# Проверка: работает ли исправленный драйвер в текущей загрузке. Только читает, пароль не нужен.
K="$(uname -r)"
echo "Ядро сейчас:            $K"
echo "Выбранный файл драйвера: $(modinfo -n nouveau 2>/dev/null)"
J="$(journalctl -k -b 0 --no-pager 2>/dev/null)"
if grep -q 'nouveau: loading out-of-tree module' <<<"$J"; then
    echo "Загружен:               НАШ драйвер с исправлением  ✅"
else
    echo "Загружен:               стандартный драйвер Ubuntu (без исправления)  ⚠️"
fi
echo "Срабатываний исправления в этой загрузке: $(grep -c 'nouveau-engobj-idle' <<<"$J")"
ERR="$(grep -cE 'killed!|fifo: fault|SCHED_ERROR|nouveau 0000:[0-9a-f:.]+: timeout|failed to idle' <<<"$J")"
echo "Ошибок видеокарты в этой загрузке:        $ERR"
[ "$ERR" -gt 0 ] && grep -E 'killed!|fifo: fault|SCHED_ERROR|failed to idle' <<<"$J" | tail -n 5
B="$HOME/Home/nouveau-build/stable-$K-nouveau.ko"
F="/lib/modules/$K/updates/nouveau-fix/nouveau.ko"
if [ -e "$B" ] && [ -e "$F" ] && ! cmp -s "$B" "$F"; then
    echo "Установлен ЛАБОРАТОРНЫЙ драйвер (опыты с частотами). Вернуть стабильный: ~/Home/nouveau-fix/lab/lab.sh restore"
fi
grep -o 'nouveau.debug=[^ ]*' /proc/cmdline | sed 's/^/Подробный журнал включён: /'
grep -q 'nouveau.debug=' /proc/cmdline && echo "  (как выключить — README, раздел «Подробный журнал»)"
exit 0
