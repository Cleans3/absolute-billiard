#!/usr/bin/env python3
"""One-shot: draws the bar's poster atlas (adhoc-1010a C10/C18) -> assets/decor/poster_atlas.png.

Our own generated art (no third-party pixels). Layout is mirrored by DecorPlan.ATLAS_* in
src/gameplay/bar_room/decor_plan.gd: change one, change the other.

  python3 src/tools/make_posters.py
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT = os.path.join(ROOT, "assets/fonts/BarlowCondensed-SemiBold.ttf")  # OFL, already in the repo
OUT = os.path.join(ROOT, "assets/decor/poster_atlas.png")

AW, AH = 1024, 1024
CW, CH = 256, 300  # portrait cell
SS = 3  # supersample


def font(px):
    return ImageFont.truetype(FONT, int(px * SS))


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


class Cell:
    """Drawing surface of w x h cells-pixels with S-times supersampling."""

    def __init__(self, w, h, bg):
        self.w, self.h = w, h
        self.im = Image.new("RGB", (w * SS, h * SS), rgb(bg) if isinstance(bg, str) else bg)
        self.d = ImageDraw.Draw(self.im)

    def s(self, *v):
        return [x * SS for x in v]

    def rect(self, x0, y0, x1, y1, fill, outline=None, width=0):
        self.d.rectangle(self.s(x0, y0, x1, y1), fill=rgb(fill) if fill else None, outline=rgb(outline) if outline else None, width=int(width * SS))

    def ellipse(self, cx, cy, rx, ry, fill, outline=None, width=0):
        self.d.ellipse(self.s(cx - rx, cy - ry, cx + rx, cy + ry), fill=rgb(fill) if fill else None, outline=rgb(outline) if outline else None, width=int(width * SS))

    def poly(self, pts, fill):
        self.d.polygon([(x * SS, y * SS) for x, y in pts], fill=rgb(fill))

    def line(self, pts, fill, width):
        self.d.line([(x * SS, y * SS) for x, y in pts], fill=rgb(fill), width=int(width * SS))

    def text(self, cx, cy, txt, px, fill, anchor="mm", stroke=0, stroke_fill=None):
        self.d.text((cx * SS, cy * SS), txt, font=font(px), fill=rgb(fill), anchor=anchor,
                    stroke_width=int(stroke * SS), stroke_fill=rgb(stroke_fill) if stroke_fill else None)

    def rays(self, cx, cy, r, n, c0, c1, phase=0.0):
        for i in range(n):
            a0 = phase + i * 2 * math.pi / n
            a1 = a0 + math.pi / n
            self.poly([(cx, cy), (cx + math.cos(a0) * r, cy + math.sin(a0) * r), (cx + math.cos(a1) * r, cy + math.sin(a1) * r)], c0 if i % 2 == 0 else c1)

    def border(self, inset, color, width):
        self.rect(inset, inset, self.w - inset, self.h - inset, None, color, width)

    def done(self):
        return self.im.resize((self.w, self.h), Image.LANCZOS)


def ball(c, cx, cy, r, color, number=None, stripe=False):
    c.ellipse(cx, cy, r, r, color)
    if stripe:
        c.ellipse(cx, cy, r, r, "#f4f0e6")
        c.d.pieslice(c.s(cx - r, cy - r, cx + r, cy + r), 200, 340, fill=rgb(color))
        c.d.pieslice(c.s(cx - r, cy - r, cx + r, cy + r), 20, 160, fill=rgb(color))
    if number is not None:
        c.ellipse(cx, cy, r * 0.5, r * 0.5, "#f4f0e6")
        c.text(cx, cy + r * 0.04, str(number), r * 0.7, "#101010")
    c.ellipse(cx - r * 0.35, cy - r * 0.4, r * 0.18, r * 0.12, "#ffffff")


def p_eight_ball():
    c = Cell(CW, CH, "#1b1033")
    c.rays(CW / 2, 150, 300, 16, "#e8402a", "#f6a21d", 0.1)
    c.ellipse(CW / 2, 150, 92, 92, "#101010")
    c.ellipse(CW / 2, 150, 46, 46, "#f4f0e6")
    c.text(CW / 2, 154, "8", 70, "#101010")
    c.ellipse(CW / 2 - 32, 112, 20, 13, "#ffffff")
    c.rect(0, 232, CW, CH, "#1b1033")
    c.text(CW / 2, 250, "RACK 'EM UP", 40, "#f6a21d")
    c.text(CW / 2, 276, "EST. 1979", 18, "#e8402a")
    c.border(8, "#f6a21d", 3)
    return c.done()


def p_cold_beer():
    c = Cell(CW, CH, "#0f4c5c")
    for i in range(14):
        c.ellipse(random.Random(i).randint(20, 236), random.Random(i + 40).randint(20, 215), 4 + i % 4, 4 + i % 4, "#2a7a8a")
    c.poly([(86, 70), (170, 70), (160, 214), (96, 214)], "#f2b134")
    c.poly([(98, 78), (118, 78), (112, 206), (104, 206)], "#f9d56e")
    c.rect(86, 70, 170, 90, "#f9f3df")
    for x in (96, 118, 140, 160):
        c.ellipse(x, 66, 15, 15, "#f9f3df")
    c.d.arc(c.s(150, 90, 206, 190), -80, 80, fill=rgb("#d8e3e6"), width=int(9 * SS))
    c.text(CW / 2, 242, "ICE COLD", 42, "#f9f3df")
    c.text(CW / 2, 273, "ON TAP TONIGHT", 20, "#f2b134")
    c.border(8, "#f9f3df", 3)
    return c.done()


def p_shark():
    c = Cell(CW, CH, "#12355b")
    c.rect(0, 150, CW, CH, "#0b2545")
    for row in range(6):
        for i in range(-1, 9):
            c.d.arc(c.s(i * 40 - (row % 2) * 20, 150 + row * 24, i * 40 + 40 - (row % 2) * 20, 190 + row * 24), 180, 360, fill=rgb("#1e5a8a"), width=int(3 * SS))
    c.poly([(70, 175), (115, 70), (130, 112), (190, 175)], "#c8d6e0")
    c.poly([(115, 70), (130, 112), (118, 108)], "#8aa1b3")
    c.line([(40, 230), (215, 110)], "#e8b86d", 5)
    c.line([(40, 230), (60, 216)], "#6b3d12", 8)
    c.text(CW / 2, 40, "THE", 24, "#f4f0e6")
    c.text(CW / 2, 248, "POOL SHARK", 40, "#f4f0e6")
    c.text(CW / 2, 274, "NEVER LOSES A RACK", 17, "#7fb3d5")
    c.border(8, "#7fb3d5", 3)
    return c.done()


def p_tournament():
    c = Cell(CW, CH, "#8c1c13")
    c.rect(14, 14, CW - 14, CH - 14, "#f2e6c8")
    c.rect(22, 22, CW - 22, CH - 22, None, "#8c1c13", 3)
    c.text(CW / 2, 52, "CUE MASTERS", 36, "#8c1c13")
    c.poly([(98, 84), (158, 84), (150, 140), (106, 140)], "#d4a017")
    c.ellipse(CW / 2, 84, 30, 9, "#f0c53d")
    c.d.arc(c.s(70, 90, 112, 128), 90, 270, fill=rgb("#d4a017"), width=int(6 * SS))
    c.d.arc(c.s(144, 90, 186, 128), -90, 90, fill=rgb("#d4a017"), width=int(6 * SS))
    c.rect(118, 140, 138, 168, "#d4a017")
    c.rect(96, 168, 160, 184, "#6b3d12")
    c.text(CW / 2, 206, "CITY FINALS", 28, "#1b1b1b")
    c.text(CW / 2, 234, "FRI & SAT - 8 PM", 22, "#8c1c13")
    c.text(CW / 2, 258, "ENTRY: $5 + CHALK", 16, "#1b1b1b")
    return c.done()


def p_happy_hour():
    c = Cell(CW, CH, "#4b1d6b")
    for i in range(8):
        c.rect(0, i * 14, CW, i * 14 + 7, "#5c2680")
    c.poly([(60, 60), (196, 60), (128, 150)], "#ff5fa2")
    c.poly([(70, 66), (186, 66), (128, 140)], "#ffc4de")
    c.line([(128, 150), (128, 214)], "#f4f0e6", 7)
    c.line([(88, 218), (168, 218)], "#f4f0e6", 8)
    c.line([(150, 40), (118, 100)], "#c7e24a", 4)
    c.ellipse(150, 40, 12, 12, "#7ea31f")
    c.ellipse(150, 40, 4, 4, "#e8402a")
    c.text(CW / 2, 244, "HAPPY HOUR", 40, "#ffd23f")
    c.text(CW / 2, 271, "5 - 7  /  2 FOR 1", 20, "#ff5fa2")
    c.border(8, "#ffd23f", 3)
    return c.done()



def p_chalk_cue():
    c = Cell(CW, CH, "#0b5d2a")
    for i in range(0, CW, 16):
        c.line([(i, 0), (i, CH)], "#0d6a31", 6)
    c.line([(36, 40), (220, 190)], "#e8c58a", 8)
    c.line([(36, 40), (62, 61)], "#2b2b2b", 10)
    c.line([(220, 40), (36, 190)], "#e8c58a", 8)
    c.line([(220, 40), (194, 61)], "#2b2b2b", 10)
    c.rect(100, 96, 156, 150, "#3a7bd5")
    c.poly([(100, 96), (112, 84), (168, 84), (156, 96)], "#6aa5f0")
    c.poly([(156, 96), (168, 84), (168, 138), (156, 150)], "#255aa0")
    c.text(CW / 2, 216, "KEEP IT", 36, "#f4f0e6")
    c.text(CW / 2, 248, "STRAIGHT", 36, "#f4f0e6")
    c.text(CW / 2, 272, "CHALK UP", 16, "#9be0a8")
    c.border(8, "#f4f0e6", 3)
    return c.done()


def p_billiards():
    c = Cell(CW, CH, "#e9dcc0")
    c.border(8, "#5b3a1a", 4)
    c.text(CW / 2, 40, "BILLIARDS", 42, "#5b3a1a")
    c.poly([(128, 52), (212, 200), (44, 200)], "#5b3a1a")
    c.poly([(128, 72), (194, 188), (62, 188)], "#e9dcc0")
    cols = ["#e8c33a", "#2457b8", "#d9381e", "#6b2a8f", "#e8742a", "#1d7a3a", "#7a1c1c", "#101010"]
    k = 0
    for row in range(4):
        for i in range(row + 1):
            ball(c, 128 + (i - row / 2) * 29, 100 + row * 26, 12, cols[k % 8], k + 1)
            k += 1
    c.text(CW / 2, 232, "FINE TABLES", 26, "#5b3a1a")
    c.text(CW / 2, 262, "SINCE 1951", 20, "#8c1c13")
    c.line([(40, 280), (216, 280)], "#5b3a1a", 2)
    return c.done()


def p_no_scratch():
    c = Cell(CW, CH, "#f6c90e")
    for i in range(-CH, CW + CH, 36):
        c.poly([(i, 0), (i + 18, 0), (i + 18 - CH, CH), (i - CH, CH)], "#1b1b1b")
    c.rect(24, 24, CW - 24, CH - 24, "#f6c90e")
    c.rect(24, 24, CW - 24, CH - 24, None, "#1b1b1b", 5)
    c.ellipse(CW / 2, 112, 50, 50, "#f4f0e6", "#c0392b", 9)
    c.ellipse(CW / 2, 112, 20, 20, "#f4f0e6", "#1b1b1b", 3)
    c.line([(92, 72), (164, 152)], "#c0392b", 9)
    c.text(CW / 2, 200, "NO SCRATCHING", 30, "#1b1b1b")
    c.text(CW / 2, 232, "COST OF THE", 22, "#1b1b1b")
    c.text(CW / 2, 258, "NIGHT: YOURS", 22, "#c0392b")
    return c.done()



def p_wanted_moe():
    """09 §2.2: the only portrait of Velvet Moe, face scratched out, defaced to read DO NOT ASK."""
    c = Cell(CW, CH, "#e2d2a8")
    rnd = random.Random(1979)
    for _ in range(140):  # foxing: an old, handled sheet
        x, y, r = rnd.uniform(0, CW), rnd.uniform(0, CH), rnd.uniform(1, 5)
        c.ellipse(x, y, r, r, "#d4c08f")
    c.border(10, "#5a2a4a", 3)
    c.text(CW / 2, 36, "WANTED", 40, "#3b1a2e")
    c.rect(52, 58, CW - 52, 196, "#cbb98d", "#3b1a2e", 3)
    c.ellipse(CW / 2, 196, 74, 46, "#4a2140")  # velvet jacket shoulders, cut at the frame
    c.rect(48, 198, CW - 48, 246, "#e2d2a8")
    c.rect(52, 58, CW - 52, 196, None, "#3b1a2e", 3)
    c.ellipse(CW / 2, 128, 34, 40, "#c79a74")  # the face
    c.rect(84, 86, 172, 94, "#2b1222")  # hat brim
    c.rect(98, 62, 158, 88, "#2b1222")  # hat crown
    c.rect(98, 80, 158, 84, "#7a2a5c")  # band
    for _ in range(28):  # scratched out: a blade, many times, by an angry hand
        x0, y0 = CW / 2 + rnd.uniform(-46, 46), 128 + rnd.uniform(-48, 40)
        a = rnd.uniform(-0.6, 0.6) + (math.pi / 4 if rnd.random() < 0.5 else -math.pi / 4)
        l = rnd.uniform(28, 64)
        c.line([(x0 - math.cos(a) * l / 2, y0 - math.sin(a) * l / 2), (x0 + math.cos(a) * l / 2, y0 + math.sin(a) * l / 2)],
               "#f1e6c8" if rnd.random() < 0.6 else "#8a7a58", rnd.uniform(1.5, 3.5))
    c.text(CW / 2, 222, "VELVET MOE", 36, "#5a2a4a")
    c.text(CW / 2, 262, "DO NOT ASK", 34, "#b3201b", stroke=1, stroke_fill="#5a0e0b")
    c.line([(56, 278), (204, 274)], "#b3201b", 3)
    return c.done()


def corner_pocket_sign():
    """09 §2.2: the bar's own name over the entrance. 2-wide banner cell."""
    c = Cell(CW * 2, CH, "#1a0f0a")
    for i in range(0, CH, 22):  # dark wood planks
        c.rect(0, i, CW * 2, i + 20, "#24150d")
    c.rect(12, 12, CW * 2 - 12, CH - 12, None, "#c8963e", 6)
    c.rect(26, 26, CW * 2 - 26, CH - 26, None, "#7a5320", 2)
    c.text(CW, 92, "GUS'S", 58, "#f2c14e", stroke=2, stroke_fill="#6b4410")
    c.text(CW, 166, "CORNER POCKET", 78, "#f2c14e", stroke=3, stroke_fill="#6b4410")
    c.line([(96, 216), (CW * 2 - 96, 216)], "#c8963e", 3)
    c.text(CW, 246, "EST. 1979  -  ONE TABLE, ONE STREAM", 24, "#e9d9b0")
    for x in (150, CW * 2 - 150):
        ball(c, x, 92, 20, "#101010", 8)
    return c.done()


def dartboard():
    s = 256
    c = Cell(s, s, "#101010")
    c.ellipse(128, 128, 126, 126, "#1a1a1a")
    n = 20
    for i in range(n):
        a0 = (i - 0.5) * 2 * math.pi / n - math.pi / 2
        a1 = a0 + 2 * math.pi / n
        dark = i % 2 == 0
        base = "#161616" if dark else "#efe3c2"
        ring = "#1f8f4a" if dark else "#d9381e"

        def sector(r0, r1, col):
            pts = [(128 + math.cos(a) * r0, 128 + math.sin(a) * r0) for a in (a0, a1)] + [(128 + math.cos(a) * r1, 128 + math.sin(a) * r1) for a in (a1, a0)]
            c.poly(pts, col)
        sector(46, 76, base)
        sector(76, 84, ring)
        sector(84, 112, base)
        sector(112, 120, ring)
    c.ellipse(128, 128, 18, 18, "#1f8f4a")
    c.ellipse(128, 128, 8, 8, "#d9381e")
    return c.done()


POSTERS = [p_eight_ball, p_cold_beer, p_shark, p_tournament, p_happy_hour, p_wanted_moe, p_chalk_cue, p_billiards, p_no_scratch]


def main():
    random.seed(7)
    atlas = Image.new("RGB", (AW, AH), (255, 255, 255))  # the bottom strip stays white: untextured props sample it
    for i, fn in enumerate(POSTERS[:8]):
        atlas.paste(fn(), ((i % 4) * CW, (i // 4) * CH))
    atlas.paste(corner_pocket_sign(), (0, 2 * CH))
    atlas.paste(dartboard(), (2 * CW, 2 * CH))
    atlas.paste(POSTERS[8](), (3 * CW, 2 * CH))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    atlas.save(OUT, optimize=True)
    print("poster atlas:", OUT, atlas.size, os.path.getsize(OUT) // 1024, "KB")


if __name__ == "__main__":
    main()
