#!/bin/bash
# Уведомление на рабочий стол от службы gpu-autoclock (сторож журнала, 25.10). Запускается от имени пользователя.
#   notify-gpu.sh ЗАГОЛОВОК ТЕКСТ [low|normal|critical]
notify-send -a 'Драйвер видеокарты' -u "${3:-normal}" -i video-display "$1" "$2"
