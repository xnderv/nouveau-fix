// СТЕНД ДЛЯ ЯДРА ГЕНЕРАТОРА СКРИПТОВ ПАМЯТИ DDR3 НА C (26.11.2026).
// Ядро — текст из лабораторного драйвера (fb/ramgf100.c, между LAB_G3_CORE_BEGIN и LAB_G3_CORE_END), вырезанный скриптом
// lab/memgen-ddr3-ctest.sh в файл g3-core.inc; здесь он собирается обычным компилятором без ядра Linux.
// Вход — блоки от «memgen-ddr3.py cases»: байты уровней VBIOS, пределы PLL, состояние регистров, записанные слова NVIDIA,
// слова и записи хоста питоновского генератора. Три сверки на каждый блок:
//   А  скрипт из состояния в момент пуска: C против питона (должно совпасть всегда) и C против записи NVIDIA;
//   Б  записи хоста до и после скрипта: C против питона;
//   В  как в драйвере: из состояния перед записями хоста — записи «до», затем скрипт; против записи NVIDIA
//      (регистр, которого в состоянии перед окном нет, берётся из состояния в момент пуска).
// В словах 0x132000 биты 16–17 (признаки захвата PLL, читаются железом) при сравнении с записью не учитываются.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;

#include "g3-core.inc"

struct regs { int n; u32 *reg, *val; };
struct tcase {
	char name[128];
	u32 tgt, cur;
	int on_pll, tgt_pll, display, first, hosted, f618;
	struct lab_g3_pll pll;
	struct lab_g3_level c, t, l;
	struct regs st, sp, dv, sa, as;
	u32 *xr, *xp, *hp, *hq;
	int nxr, nxp, nhp, nhq;
};
struct view { const struct regs *a, *b, *c, *first132; int unknown; };

static u32
rd(void *priv, u32 reg)
{
	struct view *v = priv;
	const struct regs *l[3] = { v->a, v->b, v->c };
	int k, i;

	/* 0x132000 (управление PLL памяти): запись в регистр и чтение из него дают разные числа — при чтении добавляются
	 * биты 27–28 и признаки захвата. «Последняя запись» из записи NVIDIA текущим значением не является, поэтому в
	 * сверке «как в драйвере» регистр берётся из состояния в момент пуска (там — чтение) */
	if (reg == 0x132000 && v->first132)
		for (i = 0; i < v->first132->n; i++)
			if (v->first132->reg[i] == reg)
				return v->first132->val[i];
	for (k = 0; k < 3; k++)
		for (i = 0; l[k] && i < l[k]->n; i++)
			if (l[k]->reg[i] == reg)
				return l[k]->val[i];
	v->unknown++;
	return 0;
}

static u32 *
nums(char **p, int n)
{
	u32 *a = calloc(n ? n : 1, sizeof(*a));
	int i;

	for (i = 0; i < n; i++)
		a[i] = strtoul(*p, p, 16);
	return a;
}

static void
bytes(char *p, u8 *dst, int max, const char *what)
{
	int n = strtoul(p, &p, 16), i;

	if (n > max) {
		fprintf(stderr, "запись %s длиннее буфера ядра: %d > %d\n", what, n, max);
		exit(2);
	}
	for (i = 0; i < n; i++)
		dst[i] = strtoul(p, &p, 16);
}

static void
regs(char *p, struct regs *r)
{
	int i;

	r->n = strtoul(p, &p, 16);
	r->reg = calloc(r->n ? r->n : 1, sizeof(u32));
	r->val = calloc(r->n ? r->n : 1, sizeof(u32));
	for (i = 0; i < r->n; i++) {
		r->reg[i] = strtoul(p, &p, 16);
		r->val[i] = strtoul(p, &p, 16);
	}
}

// 0 — не совпало, 1 — слово в слово, 2 — отличаются только признаки захвата PLL в значениях 0x132000
static int
same(const u32 *a, int na, const u32 *b, int nb)
{
	int i, r = 1;

	if (na != nb)
		return 0;
	for (i = 0; i < na; i++) {
		if (a[i] == b[i])
			continue;
		if (i && a[i - 1] == 0x132000 && b[i - 1] == 0x132000 && !((a[i] ^ b[i]) & ~0x00030000u)) {
			r = 2;
			continue;
		}
		return 0;
	}
	return r;
}

static void
setup(struct lab_g3 *g, const struct tcase *c, struct view *v)
{
	memset(g, 0, sizeof(*g));
	g->cur = c->c;
	g->tgt = c->t;
	g->low = c->l;
	g->pll = c->pll;
	g->tgt_mhz = c->tgt;
	g->on_pll = c->on_pll;
	g->tgt_pll = c->tgt_pll;
	g->display = c->display;
	g->f618 = c->f618;
	g->rd = rd;
	g->priv = v;
	g->run = -1;
}

static void
diff(const char *what, const u32 *a, int na, const u32 *b, int nb)
{
	int i, shown = 0;

	printf("      %s: слов %d против %d\n", what, na, nb);
	for (i = 0; i < na && i < nb && shown < 8; i++)
		if (a[i] != b[i]) {
			printf("        слово %d: ожидалось %08x, вышло %08x (перед ним %08x)\n", i, a[i], b[i], i ? a[i - 1] : 0);
			shown++;
		}
}

int
main(int argc, char **argv)
{
	static struct lab_g3 g;
	struct tcase c;
	char *line = NULL, *board = NULL;
	size_t cap = 0;
	FILE *f;
	bool verbose = argc > 2 && !strcmp(argv[2], "-v");
	int total = 0, distinct = 0, a_py = 0, a_rec = 0, a_stat = 0, b_pre = 0, b_post = 0, c_rec = 0, bad = 0;
	int bn = 0, bd = 0, bpy = 0, brec = 0, bflow = 0, bhost = 0;

	if (argc < 2 || !(f = fopen(argv[1], "r"))) {
		fprintf(stderr, "вызов: %s БЛОКИ.txt [-v]\n", argv[0]);
		return 2;
	}
	memset(&c, 0, sizeof(c));
	while (getline(&line, &cap, f) > 0) {
		char *p = line;

		if (!strncmp(p, "case ", 5)) {
			memset(&c, 0, sizeof(c));
			sscanf(p + 5, "%127s", c.name);
		} else if (!strncmp(p, "p ", 2)) {
			p += 2;
			c.tgt = strtoul(p, &p, 16);
			c.on_pll = strtoul(p, &p, 16);
			c.tgt_pll = strtoul(p, &p, 16);
			c.display = strtoul(p, &p, 16);
			c.first = strtoul(p, &p, 16);
			c.hosted = strtoul(p, &p, 16);
			c.cur = strtoul(p, &p, 16);
			c.f618 = strtoul(p, &p, 16);
		} else if (!strncmp(p, "pll ", 4)) {
			u32 *a;

			p += 4;
			a = nums(&p, 11);
			c.pll = (struct lab_g3_pll){ a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10] };
			free(a);
		} else if ((p[0] == 'T' || p[0] == 'R' || p[0] == 'M') && (p[1] == 'c' || p[1] == 't' || p[1] == 'l') && p[2] == ' ') {
			struct lab_g3_level *lv = p[1] == 'c' ? &c.c : p[1] == 't' ? &c.t : &c.l;

			if (p[0] == 'T')
				bytes(p + 3, lv->T, sizeof(lv->T), "таймингов");
			else if (p[0] == 'R')
				bytes(p + 3, lv->R, sizeof(lv->R), "ramcfg");
			else
				bytes(p + 3, lv->M, sizeof(lv->M), "rammap");
		} else if (!strncmp(p, "st ", 3)) {
			regs(p + 3, &c.st);
		} else if (!strncmp(p, "sp ", 3)) {
			regs(p + 3, &c.sp);
		} else if (!strncmp(p, "dv ", 3)) {
			regs(p + 3, &c.dv);
		} else if (!strncmp(p, "sa ", 3)) {
			regs(p + 3, &c.sa);
		} else if (!strncmp(p, "as ", 3)) {
			regs(p + 3, &c.as);
		} else if (!strncmp(p, "xr ", 3)) {
			p += 3;
			c.nxr = strtoul(p, &p, 16);
			c.xr = nums(&p, c.nxr);
		} else if (!strncmp(p, "xp ", 3)) {
			p += 3;
			c.nxp = strtoul(p, &p, 16);
			c.xp = nums(&p, c.nxp);
		} else if (!strncmp(p, "hp ", 3)) {
			p += 3;
			c.nhp = strtoul(p, &p, 16);
			c.hp = nums(&p, 2 * c.nhp);
		} else if (!strncmp(p, "hq ", 3)) {
			p += 3;
			c.nhq = strtoul(p, &p, 16);
			c.hq = nums(&p, 2 * c.nhq);
		} else if (!strncmp(p, "end", 3)) {
			struct view v = { &c.st, &c.as, NULL, NULL, 0 };
			char *hash, *bname;
			int py, rec, pre, post, flow, hl;
			bool okA, okB, okC;

			/* метка платы: до последнего '#' (в метках базы '#' есть и внутри) */
			hash = strrchr(c.name, '#');
			hl = hash ? (int)(hash - c.name) : (int)strlen(c.name);
			bname = strndup(c.name, hl);
			if (!board || strcmp(board, bname)) {
				if (board)
					printf("  %-28s скриптов %2d, разных %2d: C = питон %2d, C = запись NVIDIA %2d; из состояния до записей хоста = запись %2d; наборов записей хоста C = питон %d\n",
					       board, bn, bd, bpy, brec, bflow, bhost);
				free(board);
				board = bname;
				bn = bd = bpy = brec = bflow = bhost = 0;
			} else {
				free(bname);
			}

			/* А: скрипт из состояния в момент пуска */
			setup(&g, &c, &v);
			okA = lab_g3_target(&g) && lab_g3_script(&g);
			py = okA ? same(c.xp, c.nxp, g.scr, g.nscr) == 1 : 0;
			rec = okA ? same(c.xr, c.nxr, g.scr, g.nscr) : 0;
			if (!py) {
				bad++;
				printf("   !! %s: C не совпал с питоном%s%s\n", c.name, g.err ? " — отказ: " : "", g.err ? g.err : "");
				if (okA)
					diff("питон против C", c.xp, c.nxp, g.scr, g.nscr);
			} else if (verbose && !rec && c.first) {
				printf("      %s: C = питон, но не запись NVIDIA\n", c.name);
				diff("запись против C", c.xr, c.nxr, g.scr, g.nscr);
			}

			/* Б: записи хоста — «до» из состояния перед окном, «после» из состояния после скрипта */
			v = (struct view){ &c.sp, &c.dv, NULL, NULL, 0 };
			setup(&g, &c, &v);
			okB = lab_g3_pre(&g);
			pre = okB && g.npre == c.nhp && !memcmp(g.pre, c.hp, 2 * c.nhp * sizeof(u32));
			v = (struct view){ &c.sa, NULL, NULL, NULL, 0 };
			setup(&g, &c, &v);
			okB = lab_g3_post(&g);
			post = okB && g.npost == c.nhq && !memcmp(g.post, c.hq, 2 * c.nhq * sizeof(u32));
			if (!pre || !post) {
				bad++;
				printf("   !! %s: записи хоста C не совпали с питоном (до: %s, после: %s)\n", c.name, pre ? "да" : "нет", post ? "да" : "нет");
			}

			/* В: как в драйвере — состояние перед записями хоста, записи «до», затем скрипт. Чего в состоянии перед
			 * окном нет (регистр до того в записи не встречался), берётся из состояния в момент пуска: так в сверку
			 * не попадает модель состояния после включения, которая для части регистров неточна */
			v = (struct view){ &c.sp, &c.st, &c.as, &c.st, 0 };
			setup(&g, &c, &v);
			okC = lab_g3_target(&g) && lab_g3_pre(&g) && lab_g3_script(&g);
			flow = okC ? same(c.xr, c.nxr, g.scr, g.nscr) : 0;
			if (verbose && c.first && rec && !flow) {
				printf("      %s: из состояния до записей хоста скрипт отличается от записи\n", c.name);
				diff("запись против C", c.xr, c.nxr, g.scr, g.nscr);
			}

			total++;
			bn++;
			b_pre += pre;
			b_post += post;
			bhost += pre + post;
			if (c.first) {
				distinct++;
				bd++;
				a_py += py;
				bpy += py;
				a_rec += rec != 0;
				brec += rec != 0;
				a_stat += rec == 2;
				c_rec += flow != 0;
				bflow += flow != 0;
			}
			free(c.st.reg); free(c.st.val); free(c.sp.reg); free(c.sp.val); free(c.sa.reg); free(c.sa.val);
			free(c.as.reg); free(c.as.val); free(c.dv.reg); free(c.dv.val); free(c.xr); free(c.xp); free(c.hp); free(c.hq);
			memset(&c, 0, sizeof(c));
		}
	}
	if (board)
		printf("  %-28s скриптов %2d, разных %2d: C = питон %2d, C = запись NVIDIA %2d; из состояния до записей хоста = запись %2d; наборов записей хоста C = питон %d\n",
		       board, bn, bd, bpy, brec, bflow, bhost);
	printf("ИТОГ: скриптов %d, разных %d. А: C = питон %d из %d; C = запись NVIDIA %d из %d (из них %d — с точностью до признаков захвата PLL).\n"
	       "      Б: записи хоста C = питон: до %d из %d, после %d из %d. В: из состояния до записей хоста = запись NVIDIA %d из %d.\n"
	       "      Расхождений C с питоном: %d\n",
	       total, distinct, a_py, distinct, a_rec, distinct, a_stat, b_pre, total, b_post, total, c_rec, distinct, bad);
	return bad ? 1 : 0;
}
