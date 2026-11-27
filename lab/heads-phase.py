#!/usr/bin/env python3
# Two active screens on one card: how far apart in time are their frames?
#
# READ ONLY: it maps the card's registers read-only and reads the display line counters and the mode registers of the two
# display heads (the same registers the nouveau driver reads for vblank timestamps). It writes nothing and needs no
# special driver build. Applies to cards with the NV50-style display unit: up to GF116 (not GF119 / GT 610 class).
#
# Why: a memory clock change has to fit into the gap between two frames (the vertical blanking) of every active screen.
# The driver waits for that gap on ONE head; whether the other head is in its own gap at that moment depends on how the
# two frame timings are shifted against each other. This tool measures that shift.
#
#   sudo python3 lab/heads-phase.py            (about 3 seconds; add a PCI address such as 0000:01:00.0 to pick a card)
#
# Output: for each head its mode, blanking length and frame rate measured from the line counter; for the pair the shift
# between the frames, whether it is constant, how long both heads are in blanking at the same time, and where the other
# head is when the head the driver waits on enters blanking.
import glob, mmap, os, re, struct, sys, time

SAMPLES, GAP_S = 1500, 0.002


class Head:
    """Mode of one head, from the 'armed' copies of the timing registers (as nouveau's nv50_head_state reads them)."""

    def __init__(self, i, rd):
        o = i * 0x540 + 4
        be, bs, tot = rd(0x610ae8 + o), rd(0x610af0 + o), rd(0x610af8 + o)
        self.id = i
        self.vblanke, self.hblanke = be >> 16, be & 0xffff      # last line / column of blanking
        self.vblanks, self.hblanks = bs >> 16, bs & 0xffff      # last visible line / column
        self.vtotal, self.htotal = tot >> 16, tot & 0xffff
        self.khz = rd(0x610ad0 + o) & 0x3fffff                  # pixel clock, kHz
        size = rd(0x610b40 + i * 0x540)
        self.xres, self.yres = size & 0xffff, size >> 16
        self.active = bool(rd(0x610050) & (2 << (i * 8)))
        self.sane = self.vtotal > 100 and self.htotal > 100 and self.khz > 1000 and self.vblanke < self.vblanks < self.vtotal
        if self.sane:
            self.line_us = self.htotal * 1000.0 / self.khz
            self.frame_us = self.vtotal * self.line_us
            self.blank_lines = self.vtotal - self.vblanks + self.vblanke
            self.blank_us = self.blank_lines * self.line_us
            self.blank_start_us = (self.vblanks + 1) * self.line_us    # from the start of the raster (line 0) to blanking

    def pos_us(self, vline, hline):
        """Time since the start of the raster (line 0, column 0) for a line counter reading."""
        return (vline * self.htotal + min(hline, self.htotal - 1)) * 1000.0 / self.khz

    def where(self, us):
        """Describe a moment given as time since the start of the raster."""
        line = int(us % self.frame_us / self.line_us + 0.5) % self.vtotal      # nearest line
        if line > self.vblanks or line <= self.vblanke:
            left = ((self.vblanke + 1 - line) % self.vtotal) * self.line_us
            return f'line {line}: in blanking, the picture starts {left:.0f} us later', left
        vis = line - self.vblanke - 1
        return f'line {line}: in the visible part, {100.0 * vis / (self.vblanks - self.vblanke):.0f}% of the way down the picture', 0.0


def wrap(x, period):
    """Fold x into (-period/2, period/2]."""
    x %= period
    return x - period if x > period / 2 else x


def fit(xs, ys):
    """Least squares line: returns slope, value at xs[0], largest deviation from the line."""
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    k = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx if sxx else 0.0
    b = my - k * mx
    return k, b + k * xs[0], max(abs(y - (b + k * x)) for x, y in zip(xs, ys))


def raster_starts(head, samples, col):
    """Unwrapped 'time of the raster start' for every sample of one head: flat if the period from the mode is exact."""
    out, prev, acc = [], None, 0.0
    for s in samples:
        start = s[col] - head.pos_us(s[col + 1], s[col + 2])
        if prev is not None:
            acc += wrap(start - prev, head.frame_us)
        out.append(acc)
        prev = start
    return out


def analyse(heads, samples, sync):
    """heads: two sane Head objects; samples: (t0, v0, h0, t1, v1, h1) with times in us. Returns a list of text lines."""
    h0, h1 = heads
    out = []
    ts = [s[0] for s in samples]
    span = (ts[-1] - ts[0]) / 1e6
    rate = []
    for h, col in ((h0, 0), (h1, 3)):
        k, _, dev = fit([s[col] for s in samples], raster_starts(h, samples, col))
        period = h.frame_us * (1.0 + k)
        rate.append(1e6 / period)
        out.append(f'head {h.id}: frame rate by the line counter {1e6 / period:.4f} Hz (from the mode {1e6 / h.frame_us:.4f} Hz); '
                   f'readings scatter up to {dev:.0f} us around a steady rate')
    if abs(h0.frame_us - h1.frame_us) / h0.frame_us > 0.002:
        beat = 1.0 / abs(rate[0] - rate[1])
        out.append(f'The two heads run at DIFFERENT frame rates: the frames slide past each other, one full turn every {beat:.3f} s.')
        out.append('There is no fixed shift between them; whether both are in blanking at once changes from frame to frame.')
        return out
    period = h0.frame_us
    # shift: how much later head 1 starts its raster than head 0, folded into one frame
    d0 = None
    ds = []
    for s in samples:
        d = (s[3] - h1.pos_us(s[4], s[5])) - (s[0] - h0.pos_us(s[1], s[2]))
        d0 = d if d0 is None else d0
        ds.append(d0 + wrap(d - d0, period))
    k, at0, dev = fit(ts, ds)
    med = sorted(ds)[len(ds) // 2] % period
    drift = k * 1e6                                     # us per second
    out.append(f'Shift between the frames: head 1 starts its frame {med:.0f} us after head 0 '
               f'({med / h0.line_us:.0f} lines of head 0, {100.0 * med / period:.1f}% of a frame); '
               f'readings scatter up to {dev:.0f} us.')
    if abs(drift) * max(span, 1e-9) < 3 * max(dev, h0.line_us):
        out.append(f'The shift is CONSTANT over the {span:.1f} s measured (trend {drift:+.1f} us per second, within the scatter).')
    else:
        turn = period / abs(drift)
        part = min(1.0, (h0.blank_us + h1.blank_us) / period)
        out.append(f'The shift DRIFTS by {drift:+.1f} us per second: the frames slide past each other, one full turn in {turn:.1f} s '
                   f'(the shift above is the middle of the measurement).')
        out.append(f'Blanking: head 0 {h0.blank_us:.0f} us, head 1 {h1.blank_us:.0f} us. Both heads are in blanking at the same time '
                   f'during about {100.0 * part:.0f}% of each turn ({turn * part:.1f} s out of {turn:.1f} s); the rest of the time they are not.')
        return out
    # blanking of head 0: [a0, a0 + B0); of head 1: [med + a1, med + a1 + B1), both from the raster start of head 0
    d = wrap(med + h1.blank_start_us - h0.blank_start_us, period)       # head 1 enters blanking d after head 0
    common = max(0.0, min(h0.blank_us, d + h1.blank_us) - max(0.0, d))
    out.append(f'Blanking: head 0 {h0.blank_us:.0f} us, head 1 {h1.blank_us:.0f} us; head 1 enters blanking '
               f'{abs(d):.0f} us {"after" if d >= 0 else "before"} head 0.')
    out.append(f'BOTH heads are in blanking at the same time for {common:.0f} us in every frame.' if common > 0 else
               'The two blanking intervals do NOT overlap: there is no moment when both heads are between frames.')
    s, o = (h0, h1) if sync == 0 else (h1, h0)
    # the other head, at the moment the sync head enters blanking (time since the other head's raster start)
    at = (s.blank_start_us - med) if o is h1 else (s.blank_start_us + med)
    text, left = o.where(at)
    out.append(f'The driver waits for the blanking of head {s.id}. At that moment head {o.id} is at {text}.')
    return out


def find_card(want):
    for d in sorted(glob.glob('/sys/bus/pci/devices/*')):
        try:
            if want and os.path.basename(d) != want:
                continue
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
                return d
        except OSError:
            pass
    return None


def connectors():
    """Which connector is on which head, from the DRM state dump (debugfs); empty if it cannot be read."""
    res = {}
    for f in glob.glob('/sys/kernel/debug/dri/*/state'):
        try:
            txt = open(f).read()
        except OSError:
            continue
        for m in re.finditer(r'^connector\[\d+\]: (\S+)\n\tcrtc=crtc-(\d+)', txt, re.M):
            res.setdefault(int(m.group(2)), []).append(m.group(1))
        if res:
            break
    return res


def main():
    dev = find_card(sys.argv[1] if len(sys.argv) > 1 else None)
    if not dev:
        sys.exit('No NVIDIA display card found.')
    try:
        fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
        bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
    except OSError as e:
        sys.exit(f'Cannot map the card registers ({e}). Run with sudo; with Secure Boot / kernel lockdown this is not allowed.')
    rd = lambda a: struct.unpack_from('<I', bar, a)[0]
    chip = (rd(0) >> 20) & 0x1ff
    try:
        drv = os.path.basename(os.readlink(dev + '/driver'))
    except OSError:
        drv = 'none'
    print(f'card: chipset NV{chip:02X}, driver {drv}; {time.strftime("%F %T")}')
    if not 0x50 <= chip < 0xd0:
        sys.exit('This display unit has a different register layout (GF119 and later): the tool does not apply.')
    heads = [Head(i, rd) for i in (0, 1)]
    conn = connectors()
    for h in heads:
        name = ', '.join(conn.get(h.id, [])) or 'connector not known'
        if not h.sane:
            print(f'head {h.id}: off ({name})')
            continue
        print(f'head {h.id}: {"ACTIVE" if h.active else "not active"}, {name}; picture {h.xres}x{h.yres}, raster {h.htotal}x{h.vtotal}, '
              f'pixel clock {h.khz} kHz; one line {h.line_us:.2f} us, frame {h.frame_us / 1000:.3f} ms, '
              f'blanking {h.blank_lines} lines = {h.blank_us:.0f} us (visible lines {h.vblanke + 1}..{h.vblanks})')
    print('raw: 0x610050=%08x 0x611200=%08x 0x616308=%08x 0x616b08=%08x' % (rd(0x610050), rd(0x611200), rd(0x616308), rd(0x616b08)))
    print('outputs (armed owner registers): ' + ' '.join(f'{a:06x}={rd(a):x}' for a in
          (0x610b5c, 0x610b64, 0x610b6c, 0x610798, 0x6107a0, 0x6107a8, 0x6107b0, 0x610b84, 0x610b8c, 0x610b94)))
    live = [h for h in heads if h.sane and h.active]
    # the head the driver's frame wait picks (nvkm_memx_wait_vblank): most pixels, head 0 on a tie
    sync, px = None, 0
    for h in live:
        if h.xres * h.yres > px:
            sync, px = h.id, h.xres * h.yres
    if len(live) < 2:
        print(f'Only {len(live)} active head: nothing to compare. (The frame wait of the driver goes to head {sync}.)')
        if not live:
            return
    now = time.perf_counter_ns
    samples = []
    for _ in range(SAMPLES):
        a = now()
        v0 = rd(0x616340) & 0xffff      # reading the line latches the column until it is read
        c0 = rd(0x616344) & 0xffff
        b = now()
        v1 = rd(0x616b40) & 0xffff
        c1 = rd(0x616b44) & 0xffff
        c = now()
        if c - a < 40000:                # drop readings interrupted by something else
            samples.append((a / 1000.0, v0, c0, b / 1000.0, v1, c1))
        time.sleep(GAP_S)
    print(f'{len(samples)} readings of both line counters; largest line seen: head 0 {max(s[1] for s in samples)}, head 1 {max(s[4] for s in samples)}')
    if len(samples) < 100:
        sys.exit('Too few clean readings.')
    if len(live) == 2:
        for line in analyse(heads, samples, sync):
            print(line)
    else:
        h = live[0]
        col = 0 if h.id == 0 else 3
        k, _, dev = fit([s[col] for s in samples], raster_starts(h, samples, col))
        print(f'head {h.id}: frame rate by the line counter {1e6 / (h.frame_us * (1.0 + k)):.4f} Hz (from the mode {1e6 / h.frame_us:.4f} Hz); '
              f'readings scatter up to {dev:.0f} us around a steady rate')


if __name__ == '__main__':
    main()
