#!/usr/bin/env python3
"""One-shot: fetch the CC0 Poly Haven PBR sets the bar room uses and write assets/textures/<set>/{albedo.webp,normal.png,orm.webp}.

    python3 -I src/tools/make_textures.py [cache_dir]      # default cache: $TMPDIR/ab_textures

albedo = diffuse desaturated toward grey and scaled to a fixed mean luminance: a detail map that multiplies the material's
         albedo_color, so a BarSkin colour is still set verbatim and only gains grain; normal = OpenGL green-up (Godot's);
orm    = Poly Haven `arm` (AO, roughness, metallic) which is exactly Godot's ORM channel order.
Sizes follow 07 §8: felt and floor albedo 1024, everything else 512 or less; albedo/orm are lossy WebP (the importer VRAM-compresses them anyway),
normals stay lossless PNG. Needs only Pillow. Downloads are untrusted data: the cache holds
nothing but images that Pillow decodes, never code.
"""
import json
import os
import sys
import tempfile
import urllib.request
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "textures")
UA = {"User-Agent": "absolute-billiard-art/1.0"}
TEX_MEAN = 0.7  # linear mean luminance of a detail map; the felt is brighter (a skin's felt colour must stay what it says)
MEAN = {"felt": 0.9}

# name: (poly haven id, albedo px, normal px or 0 for none, orm px, colour kept 0..1)
SETS = {
    "floor": ("dark_wooden_planks", 1024, 512, 512, 0.4),
    "wall": ("red_brick_03", 512, 512, 512, 0.6),
    "wainscot": ("wooden_panels", 512, 512, 512, 0.4),
    "ceiling": ("ceiling_interior", 512, 0, 256, 0.2),
    "wood": ("dark_wood", 512, 512, 512, 0.4),
    "seat": ("brown_leather", 512, 256, 512, 0.2),
    "metal": ("metal_plate_02", 512, 256, 512, 0.2),
    "felt": ("velour_velvet", 1024, 512, 512, 0.1),
}


def fetch(url: str, dest: str) -> None:
    if os.path.exists(dest):
        return
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
        f.write(r.read())


def srgb_to_lin(v: float) -> float:
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def lin_to_srgb(v: float) -> float:
    v = min(max(v, 0.0), 1.0)
    return v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def knee(v: float) -> float:
    """Linear up to 0.8, then rolls off toward 1.0 so bright mortar / grain highlights keep some shape instead of clipping."""
    return v if v <= 0.8 else 0.8 + 0.2 * (1.0 - 2.718281828 ** (-(v - 0.8) / 0.2))


def normalise(img: Image.Image, keep: float, mean_target: float) -> Image.Image:
    """Pull the colour `1 - keep` of the way to grey, then scale all channels together so the linear luminance averages
    `mean_target` (soft clip at 1) and re-encode sRGB. It is a detail map: the material's albedo_color (the BarSkin colour,
    set exactly as before) supplies the hue and the brightness, this only multiplies it."""
    rgb = img.convert("RGB")
    grey = rgb.convert("L").convert("RGB")
    rgb = Image.blend(grey, rgb, keep)
    n = rgb.width * rgb.height
    lin = [srgb_to_lin(i / 255.0) for i in range(256)]
    h = rgb.convert("L").histogram()
    s = mean_target / (sum(lin[i] * h[i] for i in range(256)) / n)
    return rgb.point([round(lin_to_srgb(knee(lin[i] * s)) * 255) for i in range(256)] * 3)


IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://assets/textures/{rel}"

[params]

compress/mode=2
compress/high_quality={hq}
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map={nm}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


def write_import(rel: str, hq: bool, normal: bool) -> None:
    """VRAM-compressed with mipmaps, 07 §8: the felt ASTC via high_quality, everything else ETC2; normals as normal maps.
    Godot fills in uid / dest paths on the next `godot --headless --import`; an existing .import is left alone (it holds the uid)."""
    path = os.path.join(OUT, rel + ".import")
    if os.path.exists(path):
        return
    with open(path, "w") as f:
        f.write(IMPORT.format(rel=rel, hq="true" if hq else "false", nm=1 if normal else 0))


def main() -> None:
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "ab_textures")
    os.makedirs(cache, exist_ok=True)
    notes = []
    for name, (ph, a_px, n_px, o_px, keep) in SETS.items():
        files = json.load(urllib.request.urlopen(urllib.request.Request(f"https://api.polyhaven.com/files/{ph}", headers=UA), timeout=60))
        info = json.load(urllib.request.urlopen(urllib.request.Request(f"https://api.polyhaven.com/info/{ph}", headers=UA), timeout=60))
        out = os.path.join(OUT, name)
        os.makedirs(out, exist_ok=True)
        for key, tag in (("Diffuse", "diff"), ("nor_gl", "nor"), ("arm", "arm")):
            if key == "nor_gl" and n_px == 0:
                continue
            fetch(files[key]["1k"]["jpg"]["url"], os.path.join(cache, f"{ph}_{tag}.jpg"))
        diff = Image.open(os.path.join(cache, f"{ph}_diff.jpg")).convert("RGB")
        normalise(diff.resize((a_px, a_px), Image.LANCZOS), keep, MEAN.get(name, TEX_MEAN)).save(os.path.join(out, "albedo.webp"), quality=93, method=6)
        arm = Image.open(os.path.join(cache, f"{ph}_arm.jpg")).convert("RGB")
        arm.resize((o_px, o_px), Image.LANCZOS).save(os.path.join(out, "orm.webp"), quality=93, method=6)
        if n_px:
            nor = Image.open(os.path.join(cache, f"{ph}_nor.jpg")).convert("RGB")
            nor.resize((n_px, n_px), Image.LANCZOS).save(os.path.join(out, "normal.png"), optimize=True)
        write_import(f"{name}/albedo.webp", name == "felt", False)
        write_import(f"{name}/orm.webp", False, False)
        if n_px:
            write_import(f"{name}/normal.png", False, True)
        authors = ", ".join(info.get("authors", {}).keys())
        notes.append(f"- `{name}/` = Poly Haven `{ph}` by {authors}, https://polyhaven.com/a/{ph} (real-world tile {info.get('dimensions')} mm)")
        print(name, ph, "ok")
    with open(os.path.join(OUT, "SOURCE.md"), "w") as f:
        f.write("# Bar room PBR textures (Poly Haven, CC0)\n\n"
                "Written by `src/tools/make_textures.py`: 1k JPG downloads resized to 512/1024, albedo desaturated and normalised to a fixed mean luminance\n"
                "so a BarSkin colour can tint it (see the script header). License: CC0 1.0, see LICENSE.txt.\n\n" + "\n".join(notes) + "\n")
    with open(os.path.join(OUT, "LICENSE.txt"), "w") as f:
        f.write("Poly Haven assets are released under Creative Commons Zero (CC0 1.0 Universal):\n"
                "https://creativecommons.org/publicdomain/zero/1.0/\nhttps://polyhaven.com/license\n"
                "Credit to the authors listed in SOURCE.md is not required.\n")


if __name__ == "__main__":
    main()
