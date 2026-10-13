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
    ("pot_fx_within_3s", "pot FX within 3 s of the strike (a pot someone aimed)"),
    ("pot_fx_after_3s", "pot FX later than 3 s (a ball that crept into the pocket)"),
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
    ("aim_payout_stale", "shots whose aim still shows the last payout line"),
    ("shot_duration_median_s", "shot duration median, s"),
    ("shot_duration_max_s", "shot duration max, s"),
    ("settle_median_s", "creep tail (last ball > 0.3 m/s -> rest), median s"),
    ("settle_max_s", "creep tail max, s"),
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
        pot_t = [e[0] for x in shots for e in x["fx_log"] if e[1] == "pot"]
        r["pot_fx_within_3s"] = sum(1 for t in pot_t if t <= 3.0)
        r["pot_fx_after_3s"] = sum(1 for t in pot_t if t > 3.0)
        if all("above" in s for s in shots):
            for i, k in enumerate(("03", "08", "15")):
                r[f"above_{k}_median_s"] = statistics.median(s["above"][i] for s in shots)
        out.append(r)
        tilted = {n for rd in j["rounds"] if any(x[0] == "vote" and x[1] == "sunken_ship" for x in rd.get("notes", [])) for n in rd["shots"]}
        r["_tilted"] = [x for x in shots if x["n"] in tilted]
    return out


def cell(runs, key):
    v = [r[key] for r in runs if key in r]
    if not v:
        return "-"
    m = statistics.mean(v)
    if len(v) == 1:
        return f"{m:.2f}"
    return f"{m:.2f} ({min(v):.2f}..{max(v):.2f})"


def tilted_rows(runs):
    """Shots of Rounds whose voted Event was sunken_ship (tilted_table before adhoc-1014a), per run set: duration and creep-tail median / max."""
    shots = [x for r in runs for x in r.get("_tilted", [])]
    if not shots:
        return "-"
    d = [x["duration"] for x in shots]
    t = [x["settle_s"] for x in shots if "settle_s" in x]
    tail = f", creep tail median {statistics.median(t):.1f} max {max(t):.1f}" if t else ""
    return f"{len(shots)} shots: duration median {statistics.median(d):.1f} max {max(d):.1f}{tail}"


def main():
    d = sys.argv[1]
    prefixes = sys.argv[2:]
    sets = {p: load(d, p) for p in prefixes}
    print("| metric | " + " | ".join(f"{p} (n={len(sets[p])})" for p in prefixes) + " |")
    print("|---|" + "---|" * len(prefixes))
    for key, label in ROWS:
        print(f"| {label} | " + " | ".join(cell(sets[p], key) for p in prefixes) + " |")
    print("| Sunken Ship Rounds (voted) | " + " | ".join(tilted_rows(sets[p]) for p in prefixes) + " |")


if __name__ == "__main__":
    main()
