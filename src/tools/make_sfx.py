#!/usr/bin/env python3
"""Renders assets/audio/sfx/*.ogg (docs/plan/07 §8, 06 P54): code-synthesised sounds (CC0 by construction) plus a mono re-encode of
the Kenney CC0 picks. Needs numpy and an ffmpeg with libvorbis (env FFMPEG, default `ffmpeg`).

  python3 src/tools/make_sfx.py --kenney <dir with the unzipped packs, one folder per slug> [--out assets/audio/sfx]

Kenney packs (https://kenney.nl/assets/<slug>, CC0): interface-sounds, ui-audio, casino-audio, impact-sounds, sci-fi-sounds,
digital-audio. Every pick is listed in KENNEY below and in assets/CREDITS.md. Synth is seeded: the same run renders the same files.
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 44100
RNG = np.random.default_rng(1014)

# output name -> (pack slug, file stem). Re-encoded mono, 32 kHz, vorbis q1.5.
KENNEY = {
    "ui_click_a": ("ui-audio", "click3"),
    "ui_click_b": ("ui-audio", "click5"),
    "ui_confirm": ("interface-sounds", "confirmation_002"),
    "ui_error": ("interface-sounds", "error_005"),
    "ui_switch": ("ui-audio", "switch12"),
    "vent_open": ("sci-fi-sounds", "doorOpen_001"),
    "vent_close": ("sci-fi-sounds", "doorClose_001"),
    "flap_open": ("impact-sounds", "impactMetal_heavy_001"),
    "flap_shut": ("impact-sounds", "impactMetal_medium_002"),
    "trap_open": ("sci-fi-sounds", "doorOpen_002"),
    "trap_close": ("impact-sounds", "impactMetal_heavy_003"),
    "bump": ("impact-sounds", "impactWood_heavy_001"),
    "kick": ("impact-sounds", "impactWood_medium_002"),
    "glass": ("impact-sounds", "impactGlass_medium_001"),
    "chalk": ("interface-sounds", "scratch_003"),
    "lean": ("impact-sounds", "impactSoft_medium_001"),
    "chips_a": ("casino-audio", "chips-handle-2"),
    "chips_b": ("casino-audio", "chips-collide-3"),
    "zap": ("digital-audio", "zap1"),
}


# --- synth toolbox ---------------------------------------------------------------------------------------------------

def t_axis(sec):
    return np.arange(int(sec * SR)) / SR


def decay(t, tau):
    return np.exp(-t / tau)


def sine(t, f):
    return np.sin(2 * np.pi * f * t)


def noise(n):
    return RNG.uniform(-1, 1, n)


def lowpass(x, fc):
    a = 1 - np.exp(-2 * np.pi * fc / SR)
    y = np.empty_like(x)
    s = 0.0
    for i, v in enumerate(x):
        s += a * (v - s)
        y[i] = s
    return y


def highpass(x, fc):
    return x - lowpass(x, fc)


def pad(x, n):
    out = np.zeros(n)
    out[: min(n, len(x))] = x[:n]
    return out


def place(dst, src, at_sec, gain=1.0):
    i = int(at_sec * SR)
    j = min(len(dst), i + len(src))
    if i < len(dst):
        dst[i:j] += src[: j - i] * gain
    return dst


def fade(x, ms=4):
    n = int(ms / 1000 * SR)
    if n * 2 < len(x):
        x = x.copy()
        x[:n] *= np.linspace(0, 1, n)
        x[-n:] *= np.linspace(1, 0, n)
    return x


def norm(x, peak=0.89):
    m = np.max(np.abs(x))
    return x / m * peak if m > 0 else x


def note(freq, sec, kind="tri", tau=None):
    """One decaying note: triangle / square / bell partials."""
    t = t_axis(sec)
    if kind == "tri":
        w = 2 / np.pi * np.arcsin(np.sin(2 * np.pi * freq * t))
    elif kind == "sq":
        w = lowpass(np.sign(np.sin(2 * np.pi * freq * t)), 3200) * 0.7
    elif kind == "saw":
        w = lowpass(2 * ((freq * t) % 1.0) - 1, 2600)
    else:  # bell
        w = sine(t, freq) + 0.5 * sine(t, freq * 2.01) * decay(t, 0.12) + 0.25 * sine(t, freq * 3.02) * decay(t, 0.06)
    return fade(w * decay(t, tau or sec * 0.5), 3)


def arpeggio(freqs, step, kind="tri", tail=0.25):
    out = np.zeros(int((step * len(freqs) + tail) * SR))
    for k, f in enumerate(freqs):
        place(out, note(f, step + tail, kind, (step + tail) * 0.45), k * step)
    return out


C4, D4, E4, F4, G4, A4, B4 = 261.63, 293.66, 329.63, 349.23, 392.0, 440.0, 493.88
C5, D5, E5, F5, G5, A5, B5, C6, D6, E6, G6 = 523.25, 587.33, 659.25, 698.46, 783.99, 880.0, 987.77, 1046.5, 1174.7, 1318.5, 1568.0


# --- the billiard set --------------------------------------------------------------------------------------------------

def clack(hard, variant):
    """Ball on ball: a click, then ringing partials of a phenolic sphere. hard 0 dull .. 2 bright."""
    sec = 0.11
    t = t_axis(sec)
    shift = 1.0 + 0.07 * variant
    base = (2300, 3400, 5200)[:]
    amp = ((1.0, 0.45, 0.15), (1.0, 0.7, 0.35), (1.0, 0.9, 0.6))[hard]
    tau = (0.016, 0.012, 0.009)
    x = sum(a * sine(t, f * shift) * decay(t, tu * (1 + 0.5 * hard)) for a, f, tu in zip(amp, base, tau))
    x = x + (0.5 + 0.3 * hard) * highpass(noise(len(t)), 1800) * decay(t, 0.0016)
    x = x + (0.8 - 0.2 * hard) * sine(t, 310 * shift) * decay(t, 0.012)  # the body thock
    if hard == 0:
        x = lowpass(x, 4200)
    return fade(norm(x), 2)


def cue_tip():
    t = t_axis(0.16)
    x = 1.0 * sine(t, 1750) * decay(t, 0.010) + 0.9 * sine(t, 190) * decay(t, 0.035)
    x = x + 0.8 * highpass(noise(len(t)), 1500) * decay(t, 0.003)
    x = x + 0.4 * sine(t, 2900) * decay(t, 0.008)
    return fade(norm(x), 2)


def rail(variant):
    t = t_axis(0.2)
    f = 150 - 70 * np.minimum(t / 0.08, 1.0)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR + variant) * decay(t, 0.035)
    x = x + 0.9 * lowpass(noise(len(t)), 1100 + 250 * variant) * decay(t, 0.022)
    x = x + 0.35 * sine(t, 420 + 40 * variant) * decay(t, 0.012)
    return fade(norm(x), 2)


def pocket_drop():
    out = np.zeros(int(0.7 * SR))
    place(out, clack(0, 0)[: int(0.06 * SR)], 0.0, 0.9)
    for at, f, g in ((0.10, 340, 0.8), (0.19, 290, 0.6), (0.26, 250, 0.45), (0.31, 220, 0.3)):  # the bounces in the cup
        t = t_axis(0.09)
        place(out, (sine(t, f) * decay(t, 0.02) + 0.5 * lowpass(noise(len(t)), 900) * decay(t, 0.012)), at, g)
    t = t_axis(0.5)
    roll = lowpass(noise(len(t)), 700) * np.minimum(t / 0.05, 1.0) * decay(t, 0.14)  # the rattle down the chute
    place(out, roll, 0.08, 0.45)
    return fade(norm(out), 4)


def ding(f=B5, sec=0.7):
    t = t_axis(sec)
    x = sine(t, f) + 0.45 * sine(t, f * 2.0) * decay(t, 0.2) + 0.2 * sine(t, f * 3.01) * decay(t, 0.09)
    return fade(norm(x * decay(t, 0.28)), 3)


def coin():
    out = np.zeros(int(0.32 * SR))
    place(out, note(B5 * 1.0, 0.2, "bell", 0.05), 0.0)
    place(out, note(E6, 0.26, "bell", 0.08), 0.07)
    return fade(norm(out), 2)


def register():
    out = np.zeros(int(0.9 * SR))
    t = t_axis(0.05)
    place(out, highpass(noise(len(t)), 1200) * decay(t, 0.008) + 0.6 * sine(t, 220) * decay(t, 0.02), 0.0, 0.8)  # the drawer
    place(out, note(G6, 0.7, "bell", 0.16), 0.05)
    place(out, note(C6, 0.6, "bell", 0.12), 0.0, 0.7)
    return fade(norm(out), 3)


def lever():
    out = np.zeros(int(0.5 * SR))
    for k, at in enumerate((0.0, 0.05, 0.095, 0.135, 0.17, 0.2)):  # a ratchet that speeds up
        t = t_axis(0.02)
        place(out, (highpass(noise(len(t)), 2000) + 0.5 * sine(t, 1500 + 90 * k)) * decay(t, 0.004), at, 0.5 + 0.08 * k)
    t = t_axis(0.2)
    place(out, sine(t, 120) * decay(t, 0.05) + 0.6 * lowpass(noise(len(t)), 600) * decay(t, 0.03), 0.22)  # the thunk
    return fade(norm(out), 3)


def reel_loop():
    """A seamless 0.5 s rattle of drums: two ticking trains and a buzz, all periodic in 0.5 s."""
    sec = 0.5
    n = int(sec * SR)
    t = t_axis(sec)
    out = np.zeros(n)
    for k in range(20):  # 40 ticks a second
        at = (k + 0.4 * (k % 2)) / 40.0
        tt = t_axis(0.012)
        place(out, (highpass(noise(len(tt)), 1500) + 0.4 * sine(tt, 2100)) * decay(tt, 0.003), at, 0.55 + 0.25 * (k % 3 == 0))
    out += 0.28 * sine(t, 112) * (0.65 + 0.35 * sine(t, 20))  # the drum hum, whole cycles in 0.5 s
    out += 0.12 * lowpass(noise(n), 900) * (0.6 + 0.4 * sine(t, 8))
    x = norm(out)
    xf = int(0.02 * SR)  # the tail fades into the head, so the loop point is smooth
    head = x[:xf] * np.linspace(0, 1, xf) + x[-xf:] * np.linspace(1, 0, xf)
    return np.concatenate([head, x[xf:-xf]])


def reel_stop():
    t = t_axis(0.16)
    x = 0.9 * sine(t, 95) * decay(t, 0.03) + highpass(noise(len(t)), 1800) * decay(t, 0.004) + 0.5 * sine(t, 1300) * decay(t, 0.012)
    return fade(norm(x), 2)


def win_small():
    return fade(norm(arpeggio([C5, E5, G5], 0.09, "tri", 0.18)), 3)


def win_big():
    out = arpeggio([C5, E5, G5, C6, E6, G6], 0.085, "tri", 0.35)
    t = t_axis(0.5)
    place(out, note(C6, 0.5, "bell", 0.16) * 0.7, 0.45)
    return fade(norm(out), 3)


def win_seven():
    out = arpeggio([C5, D5, E5, G5, A5, C6, D6, E6], 0.075, "sq", 0.5)
    place(out, note(C6, 0.8, "bell", 0.2), 0.58, 0.8)
    place(out, note(E6, 0.8, "bell", 0.2), 0.6, 0.6)
    place(out, note(G6, 0.9, "bell", 0.22), 0.62, 0.5)
    return fade(norm(out), 3)


def jackpot():
    sec = 3.0
    out = np.zeros(int(sec * SR))
    place(out, arpeggio([G4, C5, E5, G5, C6, E6, G6], 0.11, "sq", 0.5), 0.0, 0.8)
    t = t_axis(2.0)
    for f in (C5, E5, G5, C6):  # the held chord, with a tremolo
        place(out, sine(t, f) * (0.7 + 0.3 * sine(t, 9)) * decay(t, 0.9), 0.85, 0.28)
    for k in range(34):  # coins
        at = 0.9 + k * 0.058 + float(RNG.uniform(0, 0.03))
        place(out, note(float(RNG.choice([G6, E6, C6, 2093.0])), 0.18, "bell", 0.05), at, 0.22)
    return fade(norm(out), 5)


def fanfare():
    out = arpeggio([C5, E5, G5, C6], 0.14, "sq", 0.7)
    for f in (C5, E5, G5, C6):
        t = t_axis(0.9)
        place(out, sine(t, f) * decay(t, 0.4), 0.55, 0.3)
    return fade(norm(out), 4)


def lose():
    out = np.zeros(int(0.7 * SR))
    place(out, note(G4 * 0.75, 0.3, "sq", 0.12), 0.0)
    place(out, note(E4 * 0.75, 0.5, "sq", 0.2), 0.16, 0.9)
    return fade(norm(out), 4)


def trick():
    out = arpeggio([E5, G5, C6, E6], 0.07, "tri", 0.35)
    place(out, note(G6, 0.5, "bell", 0.15), 0.28, 0.6)
    return fade(norm(out), 3)


def trick_minor():
    return fade(norm(arpeggio([G5, C6], 0.07, "tri", 0.2)), 3)


def go():
    t = t_axis(0.5)
    f = 280 + 760 * np.minimum(t / 0.22, 1.0) ** 2
    x = lowpass(2 * ((np.cumsum(f) / SR) % 1.0) - 1, 2400) * np.minimum(t / 0.01, 1.0) * decay(t, 0.22)
    x = x + 0.5 * sine(t, 1568) * decay(t, 0.12) * (t > 0.2)
    return fade(norm(x), 4)


def time_up():
    t = t_axis(0.8)
    x = lowpass(np.sign(sine(t, 98)), 700) * decay(t, 0.3) + 0.5 * lowpass(np.sign(sine(t, 147)), 700) * decay(t, 0.25)
    return fade(norm(x), 5)


def lost():
    t = t_axis(0.55)
    f = 520 * np.exp(-t * 2.4)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * decay(t, 0.25)
    return fade(norm(x), 4)


def hazard():
    t = t_axis(1.0)
    f = np.where((t % 0.34) < 0.17, 660.0, 880.0)
    x = lowpass(np.sign(np.sin(2 * np.pi * np.cumsum(f) / SR)), 2200) * decay(t, 0.7) * np.minimum(t / 0.01, 1.0)
    x = x + 0.4 * lowpass(noise(len(t)), 1500) * decay(t, 0.15)
    return fade(norm(x), 5)


def drink():
    out = np.zeros(int(0.5 * SR))
    place(out, note(2093.0, 0.4, "bell", 0.1), 0.0, 0.7)
    t = t_axis(0.2)
    place(out, highpass(lowpass(noise(len(t)), 5000), 800) * decay(t, 0.05), 0.0, 0.4)
    return fade(norm(out), 3)


def ready():
    out = np.zeros(int(0.22 * SR))
    place(out, note(G5, 0.12, "tri", 0.04), 0.0)
    place(out, note(C6, 0.16, "tri", 0.06), 0.07)
    return fade(norm(out), 2)


def ufo_whoosh():
    t = t_axis(1.0)
    f = 180 + 900 * (t / 1.0) ** 1.6
    carrier = np.sin(2 * np.pi * np.cumsum(f) / SR)
    x = (carrier * (0.5 + 0.5 * sine(t, 11)) + 0.4 * lowpass(noise(len(t)), 1200)) * np.sin(np.pi * np.minimum(t / 1.0, 1.0)) ** 1.5
    return fade(norm(x), 8)


def ufo_farewell():
    t = t_axis(0.7)
    f = 1100 * np.exp(-t * 3.2)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * (0.6 + 0.4 * sine(t, 17)) * decay(t, 0.3)
    return fade(norm(x), 6)


def beam_blip():
    t = t_axis(0.09)
    f = 700 + 1500 * (t / 0.09)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.sin(np.pi * t / 0.09)
    return fade(norm(x), 2)


def synth_all():
    s = {
        "cue_tip": cue_tip(), "pocket_drop": pocket_drop(), "ding": ding(), "coin": coin(), "register": register(),
        "lever": lever(), "reel_loop": reel_loop(), "reel_stop": reel_stop(), "win_small": win_small(), "win_big": win_big(),
        "win_seven": win_seven(), "jackpot": jackpot(), "fanfare": fanfare(), "lose": lose(), "trick": trick(),
        "trick_minor": trick_minor(), "go": go(), "time_up": time_up(), "lost": lost(), "hazard": hazard(), "drink": drink(),
        "ready_on": ready(), "ufo_whoosh": ufo_whoosh(), "ufo_farewell": ufo_farewell(),
        "beam_blip": beam_blip(), "rail_a": rail(0), "rail_b": rail(1),
    }
    for hard, name in enumerate(("soft", "med", "hard")):
        for v, suffix in enumerate("ab"):
            s["clack_%s_%s" % (name, suffix)] = clack(hard, v)
    return s


# --- encode ------------------------------------------------------------------------------------------------------------

def write_wav(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def encode(src, dst, rate, q, gain_db=0.0):
    ff = os.environ.get("FFMPEG", "ffmpeg")
    subprocess.run([ff, "-y", "-loglevel", "error", "-i", src, "-ac", "1", "-ar", str(rate), "-af", "volume=%gdB" % gain_db,
                    "-c:a", "libvorbis", "-q:a", str(q), dst], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kenney", required=True)
    ap.add_argument("--out", default="assets/audio/sfx")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, x in synth_all().items():
            w = os.path.join(tmp, name + ".wav")
            write_wav(w, x)
            encode(w, os.path.join(a.out, name + ".ogg"), SR if name.startswith(("clack", "rail", "cue")) else 32000, 3)
        for name, (pack, stem) in KENNEY.items():
            hits = glob.glob(os.path.join(a.kenney, pack, "**", stem + ".*"), recursive=True)
            hits = [h for h in hits if h.endswith((".ogg", ".wav"))]
            if not hits:
                sys.exit("missing %s/%s" % (pack, stem))
            encode(hits[0], os.path.join(a.out, name + ".ogg"), 32000, 2, -3.0)  # headroom: the packs peak at 0 dBFS
    print("rendered", len(os.listdir(a.out)), "files into", a.out)


if __name__ == "__main__":
    main()
