#!/usr/bin/env python3
"""生成 dsh-Go 的新图标（纯矢量）。

设计：自举环 + 提示符 —— 一个 3/4 圆的环（缺口在右侧），缺口里是一个 `>` 提示符。
环 = 自举/闭环，`>` = 终端；两者合起来表达「手机里自己造自己的 AI 工作台」。

产物：
  Android（adaptive icon）
    res/drawable/ic_launcher_foreground.xml           默认
    res/drawable/ic_launcher_night_foreground.xml     夜间
    res/drawable/ic_launcher_frost_foreground.xml     霜
    res/drawable/ic_launcher_ink_foreground.xml       墨
    res/drawable/ic_launcher_monochrome.xml           单色（Android 13 主题图标）
    res/drawable/ic_launcher*_background.xml          4 套背景渐变
    res/mipmap-anydpi-v26/ic_launcher*.xml            foreground 指向 drawable
  品牌（App 内 brand mark，由 tool/make_brand_mark.py 再转成 dart）
    app/assets/brand/glyph-light.svg / glyph-dark.svg / glyph-mono.svg / tile.svg
  预览（不参与构建）
    /sdcard/Download/DSH-Loop/icon-preview/*.png
"""
import math, pathlib, subprocess

REPO = pathlib.Path(__file__).resolve().parents[1]
RES = REPO / 'app/android/app/src/main/res'
BRAND = REPO / 'app/assets/brand'
PREVIEW = pathlib.Path('/sdcard/Download/DSH-Loop/icon-preview')

# ── 几何（108 网格，安全区半径 33 居中）──────────────────────────────────────
CX, CY, R, STROKE = 54.0, 54.0, 23.5, 7.4
GAP_DEG = 34.0                     # 缺口半角（右开）
CHEV = [(59.5, 44.5), (69.0, 54.0), (59.5, 63.5)]
CHEV_STROKE = 7.0

def arc_path():
    a = math.radians(GAP_DEG)
    x = CX + R * math.cos(a); y1 = CY - R * math.sin(a); y2 = CY + R * math.sin(a)
    return f"M{x:.2f} {y1:.2f} A{R} {R} 0 1 0 {x:.2f} {y2:.2f}"

def chev_path():
    (x0, y0), (x1, y1), (x2, y2) = CHEV
    return f"M{x0} {y0} L{x1} {y1} L{x2} {y2}"

def union_hint(prefix):
    """单色版本：环与提示符同色，读作一个整体。"""
    return (f"{prefix}<path android:pathData=\"{arc_path()}\" android:strokeWidth=\"{STROKE}\" "
            f"android:strokeLineCap=\"round\" android:strokeColor=\"#FFFFFFFF\" android:fillColor=\"#00000000\"/>\n"
            f"{prefix}<path android:pathData=\"{chev_path()}\" android:strokeWidth=\"{CHEV_STROKE}\" "
            f"android:strokeLineCap=\"round\" android:strokeLineJoin=\"round\" android:strokeColor=\"#FFFFFFFF\" "
            f"android:fillColor=\"#00000000\"/>\n")

def foreground_xml(ring: str, chev: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Launcher foreground: 自举环（3/4 圆，右侧开口）+ 缺口里的 `>` 提示符。
     Ring = 自举/闭环，chevron = 终端；合起来是「手机里自己造自己的 AI 工作台」。
     生成脚本：fix/11-make-app-icon.py（改图形请改脚本后重跑）。 -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:pathData="{arc_path()}"
        android:strokeWidth="{STROKE}"
        android:strokeLineCap="round"
        android:strokeColor="{ring}"
        android:fillColor="#00000000" />
    <path
        android:pathData="{chev_path()}"
        android:strokeWidth="{CHEV_STROKE}"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeColor="{chev}"
        android:fillColor="#00000000" />
</vector>
"""

def monochrome_xml() -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Themed-icon (Android 13+) layer: 自举环 + 提示符的剪影，与前景同位置。 -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
{union_hint('    ')}</vector>
"""

def background_xml(stops, note: str) -> str:
    items = '\n'.join(f'                <item android:offset="{o}" android:color="{c}" />' for o, c in stops)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Launcher background: {note} -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="7.57"
                android:startY="-5.87"
                android:endX="100.43"
                android:endY="113.87">
{items}
            </gradient>
        </aapt:attr>
    </path>
</vector>
"""

def adaptive_xml(bg: str, fg: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Adaptive launcher icon (API 26+): 背景渐变 + 自举环/提示符前景（纯矢量）+ 单色层。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/{bg}" />
    <foreground android:drawable="@drawable/{fg}" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"""


# ── 填充路径（供 App 内 brand mark 用：生成器只接受填充路径的 M/C/Z）────────
K = 0.5522847498307936  # 圆用三次贝塞尔的系数

def _arc_cubics(cx, cy, r, a0, a1):
    """圆心角 a0→a1（弧度，屏幕坐标 y 向下）的圆弧，拆成 ≤90° 的三次贝塞尔。"""
    out, n = [], max(1, int(abs(a1 - a0) / (math.pi / 2) + 0.999))
    step = (a1 - a0) / n
    for i in range(n):
        t0 = a0 + step * i; t1 = t0 + step; t = (t1 - t0) / 2
        k = 4 / 3 * math.tan(t / 2)
        p0 = (cx + r * math.cos(t0), cy + r * math.sin(t0))
        p3 = (cx + r * math.cos(t1), cy + r * math.sin(t1))
        p1 = (p0[0] - k * r * math.sin(t0), p0[1] + k * r * math.cos(t0))
        p2 = (p3[0] + k * r * math.sin(t1), p3[1] - k * r * math.cos(t1))
        out.append(f'C{p1[0]:.3f} {p1[1]:.3f} {p2[0]:.3f} {p2[1]:.3f} {p3[0]:.3f} {p3[1]:.3f}')
    return out

def _circle(cx, cy, r):
    k = K * r
    return (f'M{cx - r:.3f} {cy:.3f}'
            f'C{cx - r:.3f} {cy - k:.3f} {cx - k:.3f} {cy - r:.3f} {cx:.3f} {cy - r:.3f}'
            f'C{cx + k:.3f} {cy - r:.3f} {cx + r:.3f} {cy - k:.3f} {cx + r:.3f} {cy:.3f}'
            f'C{cx + r:.3f} {cy + k:.3f} {cx + k:.3f} {cy + r:.3f} {cx:.3f} {cy + r:.3f}'
            f'C{cx - k:.3f} {cy + r:.3f} {cx - r:.3f} {cy + k:.3f} {cx - r:.3f} {cy:.3f}Z')

def _poly_area(pts):
    a = 0.0
    for (x1, y1), (x2, y2) in zip(pts, pts[1:] + pts[:1]):
        a += x1 * y2 - x2 * y1
    return a / 2

def _norm(pts):
    """统一绕向（屏幕坐标下取正向）：否则重叠块会被非零填充规则挖空。"""
    return pts if _poly_area(pts) > 0 else list(reversed(pts))

def _emit(pts):
    """折线 → 只含 M / 退化 C / Z 的路径串（brand mark 生成器只认这三种）。"""
    (x0, y0), rest = pts[0], pts[1:]
    out = [f'M{x0:.3f} {y0:.3f}']
    for x, y in rest:
        out.append(f'C{x:.3f} {y:.3f} {x:.3f} {y:.3f} {x:.3f} {y:.3f}')
    return ' '.join(out) + ' Z'

def _circle_pts(cx, cy, r, n=48):
    return _norm([(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)])

def _arc_pts(cx, cy, r, a0, a1, n=64):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]

def filled_ring_paths():
    """3/4 环（环段多边形）+ 两个端点圆。"""
    a = math.radians(GAP_DEG)
    ro, ri = R + STROKE / 2, R - STROKE / 2
    a0 = -a                      # 缺口上端
    a1 = -a - (2 * math.pi - 2 * a)  # 顺时针绕长弧到缺口下端
    outer = _arc_pts(CX, CY, ro, a0, a1)
    inner = _arc_pts(CX, CY, ri, a1, a0)
    ring = _norm(outer + inner)
    caps = [_circle_pts(CX + R * math.cos(t), CY + R * math.sin(t), STROKE / 2) for t in (a0, a1)]
    return [ring] + caps

def filled_chevron_paths():
    """提示符 = 两条粗线段（矩形）+ 三个圆角点。"""
    (x0, y0), (x1, y1), (x2, y2) = CHEV
    h = CHEV_STROKE / 2
    def bar(ax, ay, bx, by):
        dx, dy = bx - ax, by - ay
        L = math.hypot(dx, dy); ux, uy = dx / L, dy / L; nx, ny = -uy, ux
        return _norm([(ax + nx * h, ay + ny * h), (bx + nx * h, by + ny * h),
                      (bx - nx * h, by - ny * h), (ax - nx * h, ay - ny * h)])
    circles = [_circle_pts(x0, y0, h), _circle_pts(x1, y1, h), _circle_pts(x2, y2, h)]
    return [bar(x0, y0, x1, y1), bar(x1, y1, x2, y2)] + circles

# ── 四套配色 ────────────────────────────────────────────────────────────────
VARIANTS = {
    # name: (背景渐变, 环色, 提示符色, 说明)
    '':      ([('0', '#FF1E2B4D'), ('1', '#FF0B1220')], '#FF5FE7BE', '#FFF1F6FF', '默认：深海军蓝 + 薄荷环'),
    '_night':([('0', '#FF17244A'), ('1', '#FF04070E')], '#FF8FE8DC', '#FFE6F0FF', '夜间：更深 + 冰环'),
    '_frost':([('0', '#FFFFFFFF'), ('1', '#FFDCE6F7')], '#FF12806A', '#FF16324F', '霜：浅底 + 深青环'),
    '_ink':  ([('0', '#FF26282D'), ('1', '#FF0A0B0E')], '#FFF2F5FA', '#FFB9C2D0', '墨：近黑 + 白环'),
}

def write(path: pathlib.Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print(f'  ✓ {path.relative_to(REPO)}')

# 生成的位图会被 Android 相册索引（/sdcard 下所有图片都会被扫）：放 .nomedia 屏蔽
for d in (REPO, PREVIEW):
    d.mkdir(parents=True, exist_ok=True)
    (d / '.nomedia').touch()

# ── Android 资源 ────────────────────────────────────────────────────────────
print('Android 矢量资源：')
for name, (stops, ring, chev, note) in VARIANTS.items():
    fg = 'ic_launcher_foreground' if name == '' else f'ic_launcher{name}_foreground'
    bg = 'ic_launcher_background' if name == '' else f'ic_launcher{name}_background'
    write(RES / f'drawable/{fg}.xml', foreground_xml(ring, chev))
    write(RES / f'drawable/{bg}.xml', background_xml(stops, note))
write(RES / 'drawable/ic_launcher_monochrome.xml', monochrome_xml())

print('自适应图标描述：')
for name in VARIANTS:
    fg = 'ic_launcher_foreground' if name == '' else f'ic_launcher{name}_foreground'
    bg = 'ic_launcher_background' if name == '' else f'ic_launcher{name}_background'
    adaptive = 'ic_launcher' if name == '' else f'ic_launcher{name}'
    for suffix in ('', '_round'):
        write(RES / f'mipmap-anydpi-v26/{adaptive}{suffix}.xml', adaptive_xml(bg, fg))

# ── 品牌 SVG（App 内 brand mark 的母版）──────────────────────────────────────
print('品牌母版：')
def _c_only(d: str) -> str:
    """把 L 段换成退化的三次贝塞尔：make_brand_mark.py 只解析 M/C/Z。"""
    import re as _re
    return _re.sub(r'L([-0-9.]+) ([-0-9.]+)', lambda m: f'C{m.group(1)} {m.group(2)} {m.group(1)} {m.group(2)} {m.group(1)} {m.group(2)}', d)

def _flat_grad(gid: str, color: str) -> str:
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="20" y1="20" x2="88" y2="88">'
            f'<stop offset="0" stop-color="{color}"/><stop offset="1" stop-color="{color}"/></linearGradient>')

def brand_svg(ring: str, chev: str, bg: str | None, view: str, tile: bool = False) -> str:
    # 每块单独一个 <path>：拼进同一个 d 会按填充规则相互抵消，出现缺口
    ring_els = ''.join(
        f'<path id="body{"" if i == 0 else f":{i}"}" fill="url(#tail)" d="{_emit(pts)}"/>'
        for i, pts in enumerate(filled_ring_paths()))
    chev_els = ''.join(
        f'<path id="bubble-layer{"" if i == 0 else f":{i}"}" fill="url(#bubble)" d="{_emit(pts)}"/>'
        for i, pts in enumerate(filled_chevron_paths()))
    defs = ''.join([_flat_grad('tail', ring), _flat_grad('fin', ring),
                    _flat_grad('belly', ring), _flat_grad('bubble', chev)])
    if tile:
        defs += ('<linearGradient id="tile-bg" gradientUnits="userSpaceOnUse" x1="7.57" y1="-5.87" x2="100.43" y2="113.87">'
                 '<stop offset="0" stop-color="#1E2B4D"/><stop offset="1" stop-color="#0B1220"/></linearGradient>')
        # 圆角方（72 单位、圆角 14），四角用三次贝塞尔
        k = 14 * (1 - 0.5522847498)
        t = ('<path id="tile" fill="url(#tile-bg)" d="M32 18 '
             'C25.4 18 22.4 19.2 20.4 21.2 C18.4 23.2 18 26.2 18 32 '
             'C18 32 18 76 18 76 C18 81.8 18.4 84.8 20.4 86.8 C22.4 88.8 25.4 90 32 90 '
             'C32 90 76 90 76 90 C82.6 90 85.6 88.8 87.6 86.8 C89.6 84.8 90 81.8 90 76 '
             'C90 76 90 32 90 32 C90 26.2 89.6 23.2 87.6 21.2 C85.6 19.2 82.6 18 76 18 Z"/>')
    else:
        t = ''
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s">\n'
            '<!-- dsh-Go glyph · 自举环 + 提示符（fix/11-make-app-icon.py 生成，勿手改）-->\n'
            '<defs>%s</defs>%s'
            '%s'
            '<path id="fin-layer" fill="none" d="M54 54Z"/>'
            '<path id="belly-layer" fill="none" d="M54 54Z"/>'
            '%s\n</svg>\n') % (view, defs, t, ring_els, chev_els)

write(BRAND / 'glyph-dark.svg', brand_svg('#5FE7BE', '#F1F6FF', None, '22 22 64 64'))
write(BRAND / 'glyph-light.svg', brand_svg('#12806A', '#16324F', None, '22 22 64 64'))
write(BRAND / 'glyph-mono.svg', brand_svg('#FFFFFF', '#FFFFFF', None, '22 22 64 64'))
write(BRAND / 'tile.svg', brand_svg('#5FE7BE', '#F1F6FF', None, '18 18 72 72', tile=True))

def svg_color(argb: str) -> str:
    """#AARRGGBB → #RRGGBB（SVG 不认 8 位色值，直接喂会把前 6 位当颜色）。"""
    c = argb.lstrip('#')
    return '#' + (c[2:] if len(c) == 8 else c)

# ── 旧位图（pre-26 保底 + 部分厂商启动器会读）──────────────────────────────
print('旧位图 mipmap：')
from PIL import Image, ImageDraw
DENS = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

def full_bleed_svg(stops, ring, chev) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="108" height="108">'
            f'<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="7.57" y1="-5.87" x2="100.43" y2="113.87">'
            f'<stop offset="0" stop-color="{svg_color(stops[0][1])}"/><stop offset="1" stop-color="{svg_color(stops[1][1])}"/></linearGradient></defs>'
            f'<rect width="108" height="108" fill="url(#g)"/>'
            f'<path d="{arc_path()}" fill="none" stroke="{svg_color(ring)}" stroke-width="{STROKE}" stroke-linecap="round"/>'
            f'<path d="{chev_path()}" fill="none" stroke="{svg_color(chev)}" stroke-width="{CHEV_STROKE}" stroke-linecap="round" stroke-linejoin="round"/>'
            f'</svg>')

def masked(png: pathlib.Path, size: int, round_icon: bool) -> Image.Image:
    im = Image.open(png).convert('RGBA').resize((size, size), Image.LANCZOS)
    mask = Image.new('L', (size * 4, size * 4), 0)
    d = ImageDraw.Draw(mask)
    if round_icon:
        d.ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    else:
        d.rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * 0.22), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out

tmp = PREVIEW / '_fb.png'
for name, (stops, ring, chev, _) in VARIANTS.items():
    svg = PREVIEW / '_fb.svg'; svg.write_text(full_bleed_svg(stops, ring, chev))
    subprocess.run(['rsvg-convert', '-w', '576', '-h', '576', str(svg), '-o', str(tmp)], check=True)
    base = 'ic_launcher' if name == '' else f'ic_launcher{name}'
    for dens, px in DENS.items():
        d = RES / f'mipmap-{dens}'; d.mkdir(parents=True, exist_ok=True)
        masked(tmp, px, False).save(d / f'{base}.png')
        masked(tmp, px, True).save(d / f'{base}_round.png')
        old = d / (f'{base}_foreground.png')
        if old.exists(): old.unlink()
    print(f'  ✓ {base}.png / _round.png × {len(DENS)} 密度')
for f in ('_fb.png', '_fb.svg'):
    (PREVIEW / f).unlink(missing_ok=True)

# ── 预览 ────────────────────────────────────────────────────────────────────
print('预览：')
PREVIEW.mkdir(parents=True, exist_ok=True)
def preview_svg(stops, ring, chev, radius=24) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="108" height="108">'
            f'<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="7.57" y1="-5.87" x2="100.43" y2="113.87">'
            f'<stop offset="0" stop-color="{svg_color(stops[0][1])}"/><stop offset="1" stop-color="{svg_color(stops[1][1])}"/></linearGradient>'
            f'<clipPath id="c"><rect width="108" height="108" rx="{radius}"/></clipPath></defs>'
            f'<g clip-path="url(#c)"><rect width="108" height="108" fill="url(#g)"/>'
            f'<path d="{arc_path()}" fill="none" stroke="{svg_color(ring)}" stroke-width="{STROKE}" stroke-linecap="round"/>'
            f'<path d="{chev_path()}" fill="none" stroke="{svg_color(chev)}" stroke-width="{CHEV_STROKE}" stroke-linecap="round" stroke-linejoin="round"/>'
            f'</g></svg>')

for name, (stops, ring, chev, _) in VARIANTS.items():
    tag = name.lstrip('_') or 'default'
    svg = PREVIEW / f'icon-{tag}.svg'
    svg.write_text(preview_svg(stops, ring, chev))
    subprocess.run(['rsvg-convert', '-w', '256', '-h', '256', str(svg), '-o', str(PREVIEW / f'icon-{tag}.png')], check=True)
    subprocess.run(['rsvg-convert', '-w', '64', '-h', '64', str(svg), '-o', str(PREVIEW / f'icon-{tag}-64.png')], check=True)
    print(f'  ✓ icon-{tag}.png / -64.png')

# 单色预览（黑白）
mono = PREVIEW / 'icon-mono.svg'
mono.write_text(preview_svg([('0', '#000000'), ('1', '#000000')], '#FFFFFF', '#FFFFFF'))
subprocess.run(['rsvg-convert', '-w', '256', '-h', '256', str(mono), '-o', str(PREVIEW / 'icon-mono.png')], check=True)
print('  ✓ icon-mono.png')
print('完成')
