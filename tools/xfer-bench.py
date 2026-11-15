#!/usr/bin/env python3
# ЗАМЕР ПЕРЕДАЧИ ДАННЫХ (15.11): сколько ГБ/с проходит по трём путям, без окна, на узле рендеринга (EGL surfaceless).
#   up    — загрузка с компьютера в буфер на карте (glBufferSubData): PCIe → хаб → кросс-бар → L2 → видеопамять
#   down  — чтение с карты в компьютер (буфер заполнен на карте, glMapBufferRange на чтение): обратный путь
#   copy  — копия видеопамять → видеопамять на самой карте (glCopyBufferSubData): без PCIe, через блок копирования хаба
# Только библиотеки системы (libEGL, libGLESv2) через ctypes — заголовки и пакеты не нужны.
#   python3 -I tools/xfer-bench.py [МБ=64] [секунд на замер=1.5] [повторов=3]
# Печатает строки «XFER путь: медиана ГБ/с (замеры …)». Время включает работу процессора (memcpy), поэтому важны не сами
# ГБ/с, а их изменение между вариантами частот узлов.
import ctypes as C, sys, time, statistics

MB = int(sys.argv[1]) if len(sys.argv) > 1 else 64
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 1.5
REPS = int(sys.argv[3]) if len(sys.argv) > 3 else 3
N = MB << 20

egl = C.CDLL('libEGL.so.1')
gl = C.CDLL('libGLESv2.so.2')
P, I, U = C.c_void_p, C.c_int, C.c_uint
for name, res, args in [
    ('eglGetPlatformDisplay', P, [U, P, P]), ('eglInitialize', I, [P, P, P]), ('eglBindAPI', I, [U]),
    ('eglChooseConfig', I, [P, P, P, I, P]), ('eglCreateContext', P, [P, P, P, P]),
    ('eglMakeCurrent', I, [P, P, P, P]), ('eglGetError', I, []), ('eglTerminate', I, [P])]:
    f = getattr(egl, name); f.restype = res; f.argtypes = args
for name, res, args in [
    ('glGetString', C.c_char_p, [U]), ('glGenBuffers', None, [I, P]), ('glBindBuffer', None, [U, U]),
    ('glBufferData', None, [U, C.c_ssize_t, P, U]), ('glBufferSubData', None, [U, C.c_ssize_t, C.c_ssize_t, P]),
    ('glCopyBufferSubData', None, [U, U, C.c_ssize_t, C.c_ssize_t, C.c_ssize_t]),
    ('glMapBufferRange', P, [U, C.c_ssize_t, C.c_ssize_t, U]), ('glUnmapBuffer', U, [U]),
    ('glFinish', None, []), ('glGetError', U, [])]:
    f = getattr(gl, name); f.restype = res; f.argtypes = args

EGL_PLATFORM_SURFACELESS_MESA, EGL_NONE, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT = 0x31DD, 0x3038, 0x3040, 0x40
EGL_OPENGL_ES_API, EGL_CONTEXT_MAJOR_VERSION = 0x30A0, 0x3098
ARRAY, CREAD, CWRITE = 0x8892, 0x8F36, 0x8F37
STATIC_DRAW, STREAM_READ, DYNAMIC_COPY = 0x88E4, 0x88E1, 0x88EA
MAP_READ = 0x0001

def die(msg):
    print('XFER ошибка:', msg, 'egl', hex(egl.eglGetError())); sys.exit(2)

dpy = egl.eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, None, None) or die('нет дисплея surfaceless')
egl.eglInitialize(dpy, None, None) or die('eglInitialize')
egl.eglBindAPI(EGL_OPENGL_ES_API) or die('eglBindAPI')
attr = (I * 3)(EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE)
cfg, n = P(), I()
if not (egl.eglChooseConfig(dpy, attr, C.byref(cfg), 1, C.byref(n)) and n.value):
    cfg = P()                                  # EGL_KHR_no_config_context: контекст без конфигурации (Mesa умеет)
cattr = (I * 3)(EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE)
ctx = egl.eglCreateContext(dpy, cfg, None, cattr) or die('eglCreateContext')
egl.eglMakeCurrent(dpy, None, None, ctx) or die('eglMakeCurrent без поверхности')
renderer = gl.glGetString(0x1F01).decode()
print(f'XFER рендерер: {renderer}; {gl.glGetString(0x1F02).decode()}; буфер {MB} МБ, {SECS} с × {REPS}')
if 'llvmpipe' in renderer or 'softpipe' in renderer:
    die('программный рендерер — это не карта')

bufs = (U * 3)(); gl.glGenBuffers(3, bufs)
src = (C.c_ubyte * N)()
C.memset(src, 0x5a, N)
for b, use in zip(bufs, (STATIC_DRAW, DYNAMIC_COPY, STREAM_READ)):
    gl.glBindBuffer(ARRAY, b); gl.glBufferData(ARRAY, N, src, use)
gl.glFinish()
e = gl.glGetError()
if e: die(f'GL {hex(e)} при создании буферов')

def run(step):
    """Повторять step() SECS секунд, затем glFinish; вернуть ГБ/с."""
    step(); gl.glFinish()                      # прогрев: первая передача может выделять память
    k, t0 = 0, time.perf_counter()
    while True:
        step(); k += 1
        if k % 4 == 0:
            gl.glFinish()
            if time.perf_counter() - t0 >= SECS: break
    gl.glFinish()
    return k * N / (time.perf_counter() - t0) / 1e9

def up():
    gl.glBindBuffer(ARRAY, bufs[0]); gl.glBufferSubData(ARRAY, 0, N, src)

def copy():
    gl.glBindBuffer(CREAD, bufs[0]); gl.glBindBuffer(CWRITE, bufs[1]); gl.glCopyBufferSubData(CREAD, CWRITE, 0, 0, N)

dst = (C.c_ubyte * N)()
def down():
    gl.glBindBuffer(CREAD, bufs[1]); gl.glBindBuffer(CWRITE, bufs[2]); gl.glCopyBufferSubData(CREAD, CWRITE, 0, 0, N)
    gl.glBindBuffer(ARRAY, bufs[2])
    p = gl.glMapBufferRange(ARRAY, 0, N, MAP_READ) or die('glMapBufferRange')
    C.memmove(dst, p, N); gl.glUnmapBuffer(ARRAY)

# «down» включает копию на карте; её вклад виден по строке copy
for name, fn in (('up', up), ('down', down), ('copy', copy)):
    r = [run(fn) for _ in range(REPS)]
    e = gl.glGetError()
    if e: die(f'GL {hex(e)} в замере {name}')
    print(f'XFER {name}: {statistics.median(r):.3f} ГБ/с (замеры {" ".join(f"{x:.3f}" for x in r)})')
if dst[0] != 0x5a or dst[N - 1] != 0x5a:
    die('прочитанные данные не совпали с записанными')
print('XFER данные сверены')
egl.eglMakeCurrent(dpy, None, None, None); egl.eglTerminate(dpy)
