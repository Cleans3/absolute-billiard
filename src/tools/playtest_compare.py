#!/usr/bin/env python3
"""Before/after table from playtest.gd runs: python3 src/tools/playtest_compare.py DIR before after > compare.md
Reads DIR/playtest_<prefix>_s<seed>.json for each prefix and prints the mean (min..max) of every report metric over the seeds."""
import glob
import json
import statistics
import sys

ROWS = [
    ("shots", "shots played"),
    ("pots", "pots"),
    ("scratches", "scratches"),
    ("fx_per_shot", "FX per shot"),
    ("shots_any_fx_pct", "shots with >= 1 FX, %"),
    ("shots_hit_fx_pct", "shots with a hit/pot FX, %"),
    ("first_fx_median_s", "strike -> first FX, median s"),
    ("late_feedback_shots", "shots with feedback > 0.3 s"),
    ("dead_max_s", "worst dead stretch (> 0.8 m/s), s"),
    ("shots_with_dead_over_3s", "shots with dead stretch > 3 s"),
    ("combo_shots", "combo shots (COMBO xN)"),
    ("trick_shots", "trick shots (paid or not)"),
    ("paid_trick_shots", "trick shots that paid (full show)"),
    ("rounds_with_combo_or_trick", "Rounds with a combo or trick"),
    ("rounds_with_full_show", "Rounds with a full trick/combo show (paid)"),
    ("rounds_with_chaos", "Rounds with a chaos event"),
    ("chaos_per_round", "chaos events per Round"),
    ("slot_result_max_s", "slot lever -> result, max s"),
    ("slot_pulls", "slot pulls"),
    ("slot_chaos", "slot chaos fired"),
    ("aim_fx_opaque_pct", "FX opaque 0.35 s into the aim, % of shots"),
    ("shot_duration_median_s", "shot duration median, s"),
    ("above_08_median_s", "per shot: seconds a ball moves > 0.8 m/s, median"),
    ("above_03_median_s", "per shot: seconds a ball moves > 0.3 m/s, median"),
    ("gpu_ms_p95_worst", "render GPU p95 worst shot, ms"),
    ("draw_calls_max", "draw calls max in shots"),
    ("anomalies", "anomalies"),
]


def load(d, prefix):
    out = []
    for f in sorted(glob.glob(f"{d}/playtest_{prefix}_s*.json")):
        j = json.load(open(f))
        r = j["report"]
        shots = j["shots"]
        r["fx_per_shot"] = sum(s["fx_count"] for s in shots) / max(len(shots), 1)
        r["paid_trick_shots"] = sum(1 for s in shots if s["trick_ids"] and s["pots"])
        r["rounds_with_full_show"] = sum(1 for rd in j["rounds"] if rd["beats"].get("trick", 0) + rd["beats"].get("combo", 0) > 0)
        if all("above" in s for s in shots):
            for i, k in enumerate(("03", "08", "15")):
                r[f"above_{k}_median_s"] = statistics.median(s["above"][i] for s in shots)
        out.append(r)
    return out


def cell(runs, key):
    v = [r[key] for r in runs if key in r]
    if not v:
        return "-"
    m = statistics.mean(v)
    if len(v) == 1:
        return f"{m:.2f}"
    return f"{m:.2f} ({min(v):.2f}..{max(v):.2f})"


def main():
    d = sys.argv[1]
    prefixes = sys.argv[2:]
    sets = {p: load(d, p) for p in prefixes}
    print("| metric | " + " | ".join(f"{p} (n={len(sets[p])})" for p in prefixes) + " |")
    print("|---|" + "---|" * len(prefixes))
    for key, label in ROWS:
        print(f"| {label} | " + " | ".join(cell(sets[p], key) for p in prefixes) + " |")


if __name__ == "__main__":
    main()
