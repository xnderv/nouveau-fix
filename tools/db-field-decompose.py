import json, collections
W=json.load(open('fermi_writes.json'))
# поля: (имя, младший бит, старший бит)
PLLCTL=[('ENABLE',0,0),('IDDQ(выкл.питания)',1,1),('UNK2',2,2),('ENB_LCKDET',4,4),('UNK12',12,15),('PLL_PWR?',16,16),('LOCK(чт)',17,17)]
COEF=[('M',0,7),('N',8,15),('P',16,21)]
REFSRC=[('SRC',0,3),('UNK8',8,12),('SRC0 27/108',16,17),('SRC2 подвыбор',24,26),('B31',31,31)]
DIVCTL=[('поле A (BYPDIV)',0,5),('поле B (VCODIV)',8,13),('B31 (SDIV14/вкл)',31,31)]
DIVSRC=[('SRC',0,3),('VCO=SPPLL1',8,8),('SRC0 27/108',16,17),('B31',31,31)]
FSRM2=[('B: глубина по команде',0,5),('флаг 7',7,7),('FSRM2 8–15',8,15),('A: глубина в простое',16,21),('UNK24',24,31)]
REGS={
 0x137000:('PLL GPC2CLK: управление',PLLCTL),0x137020:('PLL LTC2CLK: управление',PLLCTL),0x137040:('PLL XBAR2CLK: управление',PLLCTL),0x1370e0:('PLL SYS2CLK (SYSPLL): управление',PLLCTL),
 0x137004:('PLL GPC2CLK: коэфф.',COEF),0x137024:('PLL LTC2CLK: коэфф.',COEF),0x137044:('PLL XBAR2CLK: коэфф.',COEF),0x1370e4:('PLL SYS2CLK: коэфф.',COEF),
 0x137100:('переключатель',[('GPC',0,0),('LTC',1,1),('XBAR',2,2),('SYS',7,7),('HUB',8,8),('copy',9,9),('PWR',12,12),('MSD',14,14),('прочие биты',3,6)]),
 0x137120:('опора PLL GPC: источник',REFSRC),0x137124:('опора PLL LTC: источник',REFSRC),0x137128:('опора PLL XBAR: источник',REFSRC),0x13713c:('опора PLL SYS: источник',REFSRC),
 0x137140:('опора PLL GPC: делитель',DIVCTL),0x137144:('опора PLL LTC: делитель',DIVCTL),0x137148:('опора PLL XBAR: делитель',DIVCTL),0x13715c:('опора PLL SYS: делитель',DIVCTL),
 0x137160:('источник делителя GPC',DIVSRC),0x137164:('источник делителя LTC',DIVSRC),0x137168:('источник делителя XBAR',DIVSRC),0x13717c:('источник делителя SYS',DIVSRC),0x137180:('источник делителя HUB',DIVSRC),0x137184:('источник делителя copy',DIVSRC),0x137190:('источник делителя PWR',DIVSRC),0x137198:('источник делителя MSD',DIVSRC),0x1371c8:('источник CLK26',DIVSRC),0x1371cc:('источник CLK27',DIVSRC),
 0x1371d0:('основной делитель GPC',DIVCTL),0x1371d4:('основной делитель LTC',DIVCTL),0x1371d8:('основной делитель XBAR',DIVCTL),
 0x137250:('пост-делитель GPC (GPC2CLK_OUT)',DIVCTL),0x137254:('пост-делитель LTC',DIVCTL),0x137258:('пост-делитель XBAR',DIVCTL),0x13726c:('пост-делитель SYS',DIVCTL),0x137270:('пост-делитель HUB',DIVCTL),0x137274:('пост-делитель copy',DIVCTL),0x137280:('пост-делитель PWR',DIVCTL),0x137288:('пост-делитель MSD',DIVCTL),
 0x020160:('замедление GPC (FSRM_2)',FSRM2),0x020164:('замедление SYS (FSRM_2)',FSRM2),0x020180:('замедление GPC (FSRM_3)',[('код 0–5',0,5),('прочее',6,31)]),0x020184:('замедление SYS (FSRM_3)',[('код 0–5',0,5),('прочее',6,31)]),
 0x0201a0:('замедление GPC (FSRM_4)',[('биты 6 и 14 (0x4040)',0,31)]),0x0201a4:('замедление SYS (FSRM_4)',[('биты 6 и 14',0,31)]),
 0x020004:('PTHERM CTRL_1',[('бит 3',3,3),('бит 5',5,5),('бит 6',6,6),('бит 16',16,16),('бит 20',20,20),('прочее',0,31)]),
 0x00e9e0:('0x00e9e0 (делитель?)',DIVCTL),
}
def fields(v,fl): return [(n,(v>>lo)&((1<<(hi-lo+1))-1)) for n,lo,hi in fl]
for a,(name,fl) in REGS.items():
    k=hex(a)
    if k not in W: print(f'{k} {name}: NVIDIA не пишет'); continue
    vals=W[k]['vals']; chips=W[k]['chips']
    print(f'{k} {name}  [{len(vals)} знач., чипы {",".join(c[2:] for c in chips)}]')
    for n,lo,hi in fl:
        c=collections.Counter()
        for vs,cnt in vals.items(): c[(int(vs,16)>>lo)&((1<<(hi-lo+1))-1)]+=cnt
        s=', '.join(f'{x:#x}×{y}' for x,y in c.most_common(6))
        print(f'    {n:24} {s}')
