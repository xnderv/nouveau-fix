# Если машина автора не загружается (на время тестов лабораторного драйвера, с 25.10.2026)

1. Экран чёрный или завис — нажми кнопку **Reset** (или подожди: при панике ядра машина сама перезагрузится через 10 с).
2. При старте 5 с видно меню GRUB (после сбоя оно ждёт 30 с). Стрелками выбери **третью строку**
   `Ubuntu - STABLE nouveau (if the lab driver fails)` и нажми **Enter**.
3. Загрузится стабильный драйвер (копия от 19.10). Работай как обычно; лабораторный остаётся на диске, его разберём потом.
4. Меню не появилось — при старте держи **Shift**. Совсем ничего не помогает — в меню «Advanced options» → «recovery mode».

Как это устроено: nouveau поднимается из образа initramfs, который GRUB грузит вместе с ядром. Третья строка — то же ядро,
но второй образ `/boot/initrd.img-<ядро>.nouveau-stable` со стабильным модулем. Ставит и убирает `lab/bootmenu.sh`
(`install`, `status`, `uninstall`); после обновления ядра — `lab/bootmenu.sh install` заново.

*If the author's machine does not boot during lab-driver tests: press Reset, then pick the 3rd GRUB line
“Ubuntu - STABLE nouveau (if the lab driver fails)”. Set up by `lab/bootmenu.sh`.*
