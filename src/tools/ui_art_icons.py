"""Shop and hazard icons (polish 2, C12 + C15), drawn by src/tools/ui_art.py: assets/ui/{drink,hazard,upgrade}/<id>.svg.
128x128 plain SVG (no filters, no <text>, no clipPath: ThorVG draws it as written), transparent, made to sit on a dark
plate. Drinks are composed from rules, not drawn one by one: GLASSES = the silhouette, a row of DRINKS = glass +
liquid colour + decor, so a new Drink is one row. The tier rim is not in the file: BartenderMenu draws it from Drink.tier.
Every id of every Drink / Event / ShopItem needs a row here: tests/ui/shop_ui_probe.gd fails on a missing file."""
import math
import random

CREAM, INK = "#F4EAD3", "#0A0604"
GLASS_LINE, GLASS_FILL = "#DCE6F0", "#FFFFFF"
BRASS, BRASS_L, BRASS_D = "#C9A24B", "#F2D98B", "#86672A"
PINK, CYAN, GREEN, ORANGE, RED, GOLD = "#FF3D9A", "#3DE0FF", "#5BE08A", "#FFA23D", "#FF5A5A", "#FFD24A"
FELT, FELT_L = "#14664C", "#1E8A66"
CX = 64


# ---- tiny svg helpers -----------------------------------------------------------------------------------

def mix(a, b, t):
    """Hex colour a moved t of the way to b."""
    pa = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    pb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(pa, pb))


def lighten(c, t=0.35): return mix(c, "#FFFFFF", t)
def darken(c, t=0.35): return mix(c, "#000000", t)


def wrap(body, defs="", zoom=1.0):
    """`zoom` scales the drawing about the bottom centre: a shot glass fills its plate, a garnished cocktail fits it."""
    if zoom != 1.0:
        body = f'<g transform="translate(64 118) scale({zoom}) translate(-64 -118)">{body}</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
            f'<defs>{defs}</defs>{body}</svg>\n')


def grad(id_, c0, c1, x1=0, y1=0, x2=0, y2=1):
    return (f'<linearGradient id="{id_}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">'
            f'<stop offset="0" stop-color="{c0}"/><stop offset="1" stop-color="{c1}"/></linearGradient>')


def poly(pts, fill="none", stroke="none", sw=0, op=1.0):
    p = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    return (f'<polygon points="{p}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round" '
            f'opacity="{op}"/>')


def path(d, fill="none", stroke="none", sw=0, op=1.0, cap="round"):
    return (f'<path d="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}" '
            f'stroke-linejoin="round" opacity="{op}"/>')


def circ(x, y, r, fill="none", stroke="none", sw=0, op=1.0):
    return f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" opacity="{op}"/>'


def ell(x, y, rx, ry, fill="none", stroke="none", sw=0, op=1.0):
    return (f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{rx}" ry="{ry}" fill="{fill}" stroke="{stroke}" '
            f'stroke-width="{sw}" opacity="{op}"/>')


def rect(x, y, w, h, r=0, fill="none", stroke="none", sw=0, op=1.0, rot=None):
    t = f' transform="rotate({rot[0]} {rot[1]} {rot[2]})"' if rot else ""
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" '
            f'stroke-width="{sw}" opacity="{op}"{t}/>')


def star(x, y, r, fill=GOLD, stroke="none", sw=0, points=5, inner=0.45):
    pts = []
    for i in range(points * 2):
        a = -math.pi / 2 + i * math.pi / points
        rr = r if i % 2 == 0 else r * inner
        pts.append((x + rr * math.cos(a), y + rr * math.sin(a)))
    return poly(pts, fill, stroke, sw)


# ---- glasses: silhouette = interior profile [(y, half_width)] around x = cx ---------------------------------

def hw_at(prof, y):
    if y <= prof[0][0]:
        return prof[0][1]
    for (y0, w0), (y1, w1) in zip(prof, prof[1:]):
        if y <= y1:
            return w0 + (w1 - w0) * (y - y0) / (y1 - y0) if y1 > y0 else w1
    return prof[-1][1]


def band(prof, y0, y1, cx=CX):
    """Polygon of the profile between y0 and y1 (clipped by interpolation)."""
    ys = [y0] + [y for y, _ in prof if y0 < y < y1] + [y1]
    left = [(cx - hw_at(prof, y), y) for y in ys]
    right = [(cx + hw_at(prof, y), y) for y in reversed(ys)]
    return left + right


def stem_foot(top, bottom, foot_rx=22, cx=CX, stem=3.2):
    return (rect(cx - stem, top - 1, stem * 2, bottom - top, 1.5, GLASS_FILL, GLASS_LINE, 2.5, 0.35) +
            ell(cx, bottom + 2, foot_rx, 5.5, GLASS_FILL, GLASS_LINE, 3, 0.35))


def handle(x, y0, y1, out=20, sw=7, cx=0):
    return path(f"M{x} {y0} H{x + out - 8} Q{x + out} {y0} {x + out} {y0 + 12} V{y1 - 12} Q{x + out} {y1} {x + out - 8} {y1} H{x}",
                "none", GLASS_LINE, sw, 0.9)


# Each glass: prof (y, half width), level (liquid surface y), back/front extras; cx moves the body when a handle balances it.
GLASSES = {
    "shot": dict(prof=[(40, 26), (104, 19), (112, 15)], level=58),
    "tall_shot": dict(prof=[(26, 20), (106, 14), (114, 10)], level=44),
    "rocks": dict(prof=[(34, 34), (106, 30), (114, 26)], level=58),
    "highball": dict(prof=[(12, 24), (110, 19), (118, 15)], level=36),
    "collins": dict(prof=[(8, 19), (112, 15), (120, 12)], level=30),
    "pint": dict(prof=[(12, 27), (26, 30), (38, 28), (112, 18), (120, 14)], level=34),
    "mug": dict(prof=[(26, 31), (110, 30), (118, 26)], level=44, cx=54,
                back=handle(88, 48, 98, 24)),
    "pilsner": dict(prof=[(8, 24), (70, 16), (88, 9)], level=26, back=stem_foot(88, 108, 22)),
    "flute": dict(prof=[(8, 15), (66, 13), (88, 5)], level=28, back=stem_foot(88, 108, 20)),
    "coupe": dict(prof=[(30, 38), (42, 34), (54, 24), (64, 11), (70, 4)], level=40, back=stem_foot(70, 108, 24)),
    "martini": dict(prof=[(22, 42), (78, 3)], level=36, back=stem_foot(78, 108, 24)),
    "snifter": dict(prof=[(22, 20), (36, 31), (54, 40), (72, 37), (88, 24), (96, 8)], level=62, back=stem_foot(96, 108, 22)),
    "goblet": dict(prof=[(12, 25), (34, 31), (50, 28), (66, 14), (74, 4)], level=34, back=stem_foot(74, 108, 22)),
    "hurricane": dict(prof=[(10, 25), (30, 20), (50, 15), (68, 25), (90, 27), (102, 14)], level=34, back=stem_foot(102, 112, 22)),
    "pitcher": dict(prof=[(22, 32), (108, 31), (116, 27)], level=46, cx=54,
                    back=handle(84, 40, 96, 24) + path("M80 20 L96 12", "none", GLASS_LINE, 6, 0.9)),
}


def render_glass(g, liquid, decor_back="", decor_front="", gid="L"):
    """Glass body + liquid. Returns (svg, defs)."""
    prof, level, cx = g["prof"], g["level"], g.get("cx", CX)
    top, bot = prof[0][0], prof[-1][0]
    defs = grad(gid, lighten(liquid, 0.25), darken(liquid, 0.25))
    out = g.get("back", "")
    out += decor_back
    out += poly(band(prof, top, bot, cx), GLASS_FILL, "none", 0, 0.12)
    out += poly(band(prof, level, bot, cx), f"url(#{gid})", "none", 0, 0.96)
    out += path(f"M{cx - hw_at(prof, level) + 2:.1f} {level} H{cx + hw_at(prof, level) - 2:.1f}", "none", lighten(liquid, 0.6), 3, 0.7)
    out += poly(band(prof, top, bot, cx), "none", GLASS_LINE, 3.5)
    hl = hw_at(prof, top + 14)
    out += path(f"M{cx - hl + 6:.1f} {top + 12} L{cx - hw_at(prof, bot - 18) + 6:.1f} {bot - 18}", "none", "#FFFFFF", 3, 0.5)
    out += g.get("front", "")
    out += decor_front
    return out, defs


def level_zone(g):
    return g["level"], g["prof"][-1][0], g.get("cx", CX)


# ---- decor ------------------------------------------------------------------------------------------------

def foam(g, col="#FFF6DC"):
    prof, level, cx = g["prof"], g["level"], g.get("cx", CX)
    w = hw_at(prof, level) - 3
    out = poly(band(prof, level - 2, level + 12, cx), col, "none", 0, 0.97)
    n = max(3, int(w // 7))
    for i in range(n):
        x = cx - w + (i + 0.5) * (2 * w / n)
        out += circ(x, level - 3, 7.5 if i % 2 else 6.5, col)
    return out


def ice(g, n=3, seed=1):
    r = random.Random(seed)
    lv, bot, cx = level_zone(g)
    out = ""
    for i in range(n):
        y = lv + 12 + r.random() * max(8, bot - lv - 34)
        w = hw_at(g["prof"], y) - 12
        x = cx + (r.random() * 2 - 1) * max(2, w)
        out += rect(x - 8, y - 8, 16, 16, 3, "#FFFFFF", "#FFFFFF", 1.5, 0.38, (r.randint(-25, 25), x, y))
    return out


def bubbles(g, n=6, seed=2, col="#FFFFFF"):
    r = random.Random(seed)
    lv, bot, cx = level_zone(g)
    out = ""
    for _ in range(n):
        y = lv + 8 + r.random() * max(6, bot - lv - 18)
        w = hw_at(g["prof"], y) - 7
        out += circ(cx + (r.random() * 2 - 1) * w, y, 2 + r.random() * 2.2, "none", col, 1.6, 0.8)
    return out


def lime_wheel(g, dx=0):
    top, cx = g["prof"][0][0], g.get("cx", CX)
    x, y = cx + hw_at(g["prof"], top) - 2 + dx, top + 2
    out = circ(x, y, 15, "#7FD65A", "#2E7D32", 3)
    out += circ(x, y, 10.5, "#D8F5A8", "none")
    for a in range(0, 360, 60):
        out += path(f"M{x} {y} L{x + 10 * math.cos(math.radians(a)):.1f} {y + 10 * math.sin(math.radians(a)):.1f}", "none", "#7FD65A", 2)
    return out


def wedge(g, col="#7FD65A", edge="#2E7D32", dx=2):
    top, cx = g["prof"][0][0], g.get("cx", CX)
    x, y = cx + hw_at(g["prof"], top) + dx, top + 2
    return (path(f"M{x - 16} {y} A16 16 0 0 0 {x + 16} {y} Z", col, edge, 3) +
            path(f"M{x - 9} {y + 2} A9 9 0 0 0 {x + 9} {y + 2} Z", lighten(col, 0.5)))


def cherry(x, y):
    return path(f"M{x} {y} Q{x + 4} {y - 14} {x + 12} {y - 20}", "none", "#4B8F29", 2.5) + circ(x, y, 7, "#D81B3C", "#7A0F22", 2) + circ(x - 2, y - 2, 2, "#FFFFFF", op=0.7)


def orange_slice(x, y):
    out = circ(x, y, 15, ORANGE, "#B85E00", 3) + circ(x, y, 10.5, "#FFD27A")
    for a in range(0, 360, 45):
        out += path(f"M{x} {y} L{x + 10.5 * math.cos(math.radians(a)):.1f} {y + 10.5 * math.sin(math.radians(a)):.1f}", "none", ORANGE, 1.8)
    return out


def straw(g, col=PINK, lean=18):
    top, cx = g["prof"][0][0], g.get("cx", CX)
    x0, y0 = cx - 6, g["level"] + 30
    return path(f"M{x0} {y0} L{cx + lean} {top - 20}", "none", col, 6) + path(f"M{x0 + 1} {y0} L{cx + lean + 1} {top - 20}", "none", "#FFFFFF", 1.8, 0.55)


def umbrella(x, y, col1=PINK, col2=CYAN):
    """Cocktail parasol, canopy centre (x, y), tilted pole going down-left."""
    out = path(f"M{x - 18} {y + 40} L{x} {y + 6}", "none", "#E8D8B0", 3.5)
    out += path(f"M{x - 26} {y + 6} Q{x} {y - 26} {x + 26} {y + 6} Q{x + 13} {y + 1} {x} {y + 6} Q{x - 13} {y + 1} {x - 26} {y + 6} Z", col1, darken(col1, 0.4), 2.5)
    out += path(f"M{x - 13} {y - 10} Q{x - 9} {y} {x} {y + 6} Q{x + 9} {y} {x + 13} {y - 10} Q{x} {y - 22} {x - 13} {y - 10} Z", col2, "none", 0)
    return out


def flame(x, y, h=34, w=22, outer=ORANGE, inner="#FFE27A"):
    """Teardrop flame with its base centre at (x, y)."""
    o = path(f"M{x} {y - h} C{x + w * 0.2} {y - h * 0.6} {x + w} {y - h * 0.45} {x + w * 0.85} {y - h * 0.15} "
             f"A{w * 0.85} {h * 0.34} 0 0 1 {x - w * 0.85} {y - h * 0.15} C{x - w} {y - h * 0.5} {x - w * 0.15} {y - h * 0.62} {x} {y - h} Z",
             outer, darken(outer, 0.45), 2.5)
    i = path(f"M{x} {y - h * 0.55} C{x + w * 0.5} {y - h * 0.3} {x + w * 0.5} {y - 2} {x} {y - 2} C{x - w * 0.5} {y - 2} {x - w * 0.5} {y - h * 0.3} {x} {y - h * 0.55} Z", inner)
    return o + i


def smoke(x, y):
    return (path(f"M{x - 10} {y} Q{x - 18} {y - 8} {x - 8} {y - 15} T{x - 10} {y - 28}", "none", "#C9C9D1", 4, 0.55) +
            path(f"M{x + 10} {y + 2} Q{x + 2} {y - 8} {x + 12} {y - 16} T{x + 8} {y - 30}", "none", "#C9C9D1", 4, 0.45))


def glitch(g, cols=(CYAN, PINK), seed=3, n=5):
    """Horizontal tear bars across the glass: the Mystery tier's mark."""
    r = random.Random(seed)
    prof, cx = g["prof"], g.get("cx", CX)
    top, bot = prof[0][0], prof[-1][0]
    out = ""
    for i in range(n):
        y = top + 6 + r.random() * (bot - top - 16)
        w = hw_at(prof, y) + 6
        a = cx - w + r.random() * 12
        out += rect(a, y, w * (0.9 + r.random() * 0.9), 4 + r.randint(0, 2), 1, cols[i % 2], "none", 0, 0.88)
    return out


def noise(g, seed=7, cell=8):
    r = random.Random(seed)
    prof, cx = g["prof"], g.get("cx", CX)
    top, bot = prof[0][0], prof[-1][0]
    out = ""
    y = top + 2
    while y < bot - cell:
        x = cx - hw_at(prof, y + cell) + 2
        while x < cx + hw_at(prof, y + cell) - cell - 1:
            v = r.randint(60, 250)
            out += rect(x, y, cell - 1, cell - 1, 0, f"#{v:02x}{v:02x}{v:02x}", "none", 0, 0.92)
            x += cell
        y += cell
    return out


def bolt(x, y, s=1.0, col="#FFE14A"):
    pts = [(x + 4 * s, y - 24 * s), (x - 14 * s, y + 4 * s), (x - 2 * s, y + 4 * s), (x - 8 * s, y + 24 * s), (x + 14 * s, y - 6 * s), (x + 2 * s, y - 6 * s)]
    return poly(pts, col, darken(col, 0.5), 2.5)


def xxx(x, y):
    return "".join(path(f"M{x + dx - 5} {y - 6} L{x + dx + 5} {y + 6} M{x + dx + 5} {y - 6} L{x + dx - 5} {y + 6}", "none", "#7A2E1A", 3.2) for dx in (-14, 0, 14))


def skull(x, y, s=1.0):
    return (circ(x, y - 2 * s, 11 * s, "#F2F2F2", "#222", 2) + rect(x - 6 * s, y + 6 * s, 12 * s, 8 * s, 2, "#F2F2F2", "#222", 2) +
            circ(x - 4.5 * s, y - 2 * s, 3 * s, "#150818") + circ(x + 4.5 * s, y - 2 * s, 3 * s, "#150818") + poly([(x, y + 2 * s), (x - 2 * s, y + 6 * s), (x + 2 * s, y + 6 * s)], "#150818"))


def eye(x, y, col="#B84DFF"):
    return (path(f"M{x - 20} {y} Q{x} {y - 16} {x + 20} {y} Q{x} {y + 16} {x - 20} {y} Z", CREAM, "#222", 2.5) +
            circ(x, y, 8, col, "#2B0A44", 2) + circ(x, y, 3.5, "#0A0010") + circ(x + 3, y - 3, 1.8, "#FFFFFF"))


def hop(x, y):
    out = ""
    for i, (dx, dy) in enumerate([(0, -9), (-6, -2), (6, -2), (-3, 6), (3, 6), (0, 13)]):
        out += ell(x + dx, y + dy, 6.5, 8, "#8CCB3F" if i % 2 else "#6BAF2A", "#2F5E12", 1.5)
    return out


def gold_flakes(g, n=7, seed=5):
    r = random.Random(seed)
    lv, bot, cx = level_zone(g)
    out = ""
    for _ in range(n):
        y = lv + 6 + r.random() * (bot - lv - 14)
        x = cx + (r.random() * 2 - 1) * (hw_at(g["prof"], y) - 5)
        s = 2.6 + r.random() * 2.4
        out += poly([(x, y - s), (x + s, y), (x, y + s), (x - s, y)], GOLD, "#B8860B", 0.8)
    return out


def arrow_left(x, y):
    return (path(f"M{x + 20} {y} H{x - 12}", "none", CYAN, 7) + poly([(x - 8, y - 15), (x - 28, y), (x - 8, y + 15)], CYAN, darken(CYAN, 0.4), 2.5))


def salt(y=121):
    out = ""
    r = random.Random(9)
    for i in range(14):
        out += circ(30 + i * 5.6 + r.random() * 2, y + r.random() * 4 - 2, 1.7, "#FFFFFF", "none", 0, 0.95)
    return out


def sugar_spoon(g):
    top, cx = g["prof"][0][0], g.get("cx", CX)
    w = hw_at(g["prof"], top)
    out = path(f"M{cx - w - 10} {top - 8} L{cx + w + 12} {top + 6}", "none", "#C0C0C8", 5)
    out += ell(cx, top - 1, 15, 5, "#D8D8E0", "#6A6A74", 2)
    for dx in (-6, 0, 6):
        out += path(f"M{cx + dx} {top - 3} V{top + 1}", "none", "#4A4A54", 1.6)
    return out + rect(cx - 7, top - 18, 14, 12, 2, "#FFFFFF", "#9AA", 1.8, 0.95)


def ghost(g, dx=10, col=CYAN):
    prof, cx = g["prof"], g.get("cx", CX)
    return poly(band(prof, prof[0][0], prof[-1][0], cx + dx), col, col, 3, 0.28)


def pickle_in(g):
    cx = CX
    return rect(cx - 8, g["level"] + 8, 16, 46, 7, "#6A9E2A", "#3B5E14", 2.5, 1.0, (-18, cx, 70)) + circ(cx - 4, 68, 1.6, "#3B5E14") + circ(cx + 2, 80, 1.6, "#3B5E14")


# ---- non-glass vessels (opaque) ---------------------------------------------------------------------------------

def mug_tiki(col="#8A5530"):
    """Carved tiki mug: tapered cylinder, brow, eyes, mouth."""
    cx = 54
    body = poly([(cx - 34, 36), (cx + 34, 36), (cx + 28, 112), (cx - 28, 112)], col, "#3E2412", 3.5)
    body += rect(cx - 36, 30, 72, 12, 5, lighten(col, 0.18), "#3E2412", 3)
    body += path(f"M{cx - 24} 58 Q{cx - 13} 48 {cx - 3} 58 M{cx + 3} 58 Q{cx + 13} 48 {cx + 24} 58", "none", "#2A170B", 5)
    body += ell(cx - 13, 66, 6, 5, "#FFE0A0", "#2A170B", 2.5) + ell(cx + 13, 66, 6, 5, "#FFE0A0", "#2A170B", 2.5)
    body += rect(cx - 17, 82, 34, 18, 6, "#2A170B", "#1A0E06", 2) + "".join(rect(cx - 13 + i * 9, 82, 7, 7, 1, "#FFE0A0") for i in range(3))
    body += handle(cx + 30, 52, 96, 22, 8)
    return body


def can_body(col):
    x, w = 40, 48
    return (rect(x, 24, w, 92, 8, col, darken(col, 0.5), 3.5) + rect(x - 1, 14, w + 2, 12, 5, "#D9DDE3", "#6A7078", 3) +
            rect(x - 1, 108, w + 2, 12, 5, "#D9DDE3", "#6A7078", 3) + rect(x + 8, 28, 6, 78, 3, "#FFFFFF", "none", 0, 0.28))


def bottle_body(col):
    out = path("M54 14 V32 Q54 44 40 54 Q34 60 34 72 V108 Q34 118 44 118 H84 Q94 118 94 108 V72 Q94 60 88 54 Q74 44 74 32 V14 Z",
               col, darken(col, 0.5), 3.5)
    out += rect(52, 6, 24, 12, 3, "#C9A24B", "#86672A", 3) + rect(38, 72, 52, 26, 4, "#F4EAD3", "none", 0, 0.92)
    out += rect(40, 60, 6, 48, 3, "#FFFFFF", "none", 0, 0.3)
    return out


def jug_body(col):
    out = path("M52 10 H76 V28 Q96 36 104 58 Q112 84 100 104 Q92 118 64 118 Q36 118 28 104 Q16 84 24 58 Q32 36 52 28 Z", col, darken(col, 0.45), 3.5, 0.97)
    out += path("M100 40 Q122 40 122 62 Q122 84 102 86", "none", darken(col, 0.45), 8) + path("M100 40 Q118 40 118 62 Q118 80 102 82", "none", col, 4)
    out += rect(50, 6, 28, 10, 4, "#8A6A3A", "#4A3515", 2.5) + rect(34, 56, 60, 30, 5, "#F4EAD3", "none", 0, 0.9)
    return out


def jar_body(col):
    out = poly([(CX - 34, 32), (CX + 34, 32), (CX + 38, 40), (CX + 38, 106), (CX + 28, 118), (CX - 28, 118), (CX - 38, 106), (CX - 38, 40)], GLASS_FILL, GLASS_LINE, 3.5, 0.2)
    out += poly([(CX - 35, 56), (CX + 35, 56), (CX + 35, 106), (CX + 26, 115), (CX - 26, 115), (CX - 35, 106)], col, "none", 0, 0.85)
    out += rect(CX - 38, 14, 76, 20, 5, BRASS, BRASS_D, 3.5) + path(f"M{CX - 30} 22 H{CX + 30}", "none", BRASS_L, 2.5)
    out += path(f"M{CX - 30} 42 V104", "none", "#FFFFFF", 3, 0.4)
    return out


def flask_body(col):
    out = poly([(50, 14), (78, 14), (78, 46), (112, 108), (108, 118), (20, 118), (16, 108), (50, 46)], GLASS_FILL, GLASS_LINE, 3.5, 0.2)
    out += poly([(34, 82), (94, 82), (112, 108), (108, 118), (20, 118), (16, 108)], col, "none", 0, 0.95)
    out += poly([(50, 14), (78, 14), (78, 46), (112, 108), (108, 118), (20, 118), (16, 108), (50, 46)], "none", GLASS_LINE, 3.5)
    out += rect(46, 4, 36, 14, 4, "#B98A4E", "#5E4220", 3)
    return out


def bowl_body():
    return (path("M18 66 Q20 112 64 114 Q108 112 110 66 Z", "#7A4A2A", "#3E2412", 3.5) + rect(14, 60, 100, 12, 6, "#9A6038", "#3E2412", 3) +
            path("M30 80 Q34 100 50 104", "none", "#FFFFFF", 3, 0.25))


def nuts():
    pts = [(34, 58), (50, 52), (68, 50), (86, 54), (98, 60), (44, 44), (62, 40), (80, 44), (54, 30), (72, 32)]
    cols = ["#C98B4A", "#B07838", "#D79B5B"]
    out = ""
    for i, (x, y) in enumerate(pts):
        out += ell(x, y, 9, 6.5, cols[i % 3], "#6E4720", 2) + path(f"M{x - 5} {y} Q{x} {y - 4} {x + 5} {y}", "none", "#6E4720", 1.6, 0.8)
    return out


def pretzel():
    d = ("M64 106 C30 106 14 84 22 58 C30 34 54 30 64 52 C74 30 98 34 106 58 C114 84 98 106 64 106 Z")
    out = path(d, "none", "#6A3A12", 17) + path(d, "none", "#C4772C", 12)
    out += path("M38 70 C50 94 78 94 90 70", "none", "#6A3A12", 17) + path("M38 70 C50 94 78 94 90 70", "none", "#C4772C", 12)
    out += path("M40 40 Q64 66 88 40", "none", "#6A3A12", 17) + path("M40 40 Q64 66 88 40", "none", "#C4772C", 12)
    r = random.Random(4)
    for _ in range(16):
        x, y = 26 + r.random() * 76, 38 + r.random() * 62
        out += rect(x, y, 5, 3, 1, "#FFFFFF", "none", 0, 0.95, (r.randint(0, 180), x, y))
    return out


def pitcher_extra(g):
    return ice(g, 3, 4) + ell(76, 56, 11, 5, "#FFF3A6", "#C9A800", 2) + path("M64 56 H88", "none", "#C9A800", 1.4)


# ---- the drinks: glass (or vessel) + liquid + decor ---------------------------------------------------------------

def drinks():
    D = {}

    def glass(id_, name, liquid, deco_fn=None, back_fn=None, zoom=1.0):
        g = GLASSES[name]
        back = back_fn(g) if back_fn else ""
        front = deco_fn(g) if deco_fn else ""
        body, defs = render_glass(g, liquid, back, front)
        D[id_] = wrap(body, defs, zoom)

    glass("beer", "mug", "#E3A21A", lambda g: foam(g) + bubbles(g, 5, 1, "#FFF1B8"))
    glass("pale_ale", "pint", "#F4D35E", lambda g: foam(g, "#FFFDF0") + hop(CX + 22, 54) + bubbles(g, 5, 8, "#FFF7C8"))
    glass("rum_and_cola", "highball", "#5A301C", lambda g: ice(g, 3, 6) + wedge(g) + straw(g, PINK))
    glass("vodka_tonic", "collins", "#CDEFFF", lambda g: ice(g, 3, 2) + bubbles(g, 7, 3) + lime_wheel(g) + straw(g, CYAN, -14))
    glass("whiskey_shot", "rocks", "#C97B1E", lambda g: bubbles(g, 2, 3, "#FFE0A0"), zoom=1.3)
    glass("flaming_shot", "shot", "#FF7A1A", lambda g: flame(CX, 42, 38, 25) + bubbles(g, 3, 5, "#FFE9A0"), zoom=1.05)
    glass("static_shot", "shot", "#C8CCD4", lambda g: noise(g, 7, 7), zoom=1.5)
    glass("tequila_line", "tall_shot", "#F2E3A0", lambda g: wedge(g, dx=-4) + bubbles(g, 3, 4, "#FFFFFF") + salt(120), zoom=1.12)
    glass("green_fairy", "coupe", "#8DFF4A", lambda g: bubbles(g, 4, 5, "#E9FFC8") + sugar_spoon(g))
    glass("dragons_breath", "snifter", "#FF3B1F", lambda g: flame(CX, 34, 36, 24, "#FF4A1A", "#FFD23A") + smoke(CX - 8, 10) + bubbles(g, 3, 8, "#FFD0A0"), zoom=0.92)
    glass("gold_flake_champagne", "flute", "#F7E7A1", lambda g: gold_flakes(g, 9, 5) + bubbles(g, 6, 9, "#FFFFFF"))
    glass("house_special", "goblet", "#8A1F45", lambda g: star(CX, 72, 11, GOLD, "#B8860B", 1.5) + bubbles(g, 3, 6, "#FFB0C8"))
    glass("blue_lagoon", "hurricane", "#1E9BFF", lambda g: ice(g, 2, 4) + cherry(CX - 14, 14) + orange_slice(CX + 24, 22) + umbrella(CX + 10, 10, PINK, "#FFD23A") + bubbles(g, 4, 11), zoom=0.84)
    glass("ice_water", "pitcher", "#BFEFFF", pitcher_extra)
    glass("neighbours_round", "pilsner", "#F7C948", lambda g: foam(g) + arrow_left(CX + 36, 72) + bubbles(g, 4, 3, "#FFF1B8"))
    glass("quantum_ale", "pint", "#55E6FF", lambda g: foam(g, "#CFFAFF") + bubbles(g, 5, 4, "#FFFFFF") + glitch(g, (CYAN, "#B84DFF"), 3, 4),
          back_fn=lambda g: ghost(g, 11, "#B84DFF"))
    glass("cursed_cola", "highball", "#2B1030", lambda g: skull(CX, 70) + glitch(g, ("#B84DFF", PINK), 5, 5) + ice(g, 2, 7))
    glass("void_juice", "martini", "#12061C", lambda g: eye(CX, 44) + glitch(g, ("#B84DFF", CYAN), 9, 3))

    # opaque vessels
    D["tiki_torch"] = wrap(mug_tiki() + flame(48, 32, 34, 22, "#FF6A1A", "#FFE27A") + flame(66, 30, 24, 16, "#FF9A2A", "#FFE27A"))
    D["energy_drink"] = wrap(can_body("#62E04A") + bolt(64, 66, 1.4) + path("M46 36 H82 M46 98 H82", "none", "#14301A", 3, 0.6))
    D["soda_pop"] = wrap(bottle_body("#E5383B") + circ(64, 85, 8, "#E5383B", "none", 0, 0.95) + bubbles({"prof": [(60, 28), (108, 26)], "level": 62}, 5, 3, "#FFD0D0"))
    D["pickle_juice"] = wrap(jar_body("#8BC34A") + pickle_in({"level": 56}))
    D["moonshine"] = wrap(jug_body("#E9EFA0") + xxx(59, 71))
    D["back_alley_brew"] = wrap(flask_body("#6B7F2A") + bubbles({"prof": [(84, 36), (114, 40)], "level": 86}, 5, 6, "#D8F58A") + glitch({"prof": [(14, 50), (118, 56)]}, (CYAN, PINK), 4, 4))
    D["bar_nuts"] = wrap(bowl_body() + nuts() + path("M20 66 Q64 76 108 66", "none", "#3E2412", 2, 0.4))
    D["pretzels"] = wrap(pretzel())
    return D


# ---- hazards: bold flat symbols ------------------------------------------------------------------------------------

def ball(x, y, r, col, stripe=False):
    out = circ(x, y, r, col, darken(col, 0.5), 2.5)
    out += circ(x - r * 0.3, y - r * 0.32, r * 0.28, "#FFFFFF", op=0.55)
    return out


def arrow_curve(d, tip, ang, col=CREAM, sw=6):
    x, y = tip
    a = math.radians(ang)
    p = [(x + 14 * math.cos(a), y + 14 * math.sin(a)), (x + 11 * math.cos(a + 2.5), y + 11 * math.sin(a + 2.5)), (x + 11 * math.cos(a - 2.5), y + 11 * math.sin(a - 2.5))]
    return path(d, "none", col, sw) + poly(p, col, col, 2)


def hazards():
    H = {}
    H["ball_swap_chaos"] = wrap(
        ball(36, 40, 18, PINK) + ball(92, 88, 18, CYAN) +
        arrow_curve("M60 30 Q100 22 100 56", (100, 60), 90, CREAM) + arrow_curve("M68 98 Q28 106 28 72", (28, 68), -90, CREAM) +
        star(98, 22, 7, GOLD, "none", 0, 4, 0.4) + star(24, 108, 6, GOLD, "none", 0, 4, 0.4))
    H["bouncer"] = wrap(
        circ(60, 62, 34, "#E0B089", "#6A4630", 3) + poly([(30, 28), (60, 14), (92, 28), (92, 40), (30, 40)], "#1A1A22", "#000", 2) +
        rect(30, 50, 62, 18, 8, "#0B0B10", "#000", 2) + rect(58, 55, 6, 6, 1, "#0B0B10") +
        path("M34 52 L46 52 M70 52 L82 52", "none", "#6B6B7A", 3, 0.7) +
        path("M44 86 Q60 94 76 86", "none", "#6A4630", 4) +
        poly([(46, 100), (60, 108), (46, 116), (28, 108)], PINK, "#7A1244", 2.5) + poly([(74, 100), (60, 108), (74, 116), (92, 108)], PINK, "#7A1244", 2.5) + circ(60, 108, 5, "#7A1244") +
        circ(100, 30, 18, "#1B120C", CREAM, 4) + path("M100 30 V20 M100 30 L108 34", "none", CYAN, 4))
    H["crowd_roar"] = wrap(
        poly([(18, 52), (44, 52), (88, 22), (88, 106), (44, 76), (18, 76)], BRASS, BRASS_D, 3.5) + rect(18, 52, 26, 24, 5, "#3B2316", BRASS_D, 3) +
        poly([(88, 22), (100, 16), (100, 112), (88, 106)], BRASS_L, BRASS_D, 3) +
        rect(26, 76, 12, 22, 4, "#3B2316", BRASS_D, 3) +
        path("M108 44 Q120 64 108 84", "none", CYAN, 5) + path("M114 30 Q134 64 114 98", "none", PINK, 5, 0.8) + path("M96 18 L100 8 M104 22 L112 14", "none", GOLD, 4))
    H["glass_cushions"] = wrap(
        rect(8, 84, 112, 28, 6, "#8A5530", "#2A170B", 3) + rect(8, 76, 112, 14, 5, FELT_L, "#0A2A1F", 2.5) +
        poly([(18, 76), (110, 76), (102, 28), (26, 28)], "#9FE8FF", "#E8FAFF", 3.5, 0.4) +
        path("M38 32 L58 72 M60 30 L72 56 M86 32 L96 70", "none", "#FFFFFF", 3, 0.8) +
        path("M34 52 L52 62 L46 46", "none", "#FFFFFF", 2.5, 0.9) + ball(28, 64, 9, CREAM) + path("M40 70 L62 52 L86 74", "none", ORANGE, 4.5) + poly([(88, 78), (72, 76), (84, 64)], ORANGE, ORANGE, 2))
    H["lights_out"] = wrap(
        circ(64, 52, 36, "#3A3A4E", "#B8B8D0", 4) + rect(50, 86, 28, 12, 4, "#4A4A58", "#8A8AA0", 3) + rect(54, 98, 20, 10, 4, "#4A4A58", "#8A8AA0", 3) +
        path("M52 56 Q64 40 76 56", "none", "#6A6A80", 4) + path("M64 56 V86", "none", "#6A6A80", 3) +
        path("M30 20 L98 84", "none", RED, 7) + star(108, 20, 9, "#C9C9E8", "none", 0, 5, 0.5) +
        path("M96 28 Q106 40 100 52 Q112 44 112 30 Q106 22 96 28 Z", "#C9C9E8", "none", 0, 0.9) +
        path("M12 112 Q30 100 48 112 T84 112 T120 112", "none", "#8A8AA0", 3.5, 0.6))
    H["moving_pockets"] = wrap(
        poly([(4, 24), (124, 24), (124, 104), (4, 104)], FELT_L, "#0A2A1F", 3.5) + circ(64, 62, 24, "#08060A", "#6B3F22", 6) + circ(64, 62, 16, "#000", "none") +
        path("M20 62 H32 M96 62 H108", "none", CREAM, 5) + poly([(14, 62), (28, 52), (28, 72)], CREAM, CREAM, 1) + poly([(114, 62), (100, 52), (100, 72)], CREAM, CREAM, 1) +
        path("M40 40 Q64 28 88 40", "none", CYAN, 3.5, 0.8) + path("M40 84 Q64 96 88 84", "none", CYAN, 3.5, 0.8))
    H["pocket_jackpot"] = wrap(
        ell(64, 100, 44, 14, "#08060A", "#6B3F22", 5) + ell(64, 98, 34, 9, "#000") +
        circ(40, 62, 14, GOLD, "#B8860B", 3.5) + circ(40, 62, 8, "none", "#B8860B", 2.5) +
        circ(68, 44, 14, GOLD, "#B8860B", 3.5) + circ(68, 44, 8, "none", "#B8860B", 2.5) +
        circ(94, 66, 14, GOLD, "#B8860B", 3.5) + circ(94, 66, 8, "none", "#B8860B", 2.5) +
        star(64, 16, 10, PINK, "#7A1244", 2) + star(20, 30, 7, CYAN, "none", 0, 4, 0.4) + star(108, 28, 7, CYAN, "none", 0, 4, 0.4) +
        path("M40 82 V90 M68 62 V88 M94 84 V90", "none", GOLD, 3, 0.7))
    H["sunken_ship"] = wrap(
        poly([(10, 60), (100, 34), (116, 50), (26, 84)], "#8A5530", "#2A170B", 3) + poly([(16, 60), (98, 38), (108, 48), (28, 76)], FELT_L, "#0A2A1F", 2.5) +
        circ(26, 76, 9, "#08060A", "#6B3F22", 3.5) + path("M70 50 L48 62", "none", ORANGE, 4) + poly([(40, 66), (56, 62), (46, 52)], ORANGE, ORANGE, 2) +
        poly([(60, 84), (96, 80), (88, 104), (68, 104)], "#5A3720", "#2A170B", 3) + path("M78 82 V44", "none", "#3A2210", 4) + poly([(78, 44), (96, 50), (78, 56)], RED, "#7A1A1A", 2) +
        path("M4 100 Q18 88 32 100 T60 100 T88 100 T124 100", "none", CYAN, 5) + path("M4 114 Q18 104 32 114 T60 114 T88 114 T124 114", "none", "#2D8FD0", 5) +
        circ(104, 108, 7, "none", CREAM, 3, 0.7) + circ(14, 86, 5, CREAM, "none", 0, 0.45))
    H["vacation"] = wrap(
        poly([(8, 34), (64, 34), (64, 112), (8, 112)], "#2D8FD0", "#0B3A66", 3.5) + poly([(64, 34), (120, 34), (120, 112), (64, 112)], "#E8C878", "#8A6A2A", 3.5) +
        path("M16 56 Q26 48 36 56 T56 56 M16 76 Q26 68 36 76 T56 76 M16 96 Q26 88 36 96 T56 96", "none", "#E8FAFF", 4) +
        path("M64 34 V112", "none", "#FFFFFF", 5, 0.9) +
        path("M96 108 V56", "none", "#5A3720", 4) + poly([(70, 58), (96, 36), (122, 58), (96, 62)], RED, "#7A1A1A", 3) + poly([(84, 47), (96, 36), (108, 47), (96, 60)], CREAM, "none", 0, 0.9) +
        ball(84, 100, 8, CREAM) + star(30, 20, 9, GOLD, "none", 0, 8, 0.5) + path("M30 6 V10 M16 20 H20 M44 20 H40", "none", GOLD, 3))
    H["pinball"] = wrap(
        rect(6, 100, 116, 12, 6, "#8A5530", "#2A170B", 3) +
        rect(26, 40, 14, 62, 5, "#C8CCD4", "#5A5F6A", 3) + circ(33, 40, 17, RED, "#7A1A1A", 3.5) + circ(33, 40, 8, "#FFE9A8", "#B8860B", 2.5) +
        rect(88, 40, 14, 62, 5, "#C8CCD4", "#5A5F6A", 3) + circ(95, 40, 17, RED, "#7A1A1A", 3.5) + circ(95, 40, 8, "#FFE9A8", "#B8860B", 2.5) +
        rect(57, 66, 14, 36, 5, "#C8CCD4", "#5A5F6A", 3) + circ(64, 66, 15, RED, "#7A1A1A", 3.5) + circ(64, 66, 7, "#FFE9A8", "#B8860B", 2.5) +
        ball(64, 20, 11, CREAM) + path("M64 32 L52 46 L76 52 L66 60", "none", CYAN, 4) + star(112, 24, 8, GOLD, "none", 0, 4, 0.4) + star(16, 20, 7, PINK, "none", 0, 4, 0.4))
    H["double_ball"] = wrap(
        ball(36, 38, 20, RED) + ball(80, 38, 20, CYAN) + ball(58, 80, 20, GOLD) +
        ball(34, 92, 14, PINK) + ball(96, 86, 14, GREEN) +
        path("M88 22 L100 10 M100 22 L88 10", "none", CREAM, 6) + path("M104 14 Q104 6 112 6 Q120 6 120 14 Q120 20 104 30 H122", "none", CREAM, 5) +
        circ(36, 38, 9, "#FFFFFF", "none", 0, 0.9) + circ(80, 38, 9, "#FFFFFF", "none", 0, 0.9))
    H["ice_rink"] = wrap(
        poly([(8, 70), (120, 70), (104, 112), (24, 112)], "#CFEFFF", "#4FA6D6", 4) + path("M22 84 H100 M30 98 H96", "none", "#FFFFFF", 4, 0.9) +
        path("M64 14 V58 M42 26 L86 46 M86 26 L42 46", "none", CYAN, 6) + path("M64 14 L56 22 M64 14 L72 22 M64 58 L56 50 M64 58 L72 50", "none", CYAN, 4) +
        ball(88, 90, 12, CREAM) + path("M70 94 H46 M66 86 H40 M62 102 H44", "none", "#5FB4E0", 4) + star(20, 40, 6, "#FFFFFF", "none", 0, 4, 0.4) + star(108, 34, 6, "#FFFFFF", "none", 0, 4, 0.4))
    H["shaky_hands"] = wrap(
        path("M14 104 L98 28", "none", "#5A3720", 9) + path("M14 104 L40 80", "none", "#C8A24B", 9) +
        path("M22 112 L106 36", "none", "#5A3720", 6, 0.35) + path("M6 96 L90 20", "none", "#5A3720", 6, 0.35) +
        ball(100, 96, 14, CREAM) + path("M92 70 Q104 58 116 70 M96 78 Q108 66 120 78", "none", ORANGE, 4) +
        path("M10 40 Q20 28 30 40 T50 40", "none", CYAN, 4) + path("M60 118 Q70 108 80 118 T100 118", "none", CYAN, 4) + star(58, 54, 7, GOLD, "none", 0, 4, 0.4))
    H["lead_ball"] = wrap(
        poly([(30, 118), (98, 118), (88, 70), (40, 70)], "#3A3E48", "#12141A", 3.5) + rect(52, 52, 24, 22, 8, "none", "#3A3E48", 6) + circ(64, 96, 12, "#12141A", "none", 0, 0.6) +
        path("M52 106 H76", "none", "#8A92A0", 4) +
        ball(34, 40, 18, "#2A2E38") + path("M86 22 V52 M74 40 L86 54 L98 40", "none", ORANGE, 6) + path("M106 30 V60", "none", ORANGE, 4, 0.5))
    return H


# ---- upgrades -----------------------------------------------------------------------------------------------------------

def rack(cols):
    out = poly([(64, 12), (116, 106), (12, 106)], "none", BRASS, 8)
    out += poly([(64, 20), (106, 98), (22, 98)], "#1B120C", "none", 0, 0.4)
    for (x, y), c in zip([(64, 44), (48, 72), (80, 72), (34, 92), (64, 92), (94, 92)], cols):
        out += ball(x, y, 12, c)
    return out


def cue(x0, y0, x1, y1, thick=8):
    return (path(f"M{x0} {y0} L{x1} {y1}", "none", BRASS_L, thick) + path(f"M{x0} {y0} L{x0 + (x1 - x0) * 0.32} {y0 + (y1 - y0) * 0.32}", "none", "#3B2316", thick + 2))


def upgrades():
    U = {}
    U["polish_the_set"] = wrap(ball(60, 70, 36, "#E02F3A") + star(100, 28, 12, GOLD, "#B8860B", 2) + star(24, 26, 8, CYAN, "none", 0, 4, 0.4) + star(104, 100, 7, CYAN, "none", 0, 4, 0.4) +
                               path("M76 40 Q94 46 98 62", "none", "#FFFFFF", 5, 0.7))
    U["tier2_rack"] = wrap(rack(["#3D8BFF"] * 6) + rect(54, 4, 6, 12, 2, CREAM) + rect(68, 4, 6, 12, 2, CREAM))
    U["tier3_rack"] = wrap(rack([GOLD] * 6) + rect(46, 4, 6, 12, 2, CREAM) + rect(61, 4, 6, 12, 2, CREAM) + rect(76, 4, 6, 12, 2, CREAM))
    U["bomb_ball"] = wrap(circ(58, 76, 36, "#3C3C50", CREAM, 3.5) + circ(44, 62, 10, "#FFFFFF", op=0.3) + rect(50, 32, 16, 12, 3, "#8A8AA0", CREAM, 2.5) +
                          path("M64 32 Q78 18 88 24", "none", BRASS_L, 5) + star(94, 22, 12, ORANGE, "#B85E00", 2, 8, 0.5) + star(94, 22, 6, "#FFE27A", "none", 0, 8, 0.5))
    U["split_ball"] = wrap(path("M62 18 A38 38 0 0 0 62 110 Z", "#E02F3A", "#7A1018", 3.5) + path("M70 18 A38 38 0 0 1 70 110 Z", "#E02F3A", "#7A1018", 3.5) +
                           path("M62 30 L58 46 L66 58 L58 72 L66 86 L62 100", "none", "#FFE27A", 3) + path("M46 70 H20 M20 70 l8 -8 M20 70 l8 8", "none", CREAM, 4.5) + path("M86 70 H112 M112 70 l-8 -8 M112 70 l-8 8", "none", CREAM, 4.5))
    U["joker_ball"] = wrap(ball(64, 78, 34, "#8A3DFF") + poly([(34, 56), (46, 18), (58, 44), (64, 12), (70, 44), (82, 18), (94, 56)], PINK, "#7A1244", 3) +
                           circ(46, 16, 5, GOLD, "#B8860B", 1.5) + circ(64, 10, 5, GOLD, "#B8860B", 1.5) + circ(82, 16, 5, GOLD, "#B8860B", 1.5) + star(64, 82, 13, GOLD, "#B8860B", 2))
    U["heavy_shaft"] = wrap(path("M14 112 L108 18", "none", "#3B2316", 15) + path("M14 112 L108 18", "none", BRASS_L, 9) + path("M24 102 L34 92", "none", "#1B120C", 17) +
                            rect(54, 40, 36, 14, 4, "#9A9AB0", "#2A2A36", 3, 1.0, (-45, 72, 46)) + rect(74, 60, 36, 14, 4, "#9A9AB0", "#2A2A36", 3, 1.0, (-45, 92, 66)) +
                            path("M100 100 H116 M108 92 V108", "none", CYAN, 5))
    U["chalk_tin"] = wrap(ell(64, 92, 46, 16, "#2B3A55", "#0E1626", 3) + rect(18, 66, 92, 28, 4, "#2B3A55", "#0E1626", 3) + ell(64, 66, 46, 16, "#3C5278", "#0E1626", 3) +
                          rect(42, 34, 44, 38, 5, "#5BB6FF", "#1E5E9C", 3, 1.0, (-8, 64, 52)) + rect(48, 38, 12, 8, 2, "#BFE4FF", "none", 0, 0.8, (-8, 64, 52)) +
                          star(100, 28, 7, CREAM, "none", 0, 4, 0.4))
    U["jump_cue"] = wrap(cue(10, 108, 62, 70, 7) + ball(104, 100, 14, CREAM) + path("M24 70 Q64 -4 108 76", "none", CYAN, 5, 0.95) + poly([(110, 90), (96, 70), (114, 68)], CYAN, CYAN, 2) +
                         path("M96 112 H116", "none", "#000", 3, 0.45))
    U["custom_tip"] = wrap(path("M10 118 L64 64", "none", "#5A3825", 22) + path("M56 72 L80 48", "none", BRASS, 22) + path("M74 54 L92 36", "none", CREAM, 16) + path("M86 42 L100 28", "none", "#4DA3FF", 16) +
                           circ(98, 30, 22, "none", CYAN, 3.5, 0.9) + path("M98 2 V14 M98 46 V58 M70 30 H82 M114 30 H126", "none", CYAN, 3.5, 0.9) + star(26, 40, 8, GOLD, "none", 0, 4, 0.4))
    for n, bars in (("lens_t2", 2), ("lens_t3", 3)):
        body = (rect(14, 36, 82, 60, 8, "#4A4A5E", CREAM, 3.5) + rect(88, 46, 24, 40, 4, "#5A5A70", CREAM, 3) +
                circ(54, 66, 30, "#1A1A26", "#B8B8D0", 5) + circ(54, 66, 21, "#13506E", "#3DE0FF", 3) + circ(54, 66, 9, "#08141E") + circ(46, 58, 5, "#FFFFFF", op=0.7) +
                rect(22, 26, 20, 12, 3, "#8A8AA0", CREAM, 2.5))
        for i in range(bars):
            body += rect(88 + i * 8 - (bars - 2) * 4, 50, 5, 32, 2, GOLD if bars == 3 else CREAM)
        U[n] = wrap(body)
    U["spare_tripod"] = wrap(path("M64 54 L28 116 M64 54 L100 116 M64 54 V116", "none", "#8A8A98", 8) + path("M64 54 L28 116 M64 54 L100 116", "none", "#B8B8C8", 3) +
                             rect(38, 16, 52, 36, 7, "#2A2A34", "#0E0E14", 3.5) + circ(64, 34, 12, "#13364D", CYAN, 3.5) + circ(60, 30, 3.5, "#FFFFFF", op=0.7) + circ(80, 24, 3.5, RED) +
                             path("M92 30 H108 M100 22 V38", "none", GREEN, 5))
    U["magnetic_pockets"] = wrap(path("M24 28 V74 A40 40 0 0 0 104 74 V28", "none", "#B8B8C8", 22) + path("M24 28 V74 A40 40 0 0 0 104 74 V28", "none", RED, 13) +
                                 rect(12, 14, 24, 22, 3, "#E8E8F0", "#6A6A74", 2.5) + rect(92, 14, 24, 22, 3, "#E8E8F0", "#6A6A74", 2.5) +
                                 path("M52 12 V0 M76 12 V0 M64 14 V2", "none", CYAN, 3.5, 0.9) + ell(64, 100, 16, 10, "#08060A", "#6B3F22", 3.5) + circ(64, 78, 7, CREAM, "#6A6A74", 1.5))
    U["stream_overlay"] = wrap(rect(8, 18, 112, 74, 8, "#14141C", CREAM, 4.5) + rect(16, 26, 96, 58, 3, "#1A3A4A", "none", 0) +
                               circ(28, 40, 6, RED) + rect(40, 36, 32, 8, 3, RED) + path("M22 64 H64 M22 74 H84", "none", "#7AA0B0", 4) +
                               rect(76, 52, 32, 24, 5, PINK, "#7A1244", 2.5) + poly([(84, 76), (90, 88), (96, 76)], PINK, "#7A1244", 2) + path("M82 60 H102 M82 68 H96", "none", "#FFFFFF", 3) +
                               rect(46, 94, 36, 8, 2, "#8A8A98", "#2A2A34", 2.5) + rect(32, 102, 64, 8, 3, "#8A8A98", "#2A2A34", 2.5))
    U["fresh_cloth"] = wrap(poly([(14, 42), (100, 28), (118, 80), (30, 100)], FELT_L, "#0A2A1F", 3.5) + poly([(14, 42), (100, 28), (96, 40), (20, 52)], lighten(FELT_L, 0.3), "none") +
                            poly([(100, 28), (118, 80), (106, 70), (96, 40)], FELT, "#0A2A1F", 2.5) + path("M30 56 L84 48 M34 76 L98 64", "none", "#0A2A1F", 2.5, 0.5) +
                            star(34, 22, 10, CREAM, "none", 0, 4, 0.4) + star(104, 104, 9, CYAN, "none", 0, 4, 0.4) + star(66, 110, 6, GOLD, "none", 0, 4, 0.4))
    return U


def unknown(kind):
    body = (circ(64, 64, 44, "#2A2230", BRASS, 5) + path("M48 50 Q48 34 64 34 Q80 34 80 50 Q80 60 64 66 V76", "none", CREAM, 8) + circ(64, 94, 5.5, CREAM))
    return wrap(body)


def build(put):
    """Calls put('drink/<id>', svg) for every icon (ui_art.py's file table)."""
    for kind, table in (("drink", drinks()), ("hazard", hazards()), ("upgrade", upgrades())):
        for id_, content in table.items():
            put(f"{kind}/{id_}", content)
        put(f"{kind}/unknown", unknown(kind))
