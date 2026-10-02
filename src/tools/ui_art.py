#!/usr/bin/env python3
"""Draws every sprite in assets/ui/ (P12): night pool hall, dark walnut + felt, brass trim, neon accents.
Run from the repo root: python3 src/tools/ui_art.py  -- then `godot --headless --import`, then
`godot --path . --headless -s src/tools/build_ui_theme.gd` to rebuild src/ui/theme/game_theme.tres.
Plain SVG only (no filters, no <text>) so the ThorVG rasteriser in Godot renders it exactly."""
import os
import re

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "ui")

WAL_D, WAL_M, WAL_L = "#22130C", "#3B2316", "#5A3825"
BRASS, BRASS_L, BRASS_D = "#C9A24B", "#F2D98B", "#86672A"
CREAM = "#F4EAD3"
PINK, PINK_D, PINK_L = "#FF3D9A", "#C21F73", "#FF8CC4"
CYAN, CYAN_D = "#3DE0FF", "#13A9C9"
FELT, FELT_D = "#0F3D2E", "#082A1F"
RED, GREEN, ORANGE = "#FF5A5A", "#5BE08A", "#FFA23D"


def svg(w, h, body, defs="", out=None):
    ow, oh = out or (w, h)  # `out` = rasterised size: the menu backdrop is drawn at 1280x720 but ships as 1024x576 (07 §8 texture cap)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{ow}" height="{oh}" viewBox="0 0 {w} {h}">'
            f'<defs>{defs}</defs>{body}</svg>\n')


def lin(id_, c0, c1, x1=0, y1=0, x2=0, y2=1, mid=None):
    stops = f'<stop offset="0" stop-color="{c0}"/>'
    if mid:
        stops += f'<stop offset="0.5" stop-color="{mid}"/>'
    stops += f'<stop offset="1" stop-color="{c1}"/>'
    return f'<linearGradient id="{id_}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stops}</linearGradient>'


def rad(id_, c0, c1, o0=1, o1=0, cx=0.5, cy=0.5, r=0.5):
    return (f'<radialGradient id="{id_}" cx="{cx}" cy="{cy}" r="{r}">'
            f'<stop offset="0" stop-color="{c0}" stop-opacity="{o0}"/>'
            f'<stop offset="1" stop-color="{c1}" stop-opacity="{o1}"/></radialGradient>')


def rrect(x, y, w, h, r, fill="none", stroke="none", sw=0, extra=""):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" {extra}/>'


FILES = {}


def _rgba(m):
    r, g, b, a = (float(v) for v in m.group(2, 3, 4, 5))
    return f'{m.group(1)}="#{int(r):02x}{int(g):02x}{int(b):02x}" {m.group(1)}-opacity="{a}"'


def put(name, content):
    # ThorVG rejects CSS rgba() colours (paints them opaque black): split into hex + *-opacity
    FILES[name] = re.sub(r'(fill|stroke)="rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)"', _rgba, content)


# ---- panels -------------------------------------------------------------------------------------

def panel_frame():
    d = lin("w", "#43291A", "#1E110A") + lin("b", BRASS_L, BRASS_D, 0, 0, 1, 1)
    b = rrect(1, 1, 94, 94, 18, "url(#w)", "#0A0604", 2)
    b += rrect(6, 6, 84, 84, 12, "none", "url(#b)", 3)
    b += rrect(10, 10, 76, 76, 9, "none", "rgba(0,0,0,0.55)", 2)
    b += rrect(12, 12, 72, 72, 8, "none", "rgba(255,255,255,0.05)", 1)
    for cx, cy in ((16, 16), (80, 16), (16, 80), (80, 80)):
        b += f'<circle cx="{cx}" cy="{cy}" r="4" fill="{BRASS_L}" stroke="{BRASS_D}" stroke-width="1.5"/>'
    put("panel_frame", svg(96, 96, b, d))


def panel_inset():
    d = lin("f", "#0C3327", FELT_D)
    b = rrect(1, 1, 62, 62, 12, "url(#f)", "#050F0B", 2)
    b += rrect(3, 3, 58, 58, 10, "none", "rgba(201,162,75,0.35)", 1.5)
    b += '<path d="M8 4.5 H56" stroke="rgba(0,0,0,0.45)" stroke-width="3" stroke-linecap="round"/>'
    put("panel_inset", svg(64, 64, b, d))


def hud_plate():
    b = rrect(1, 1, 62, 46, 14, "rgba(14,8,5,0.80)", "rgba(201,162,75,0.85)", 2)
    b += '<path d="M14 45 H50" stroke="rgba(61,224,255,0.55)" stroke-width="2" stroke-linecap="round"/>'
    put("hud_plate", svg(64, 48, b))


# ---- buttons ------------------------------------------------------------------------------------

def button(name, top, bot, stroke, glow=None, hi=0.18, shade=False):
    d = lin("g", top, bot)
    b = rrect(1.5, 1.5, 61, 61, 15, "url(#g)", stroke, 2.5)
    if glow:
        b += rrect(5, 5, 54, 54, 11, "none", glow, 1.5, 'opacity="0.8"')
    if shade:
        b += '<path d="M9 6.5 H55" stroke="rgba(0,0,0,0.5)" stroke-width="4" stroke-linecap="round"/>'
    else:
        b += f'<path d="M10 6 H54" stroke="rgba(255,255,255,{hi})" stroke-width="2" stroke-linecap="round"/>'
        b += '<path d="M10 58 H54" stroke="rgba(0,0,0,0.35)" stroke-width="2" stroke-linecap="round"/>'
    put(name, svg(64, 64, b, d))


def buttons():
    button("btn_normal", "#69442D", "#3A2316", BRASS)
    button("btn_hover", "#7E5238", "#4A2D1D", BRASS_L, CYAN)
    button("btn_pressed", "#2B190F", "#432818", BRASS_D, None, shade=True)
    button("btn_disabled", "#3C3631", "#2D2926", "#6E6358", None, 0.06)
    button("btn_primary", PINK, PINK_D, BRASS_L, None, 0.4)
    button("btn_primary_hover", PINK_L, "#E02F88", BRASS_L, CYAN, 0.5)
    button("btn_primary_pressed", "#A91760", "#D12A7C", BRASS_D, None, shade=True)
    b = rrect(2, 2, 60, 60, 15, "none", "rgba(61,224,255,0.25)", 6)
    b += rrect(2.5, 2.5, 59, 59, 15, "none", CYAN, 3)
    put("btn_focus", svg(64, 64, b))


# ---- tabs ---------------------------------------------------------------------------------------

def tab(name, top, bot, stroke, line=None):
    d = lin("t", top, bot)
    path = "M1.5 48 V18 Q1.5 1.5 18 1.5 H46 Q62.5 1.5 62.5 18 V48 Z"
    b = f'<path d="{path}" fill="url(#t)" stroke="{stroke}" stroke-width="2.5"/>'
    if line:
        b += f'<path d="M14 5 H50" stroke="{line}" stroke-width="3" stroke-linecap="round"/>'
    put(name, svg(64, 48, b, d))


def tabs():
    tab("tab_selected", "#6F4730", "#3E2518", BRASS_L, CYAN)
    tab("tab_unselected", "#2E1B11", "#22130C", BRASS_D)
    tab("tab_hover", "#4A2E1F", "#2E1B11", BRASS)


# ---- slider / checkbox / scroll / line edit -----------------------------------------------------

def slider():
    put("slider_track", svg(32, 16, rrect(1, 3, 30, 10, 5, "#120A06", BRASS_D, 1.5)))
    d = lin("c", CYAN, CYAN_D)
    put("slider_fill", svg(32, 16, rrect(1, 3, 30, 10, 5, "url(#c)", BRASS_D, 1.5), d))
    for name, ring in (("slider_knob", BRASS), ("slider_knob_hl", CYAN)):
        d = lin("k", BRASS_L, BRASS_D, 0, 0, 1, 1) + rad("p", PINK_L, PINK_D, 1, 1)
        b = f'<circle cx="22" cy="22" r="20" fill="url(#k)" stroke="#0A0604" stroke-width="2"/>'
        b += f'<circle cx="22" cy="22" r="20" fill="none" stroke="{ring}" stroke-width="{3 if ring == CYAN else 0}"/>'
        b += f'<circle cx="22" cy="22" r="12" fill="#2A170E" stroke="{BRASS_L}" stroke-width="1.5"/>'
        b += '<circle cx="22" cy="22" r="7" fill="url(#p)"/>'
        put(name, svg(44, 44, b, d))


def checks():
    for name, on in (("check_off", False), ("check_on", True)):
        b = rrect(2, 2, 36, 36, 8, "#120A06", BRASS, 2.5)
        b += rrect(5, 5, 30, 30, 6, "none", "rgba(0,0,0,0.5)", 2)
        if on:
            b += f'<path d="M10 21 L17 28 L31 12" fill="none" stroke="{CYAN}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>'
        put(name, svg(40, 40, b))


def scroll():
    put("scroll_track", svg(24, 24, rrect(6, 1, 12, 22, 6, "#120A06", BRASS_D, 1.5)))
    for name, c0, c1 in (("scroll_grabber", BRASS, BRASS_D), ("scroll_grabber_hl", BRASS_L, BRASS)):
        d = lin("s", c0, c1, 0, 0, 1, 0)
        put(name, svg(24, 24, rrect(4, 1, 16, 22, 8, "url(#s)", "#0A0604", 1.5), d))


def line_edit():
    b = rrect(1.5, 1.5, 45, 45, 11, "#0E0805", BRASS_D, 2)
    b += '<path d="M10 5 H38" stroke="rgba(0,0,0,0.7)" stroke-width="3" stroke-linecap="round"/>'
    put("line_edit", svg(48, 48, b))
    b = rrect(1.5, 1.5, 45, 45, 11, "#0E0805", CYAN, 2.5)
    b += rrect(4, 4, 40, 40, 9, "none", "rgba(61,224,255,0.3)", 2)
    put("line_edit_focus", svg(48, 48, b))


# ---- icons (64x64, drawn to read at 28-40 px on a phone) -----------------------------------------

def icon(name, body, defs=""):
    put("icon_" + name, svg(64, 64, body, defs))


def icons():
    # cash: banknote with a $-ish coin
    icon("cash", rrect(5, 15, 54, 34, 6, GREEN, "#1B6B3A", 3) +
         f'<circle cx="32" cy="32" r="10" fill="#1B6B3A" stroke="{CREAM}" stroke-width="3"/>' +
         f'<path d="M36 27 Q32 24 28.5 27 Q27 30 32 32 Q37 34 35.5 37 Q32 40 28 37" fill="none" stroke="{CREAM}" stroke-width="3" stroke-linecap="round"/>' +
         f'<path d="M32 22 V42" stroke="{CREAM}" stroke-width="2.5"/>' +
         '<circle cx="12" cy="32" r="2.5" fill="#1B6B3A"/><circle cx="52" cy="32" r="2.5" fill="#1B6B3A"/>')
    # quota: bullseye
    icon("quota", f'<circle cx="32" cy="32" r="25" fill="none" stroke="{CREAM}" stroke-width="5"/>'
         f'<circle cx="32" cy="32" r="15" fill="none" stroke="{PINK}" stroke-width="5"/>'
         f'<circle cx="32" cy="32" r="6" fill="{CYAN}"/>')
    # viewers: eye
    icon("viewers", f'<path d="M4 32 Q32 6 60 32 Q32 58 4 32 Z" fill="#12202A" stroke="{CREAM}" stroke-width="4" stroke-linejoin="round"/>'
         f'<circle cx="32" cy="32" r="11" fill="{CYAN}"/><circle cx="32" cy="32" r="5" fill="#0A1418"/>'
         '<circle cx="36" cy="28" r="2.5" fill="#fff"/>')
    # hype: flame
    icon("hype", f'<path d="M32 4 C40 16 52 22 52 38 A20 20 0 0 1 12 38 C12 30 17 25 20 20 C22 26 25 28 27 28 C24 18 26 10 32 4 Z" fill="{ORANGE}" stroke="#8A3A12" stroke-width="3" stroke-linejoin="round"/>'
         f'<path d="M32 28 C37 34 42 37 42 44 A10 10 0 0 1 22 44 C22 38 28 36 32 28 Z" fill="#FFE27A"/>')
    # clock: stopwatch
    icon("clock", f'<circle cx="32" cy="36" r="22" fill="#1B120C" stroke="{CREAM}" stroke-width="5"/>'
         f'<path d="M26 6 H38 M32 6 V14" stroke="{CREAM}" stroke-width="5" stroke-linecap="round"/>'
         f'<path d="M32 36 V22 M32 36 L42 42" stroke="{CYAN}" stroke-width="5" stroke-linecap="round" fill="none"/>'
         f'<path d="M50 14 L55 19" stroke="{CREAM}" stroke-width="5" stroke-linecap="round"/>')
    # shots: cue stick + ball
    icon("shots", f'<path d="M6 58 L40 24" stroke="{BRASS}" stroke-width="7" stroke-linecap="round"/>'
         f'<path d="M6 58 L16 48" stroke="#5A3825" stroke-width="8" stroke-linecap="round"/>'
         f'<path d="M38 26 L42 22" stroke="{CYAN}" stroke-width="7" stroke-linecap="round"/>'
         f'<circle cx="49" cy="15" r="11" fill="{CREAM}" stroke="#0A0604" stroke-width="2"/>'
         f'<circle cx="49" cy="15" r="4.5" fill="{PINK}"/>')
    # night: crescent + star
    icon("night", f'<path d="M42 6 A26 26 0 1 0 58 40 A21 21 0 0 1 42 6 Z" fill="{BRASS_L}" stroke="{BRASS_D}" stroke-width="3" stroke-linejoin="round"/>'
         f'<path d="M50 8 L52 14 L58 16 L52 18 L50 24 L48 18 L42 16 L48 14 Z" fill="{CYAN}"/>')
    # round: rack triangle with balls
    icon("round", f'<path d="M32 6 L58 54 H6 Z" fill="#1B120C" stroke="{BRASS}" stroke-width="5" stroke-linejoin="round"/>'
         f'<circle cx="32" cy="22" r="6" fill="{PINK}"/><circle cx="24" cy="38" r="6" fill="{CYAN}"/><circle cx="40" cy="38" r="6" fill="{CREAM}"/>')
    # gear
    teeth = "".join(f'<rect x="28" y="2" width="8" height="12" rx="2" transform="rotate({a} 32 32)" fill="{BRASS}"/>' for a in range(0, 360, 45))
    icon("gear", teeth + f'<circle cx="32" cy="32" r="19" fill="{BRASS}" stroke="{BRASS_D}" stroke-width="3"/>'
         f'<circle cx="32" cy="32" r="8" fill="#22130C" stroke="{BRASS_L}" stroke-width="2.5"/>')
    # pause / close / back
    icon("pause", f'<rect x="14" y="10" width="13" height="44" rx="4" fill="{CREAM}"/><rect x="37" y="10" width="13" height="44" rx="4" fill="{CREAM}"/>')
    icon("close", f'<path d="M14 14 L50 50 M50 14 L14 50" stroke="{CREAM}" stroke-width="9" stroke-linecap="round"/>')
    icon("back", f'<path d="M40 10 L16 32 L40 54" stroke="{CREAM}" stroke-width="9" stroke-linecap="round" stroke-linejoin="round" fill="none"/>')
    # controls: gamepad
    icon("controls", f'<path d="M16 16 H48 Q60 16 60 34 Q60 52 52 52 Q46 52 42 44 H22 Q18 52 12 52 Q4 52 4 34 Q4 16 16 16 Z" fill="#3B2316" stroke="{CREAM}" stroke-width="4" stroke-linejoin="round"/>'
         f'<path d="M19 26 V40 M12 33 H26" stroke="{CYAN}" stroke-width="4.5" stroke-linecap="round"/>'
         f'<circle cx="43" cy="30" r="4" fill="{PINK}"/><circle cx="51" cy="37" r="4" fill="{BRASS_L}"/>')
    # skins: t-shirt
    icon("skins", f'<path d="M22 8 L6 16 L12 28 L18 25 V56 H46 V25 L52 28 L58 16 L42 8 Q32 18 22 8 Z" fill="{PINK}" stroke="{CREAM}" stroke-width="4" stroke-linejoin="round"/>'
         f'<circle cx="32" cy="36" r="7" fill="{CREAM}"/><circle cx="32" cy="36" r="3" fill="#0A0604"/>')
    # crew: two heads
    icon("crew", f'<circle cx="22" cy="20" r="10" fill="{CYAN}" stroke="{CREAM}" stroke-width="3"/>'
         f'<path d="M2 54 Q2 34 22 34 Q42 34 42 54 Z" fill="{CYAN}" stroke="{CREAM}" stroke-width="3" stroke-linejoin="round"/>'
         f'<circle cx="46" cy="24" r="9" fill="{PINK}" stroke="{CREAM}" stroke-width="3"/>'
         f'<path d="M30 56 Q30 38 46 38 Q62 38 62 56 Z" fill="{PINK}" stroke="{CREAM}" stroke-width="3" stroke-linejoin="round"/>')


# ---- touch widgets ------------------------------------------------------------------------------

def touch():
    d = rad("p", "#2A170E", "#0E0805", 0.82, 0.82, r=0.6)
    b = f'<circle cx="48" cy="48" r="45" fill="url(#p)" stroke="{BRASS}" stroke-width="4"/>'
    b += '<circle cx="48" cy="48" r="38" fill="none" stroke="rgba(255,255,255,0.12)" stroke-width="2"/>'
    put("touch_btn", svg(96, 96, b, d))
    d = rad("p", "#6A2147", "#2A0A1B", 0.9, 0.9, r=0.6)
    b = f'<circle cx="48" cy="48" r="45" fill="url(#p)" stroke="{PINK_L}" stroke-width="5"/>'
    b += f'<circle cx="48" cy="48" r="38" fill="none" stroke="{CYAN}" stroke-width="2.5" opacity="0.8"/>'
    put("touch_btn_sel", svg(96, 96, b, d))
    b = f'<circle cx="80" cy="80" r="76" fill="rgba(14,8,5,0.22)" stroke="rgba(242,217,139,0.55)" stroke-width="4"/>'
    b += '<circle cx="80" cy="80" r="52" fill="none" stroke="rgba(255,255,255,0.1)" stroke-width="2"/>'
    put("touch_stick_ring", svg(160, 160, b))
    d = lin("k", BRASS_L, BRASS_D, 0, 0, 1, 1)
    b = f'<circle cx="32" cy="32" r="29" fill="url(#k)" stroke="#0A0604" stroke-width="3"/>'
    b += f'<circle cx="32" cy="32" r="16" fill="#2A170E" stroke="{CYAN}" stroke-width="2.5"/>'
    put("touch_stick_knob", svg(64, 64, b, d))


# ---- logo + menu background ---------------------------------------------------------------------

def logo():
    d = rad("g", PINK, PINK, 0.5, 0, r=0.5) + lin("b", "#34343C", "#050507", 0.2, 0, 0.8, 1) + rad("h", "#fff", "#fff", 0.75, 0, 0.32, 0.3, 0.28)
    b = '<circle cx="128" cy="128" r="124" fill="url(#g)"/>'
    b += f'<circle cx="128" cy="128" r="112" fill="none" stroke="{PINK}" stroke-width="6"/>'
    b += f'<circle cx="128" cy="128" r="102" fill="none" stroke="{CYAN}" stroke-width="3" opacity="0.8"/>'
    b += '<circle cx="128" cy="128" r="90" fill="url(#b)" stroke="#000" stroke-width="3"/>'
    b += f'<circle cx="128" cy="124" r="40" fill="{CREAM}"/>'
    b += '<path d="M116 106 Q128 98 140 106 Q146 118 136 123 Q146 128 142 140 Q128 152 114 140 Q110 128 120 123 Q110 118 116 106 Z M123 110 Q128 107 133 110 Q135 116 129 119 Q122 116 123 110 Z M122 131 Q128 128 134 131 Q137 138 128 142 Q119 138 122 131 Z" fill="#0A0A0C" fill-rule="evenodd"/>'
    b += '<ellipse cx="102" cy="88" rx="30" ry="18" fill="url(#h)" transform="rotate(-30 102 88)"/>'
    # crossed cues behind the ring
    b = (f'<path d="M20 236 L236 20" stroke="{BRASS}" stroke-width="9" stroke-linecap="round" opacity="0.9"/>'
         f'<path d="M236 236 L20 20" stroke="{BRASS_L}" stroke-width="9" stroke-linecap="round" opacity="0.9"/>') + b
    put("logo_emblem", svg(256, 256, b, d))


def menu_bg():
    d = (lin("bg", "#0A0610", "#1C0F14") + lin("cone", "#FFE9A8", "#FFE9A8", 0, 0, 0, 1) +
         rad("vig", "#000", "#000", 0, 0.85, r=0.75) + lin("fe", "#14664C", "#0B3A2B") + lin("wo", "#4B2D1C", "#1C0F08") +
         rad("pool", "#FFD98A", "#FFD98A", 0.35, 0, 0.5, 0.78, 0.45) + rad("pk", PINK, PINK, 0.55, 0, r=0.5) + rad("cy", CYAN, CYAN, 0.45, 0, r=0.5))
    b = '<rect width="1280" height="720" fill="url(#bg)"/>'
    b += f'<ellipse cx="190" cy="150" rx="260" ry="190" fill="url(#pk)"/><ellipse cx="1120" cy="560" rx="300" ry="200" fill="url(#cy)"/>'
    # hanging lamps
    for cx in (320, 960):
        b += f'<path d="M{cx} 0 V70" stroke="#000" stroke-width="3"/>'
        b += f'<path d="M{cx - 44} 110 L{cx - 12} 70 H{cx + 12} L{cx + 44} 110 Z" fill="#2A1A10" stroke="{BRASS_D}" stroke-width="3"/>'
        b += f'<path d="M{cx - 44} 110 L{cx - 230} 560 H{cx + 230} L{cx + 44} 110 Z" fill="url(#cone)" opacity="0.09"/>'
        b += f'<ellipse cx="{cx}" cy="108" rx="40" ry="6" fill="#FFE9A8" opacity="0.9"/>'
    # table (perspective trapezoid)
    b += '<path d="M120 420 H1160 L1280 720 H0 Z" fill="url(#wo)"/>'
    b += '<path d="M190 450 H1090 L1190 700 H90 Z" fill="url(#fe)" stroke="#2A170E" stroke-width="10" stroke-linejoin="round"/>'
    b += f'<path d="M190 450 H1090 L1190 700 H90 Z" fill="none" stroke="{BRASS_D}" stroke-width="2" transform="translate(0 -6)"/>'
    b += '<ellipse cx="640" cy="620" rx="520" ry="150" fill="url(#pool)"/>'
    for (x, y, r, c) in ((760, 600, 15, PINK), (806, 590, 15, CYAN), (852, 612, 15, "#F2D98B"), (700, 640, 15, RED), (900, 650, 15, "#8E6BFF"), (520, 628, 15, CREAM)):
        b += f'<ellipse cx="{x}" cy="{y + 14}" rx="{r + 3}" ry="6" fill="#000" opacity="0.35"/><circle cx="{x}" cy="{y}" r="{r}" fill="{c}"/><circle cx="{x - 5}" cy="{y - 5}" r="4" fill="#fff" opacity="0.6"/>'
    b += f'<path d="M290 640 L500 628" stroke="{BRASS}" stroke-width="7" stroke-linecap="round"/><path d="M290 640 L330 637" stroke="#5A3825" stroke-width="9" stroke-linecap="round"/>'
    b += '<rect width="1280" height="720" fill="url(#vig)"/>'
    put("menu_bg", svg(1280, 720, b, d, out=(1024, 576)))


def main():
    panel_frame(); panel_inset(); hud_plate(); buttons(); tabs(); slider(); checks(); scroll(); line_edit()
    icons(); touch(); logo(); menu_bg()
    os.makedirs(OUT, exist_ok=True)
    for name, content in FILES.items():
        with open(os.path.join(OUT, name + ".svg"), "w") as f:
            f.write(content)
    print(f"{len(FILES)} sprites -> {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
