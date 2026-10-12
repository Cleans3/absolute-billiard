"""Reel atlas of the bar slot (docs/plan/02 §3.8): assets/slot/symbols.svg, 8 cells of 128x64 side by side, in
`SlotMath.Sym` order (cherry, lemon, bell, bar, seven, eight, skull) then one plain white cell the cabinet's untextured
faces sample. Plain SVG like the icons (no <text>, no filters, no clipPath: ThorVG draws it as written).
Run `python3 src/tools/slot_art.py`, then `godot --path . --headless --import`."""
import os

CELL_W, CELL_H = 128, 64
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "slot", "symbols.svg")

CREAM, INK = "#F6EBD0", "#120A08"
RED, RED_D, GOLD, GOLD_L, GOLD_D = "#E8283C", "#9B1226", "#FFC93A", "#FFE58A", "#B8851B"
GREEN, YELLOW, YELLOW_D = "#3FBF5F", "#FFE23A", "#D9A91A"
CX, CY = CELL_W / 2, CELL_H / 2


def plate(fill="#F6EBD0", edge="#8A6A2A"):
    return (f'<rect x="3" y="2" width="{CELL_W - 6}" height="{CELL_H - 4}" rx="9" fill="{fill}" stroke="{edge}" stroke-width="2"/>'
            f'<rect x="7" y="5" width="{CELL_W - 14}" height="9" rx="4" fill="#FFFFFF" opacity="0.35"/>')


def cherry():
    return (plate()
            + f'<path d="M{CX - 14} 38 Q{CX - 10} 16 {CX + 8} 10" fill="none" stroke="{GREEN}" stroke-width="3" stroke-linecap="round"/>'
            + f'<path d="M{CX + 16} 36 Q{CX + 14} 18 {CX + 8} 10" fill="none" stroke="{GREEN}" stroke-width="3" stroke-linecap="round"/>'
            + f'<ellipse cx="{CX + 9}" cy="9" rx="9" ry="4" fill="{GREEN}" transform="rotate(-20 {CX + 9} 9)"/>'
            + f'<circle cx="{CX - 15}" cy="43" r="12" fill="{RED}" stroke="{RED_D}" stroke-width="2"/>'
            + f'<circle cx="{CX + 16}" cy="41" r="12" fill="{RED}" stroke="{RED_D}" stroke-width="2"/>'
            + f'<circle cx="{CX - 19}" cy="38" r="3.5" fill="#FFFFFF" opacity="0.8"/>'
            + f'<circle cx="{CX + 12}" cy="36" r="3.5" fill="#FFFFFF" opacity="0.8"/>')


def lemon():
    return (plate()
            + f'<path d="M{CX - 30} {CY + 2} Q{CX - 24} {CY - 20} {CX} {CY - 20} Q{CX + 24} {CY - 20} {CX + 30} {CY + 2}'
              f' Q{CX + 24} {CY + 24} {CX} {CY + 24} Q{CX - 24} {CY + 24} {CX - 30} {CY + 2} Z" fill="{YELLOW}" stroke="{YELLOW_D}" stroke-width="2.5"/>'
            + f'<path d="M{CX - 30} {CY + 2} L{CX - 36} {CY - 2}" stroke="{YELLOW_D}" stroke-width="4" stroke-linecap="round"/>'
            + f'<path d="M{CX + 30} {CY + 2} L{CX + 36} {CY + 6}" stroke="{YELLOW_D}" stroke-width="4" stroke-linecap="round"/>'
            + f'<ellipse cx="{CX - 8}" cy="{CY - 9}" rx="11" ry="4" fill="#FFFFFF" opacity="0.6"/>'
            + f'<ellipse cx="{CX + 22}" cy="{CY - 9}" rx="9" ry="4" fill="{GREEN}" transform="rotate(-25 {CX + 22} {CY - 9})"/>')


def bell():
    return (plate()
            + f'<path d="M{CX - 22} 48 Q{CX - 20} 40 {CX - 17} 30 Q{CX - 14} 11 {CX} 11 Q{CX + 14} 11 {CX + 17} 30 Q{CX + 20} 40 {CX + 22} 48 Z"'
              f' fill="{GOLD}" stroke="{GOLD_D}" stroke-width="2.5" stroke-linejoin="round"/>'
            + f'<path d="M{CX - 11} 18 Q{CX - 14} 30 {CX - 15} 42" fill="none" stroke="{GOLD_L}" stroke-width="4" stroke-linecap="round"/>'
            + f'<rect x="{CX - 25}" y="46" width="50" height="6" rx="3" fill="{GOLD_D}"/>'
            + f'<circle cx="{CX}" cy="55" r="4.5" fill="{GOLD_D}"/>'
            + f'<circle cx="{CX}" cy="8" r="3.5" fill="{GOLD_D}"/>')


def bar():
    def letter(x, d):
        return f'<path d="{d}" transform="translate({x} 0)" fill="none" stroke="#FFFFFF" stroke-width="5.5" stroke-linecap="round" stroke-linejoin="round"/>'
    return (plate("#2A1A14", "#C9A24B")
            + f'<rect x="12" y="13" width="{CELL_W - 24}" height="{CELL_H - 26}" rx="6" fill="#111111" stroke="{GOLD}" stroke-width="2"/>'
            + letter(CX - 36, "M0 20 L0 44 M0 20 L9 20 Q17 20 17 27 Q17 32 9 32 L0 32 M9 32 Q19 32 19 38 Q19 44 9 44 L0 44")  # B
            + letter(CX - 8, "M0 44 L9 20 L18 44 M3 36 L15 36")  # A
            + letter(CX + 22, "M0 44 L0 20 L9 20 Q17 20 17 27 Q17 33 9 33 L0 33 M9 33 L18 44"))  # R


def seven():
    return (plate("#FFF7DF", "#B03020")
            + f'<path d="M{CX - 18} 14 L{CX + 20} 14 L{CX + 20} 20 L{CX - 2} 52 L{CX - 14} 52 L{CX + 6} 22 L{CX - 18} 22 Z"'
              f' fill="{RED}" stroke="{RED_D}" stroke-width="3" stroke-linejoin="round"/>'
            + f'<path d="M{CX - 14} 17 L{CX + 15} 17" stroke="#FFFFFF" stroke-width="2.5" stroke-linecap="round" opacity="0.7"/>')


def eight():
    return (plate("#102A22", "#3DE0FF")
            + f'<circle cx="{CX}" cy="{CY}" r="26" fill="#0B0B0B" stroke="#555555" stroke-width="2"/>'
            + f'<ellipse cx="{CX - 9}" cy="{CY - 12}" rx="9" ry="5" fill="#FFFFFF" opacity="0.35" transform="rotate(-30 {CX - 9} {CY - 12})"/>'
            + f'<circle cx="{CX}" cy="{CY}" r="12" fill="#FFFFFF"/>'
            + f'<circle cx="{CX}" cy="{CY - 4.5}" r="3.6" fill="none" stroke="#0B0B0B" stroke-width="2.6"/>'
            + f'<circle cx="{CX}" cy="{CY + 4.5}" r="4.4" fill="none" stroke="#0B0B0B" stroke-width="2.6"/>')


def skull():
    return (plate("#2A0E18", "#FF3D9A")
            + f'<path d="M{CX - 22} {CY - 2} Q{CX - 22} {CY - 24} {CX} {CY - 24} Q{CX + 22} {CY - 24} {CX + 22} {CY - 2}'
              f' Q{CX + 22} {CY + 6} {CX + 14} {CY + 9} L{CX + 14} {CY + 20} L{CX - 14} {CY + 20} L{CX - 14} {CY + 9} Q{CX - 22} {CY + 6} {CX - 22} {CY - 2} Z"'
              f' fill="#F2EEE6" stroke="#B9B2A4" stroke-width="2"/>'
            + f'<circle cx="{CX - 9}" cy="{CY - 3}" r="6.5" fill="{INK}"/>'
            + f'<circle cx="{CX + 9}" cy="{CY - 3}" r="6.5" fill="{INK}"/>'
            + f'<path d="M{CX} {CY + 3} L{CX - 3.5} {CY + 10} L{CX + 3.5} {CY + 10} Z" fill="{INK}"/>'
            + f'<path d="M{CX - 7} {CY + 13} L{CX - 7} {CY + 20} M{CX} {CY + 13} L{CX} {CY + 20} M{CX + 7} {CY + 13} L{CX + 7} {CY + 20}" stroke="{INK}" stroke-width="2"/>')


def blank():
    return f'<rect x="0" y="0" width="{CELL_W}" height="{CELL_H}" fill="#FFFFFF"/>'


CELLS = [cherry, lemon, bell, bar, seven, eight, skull, blank]


def build():
    body = "".join(f'<g transform="translate({i * CELL_W} 0)">{cell()}</g>' for i, cell in enumerate(CELLS))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CELL_W * len(CELLS)}" height="{CELL_H}" '
            f'viewBox="0 0 {CELL_W * len(CELLS)} {CELL_H}">{body}</svg>\n')


if __name__ == "__main__":
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(build())
    print("wrote", os.path.normpath(OUT))
