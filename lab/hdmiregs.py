#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ: что карта РЕАЛЬНО отправляет в монитор по HDMI (GF114, дисплей класса gt215).
# Читает регистры выходов SOR: включён ли режим HDMI, включён ли пакет AVI InfoFrame и его содержимое
# (формат цвета, диапазон, «ИТ-содержимое», тип содержимого). Сначала читается список существующих выходов
# (0x610184), чтобы не трогать несуществующие адреса. Ничего не записывает.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/hdmiregs.py
import glob, mmap, os, struct, sys

dev = next((d for d in glob.glob('/sys/bus/pci/devices/*')
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03')), None)
if not dev:
    sys.exit('Видеокарта NVIDIA не найдена')
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]

sors = (rd(0x610184) & 0x0f000000) >> 24
print(f'выходы SOR на карте (0x610184): маска {sors:x}')
CF = {0: 'RGB', 1: 'YCbCr 4:2:2', 2: 'YCbCr 4:4:4', 3: 'YCbCr 4:2:0'}
QR = {0: 'по умолчанию (для ПК-режимов = полный)', 1: 'ограниченный 16–235', 2: 'полный 0–255', 3: '?'}
CN = {0: 'графика', 1: 'фото', 2: 'кино', 3: 'игра'}
for i in range(4):
    if not sors & (1 << i):
        continue
    o = i * 0x800
    ctrl, avi_en, aud_en = rd(0x61c5a4 + o), rd(0x61c520 + o), rd(0x61c500 + o)
    hdmi = bool(ctrl & 0x40000000)
    print(f'\nSOR{i}: управление HDMI 0x61c5a4={ctrl:08x} → режим HDMI {"ВКЛЮЧЁН" if hdmi else "выключен"}; '
          f'пакет AVI {"отправляется" if avi_en & 1 else "НЕ отправляется"} (0x61c520={avi_en:08x}); '
          f'пакет звука {"отправляется" if aud_en & 1 else "нет"}')
    if not (avi_en & 1):
        continue
    h, s0l, s0h = rd(0x61c528 + o), rd(0x61c52c + o), rd(0x61c530 + o)
    b = [h & 0xff, (h >> 8) & 0xff, (h >> 16) & 0xff,
         s0l & 0xff, (s0l >> 8) & 0xff, (s0l >> 16) & 0xff, (s0l >> 24) & 0xff,
         s0h & 0xff, (s0h >> 8) & 0xff, (s0h >> 16) & 0xff]
    pb1, pb2, pb3, vic, pb5 = b[4], b[5], b[6], b[7], b[8]
    print(f'  AVI: тип {b[0]:02x} версия {b[1]} длина {b[2]}; байты {" ".join(f"{x:02x}" for x in b[3:])}')
    print(f'  формат цвета: {CF[(pb1 >> 5) & 3]}; диапазон RGB: {QR[(pb3 >> 2) & 3]}; '
          f'ИТ-содержимое (ITC): {"ДА" if pb3 & 0x80 else "нет"}; тип содержимого: {CN[(pb5 >> 4) & 3]}'
          f'{" (учитывается только при ITC=да)" if not pb3 & 0x80 else ""}; номер видеорежима VIC: {vic}; '
          f'масштаб/обрезка (SC, S): {(pb3 & 3)}, {pb1 & 3}')
