#!/usr/bin/env python3
"""One-shot: draws the wall TV's picture (a pool broadcast) -> assets/decor/tv_screen.png (512x288, the screen's aspect).

Our own generated art, like make_posters.py (same font). build_bar_room.gd puts it on the tv_screen material's emission.

  python3 src/tools/make_tv.py
"""
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT = os.path.join(ROOT, "assets/fonts/BarlowCondensed-SemiBold.ttf")
OUT = os.path.join(ROOT, "assets/decor/tv_screen.png")
W, H, SS = 512, 288, 3


def font(px):
    return ImageFont.truetype(FONT, int(px * SS))


def main():
    im = Image.new("RGB", (W * SS, H * SS), (10, 16, 26))
    d = ImageDraw.Draw(im)

    def s(*v):
        return [x * SS for x in v]

    # arena backdrop: dark blue gradient with a spot
    for y in range(H):
        t = y / H
        d.rectangle(s(0, y, W, y + 1), fill=(int(14 + 20 * t), int(20 + 26 * t), int(44 + 40 * t)))
    # the table seen from above, tilted a little by a trapezoid
    d.polygon(s(60, 70, 452, 70, 500, 220, 12, 220), fill=(92, 52, 24))            # wood rail
    d.polygon(s(78, 84, 434, 84, 478, 208, 34, 208), fill=(20, 120, 56))           # felt
    d.polygon(s(78, 84, 434, 84, 442, 100, 70, 100), fill=(30, 140, 68))           # light falloff at the far cushion
    for cx, cy in [(78, 84), (256, 82), (434, 84), (34, 208), (256, 210), (478, 208)]:
        d.ellipse(s(cx - 11, cy - 8, cx + 11, cy + 8), fill=(6, 8, 8))              # pockets
    balls = [((190, 150), (240, 200, 30)), ((205, 138), (200, 30, 30)), ((218, 156), (30, 70, 200)), ((176, 138), (230, 110, 20)),
             ((232, 140), (120, 40, 140)), ((212, 168), (20, 140, 70)), ((248, 154), (20, 20, 20)), ((192, 164), (150, 20, 30))]
    for (cx, cy), c in balls:
        d.ellipse(s(cx - 7, cy - 5.5, cx + 7, cy + 5.5), fill=c)
        d.ellipse(s(cx - 3.5, cy - 3.5, cx - 0.5, cy - 1), fill=(255, 255, 255))
    d.ellipse(s(366 - 7, 170 - 5.5, 366 + 7, 170 + 5.5), fill=(245, 245, 235))      # cue ball
    d.line(s(420, 120, 372, 168), fill=(214, 176, 110), width=3 * SS)               # cue
    # broadcast furniture: LIVE bug, score bar
    d.rectangle(s(18, 14, 82, 38), fill=(214, 28, 36))
    d.text(s(50, 26), "LIVE", font=font(22), fill=(255, 255, 255), anchor="mm")
    d.rectangle(s(0, 238, W, 288), fill=(8, 10, 18))
    d.rectangle(s(0, 238, W, 242), fill=(255, 196, 40))
    d.text(s(20, 262), "GUS'S CORNER POCKET", font=font(26), fill=(255, 255, 255), anchor="lm")
    d.text(s(250, 262), "8-BALL  FRAME 3", font=font(20), fill=(255, 196, 40), anchor="lm")
    d.rectangle(s(396, 246, 504, 280), fill=(30, 36, 60))
    d.text(s(450, 263), "GUS 4 - 3 MOE", font=font(18), fill=(255, 255, 255), anchor="mm")
    im.resize((W, H), Image.LANCZOS).save(OUT, optimize=True)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
