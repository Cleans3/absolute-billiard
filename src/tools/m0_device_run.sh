#!/usr/bin/env bash
# M0 mobile perf gate in one command (07 §9): export "Android M0" -> adb install -> run break/bar/effects/soak ->
# pull CSVs -> print the 07 budget table PASS/FAIL. Unattended once `adb devices` lists a device.
#
#   src/tools/m0_device_run.sh                 # real phone: 100 breaks, 60 s bar orbit, 30 s effects, 5 min soak
#   src/tools/m0_device_run.sh --soak-min 20   # the 07 §7 acceptance soak
#   src/tools/m0_device_run.sh --quick         # 2-minute smoke (pipeline check)
#   src/tools/m0_device_run.sh --emulator      # boot AVD (test34), x86_64 build; numbers are NOT budgets
# Other flags: --serial S, --no-build (reuse build/android/m0*.apk), --runs N, --strict (exit 1 on any FAIL),
# --avd NAME. Output: build/m0/<timestamp>/ (CSVs, summary.csv, logcat, dumpsys, report.txt).
set -uo pipefail
cd "$(dirname "$0")/../.."

PKG=com.cleans3.absolutebilliard
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
export ANDROID_HOME=$SDK JAVA_HOME=${JAVA_HOME:-$HOME/.local/jdk-17}
export PATH="$JAVA_HOME/bin:$SDK/platform-tools:$SDK/emulator:$PATH"

QUICK=0 EMU=0 BUILD=1 STRICT=0 SERIAL="" AVD=test34 SOAK_MIN=5 RUNS=100
while [ $# -gt 0 ]; do
  case $1 in
    --quick) QUICK=1 ;;
    --emulator) EMU=1 ;;
    --no-build) BUILD=0 ;;
    --strict) STRICT=1 ;;
    --serial) SERIAL=$2; shift ;;
    --avd) AVD=$2; shift ;;
    --soak-min) SOAK_MIN=$2; shift ;;
    --runs) RUNS=$2; shift ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "M0 ERROR: $*" >&2; exit 2; }
command -v adb >/dev/null || die "adb not found (run src/tools/setup_android_toolchain.sh)"

# ---------------------------------------------------------------- device
if [ $EMU = 1 ]; then
  if ! adb devices | grep -q '^emulator-.*device$'; then
    echo "== booting emulator $AVD"
    nohup emulator -avd "$AVD" -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot >/tmp/m0-emulator.log 2>&1 &
    adb wait-for-device
    until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
  fi
  [ -n "$SERIAL" ] || SERIAL=$(adb devices | awk '/^emulator-.*device$/{print $1; exit}')
else
  [ -n "$SERIAL" ] || SERIAL=$(adb devices | awk 'NR>1 && $2=="device" && $1!~/^emulator-/{print $1; exit}')
  [ -n "$SERIAL" ] || die "no phone in 'adb devices'. Plug it in, enable Developer options -> USB debugging, accept the RSA prompt, rerun. (No phone handy: --emulator for a pipeline smoke.)"
fi
ADB=(adb -s "$SERIAL")
MODEL=$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')
SOC=$("${ADB[@]}" shell getprop ro.soc.model | tr -d '\r')
echo "== device $SERIAL ($MODEL ${SOC:+/ $SOC}) abi=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"

OUT=build/m0/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

# ---------------------------------------------------------------- build
if [ $EMU = 1 ]; then PRESET="Android M0 emu"; APK=build/android/m0-emu.apk; else PRESET="Android M0"; APK=build/android/m0.apk; fi
if [ $BUILD = 1 ]; then
  echo "== export '$PRESET' (gradle)"
  flag=()
  [ -d android/build ] || flag=(--install-android-build-template)
  mkdir -p build/android
  godot --headless --path . "${flag[@]}" --export-debug "$PRESET" "$APK" >"$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; die "export failed (log: $OUT/export.log)"; }
fi
[ -f "$APK" ] || die "$APK missing (run without --no-build)"
APK_MB=$(python3 -c "import os,sys;print('%.1f'%(os.path.getsize(sys.argv[1])/1048576))" "$APK")
echo "== APK $APK ${APK_MB} MB"

# ---------------------------------------------------------------- run
echo "== install"
"${ADB[@]}" shell am force-stop $PKG >/dev/null 2>&1
"${ADB[@]}" install -r -t "$APK" >"$OUT/install.log" 2>&1 || { cat "$OUT/install.log"; die "adb install failed"; }
"${ADB[@]}" shell svc power stayon true >/dev/null 2>&1
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

if [ $QUICK = 1 ]; then PARAMS=$'quick=1\nruns=6'; else PARAMS=$'runs='$RUNS$'\nsoak-minutes='$SOAK_MIN; fi
# user:// is the app's files dir (internal, run-as) or the external files dir depending on the build; write both
"${ADB[@]}" shell "run-as $PKG sh -c 'rm -rf files/perf; mkdir -p files; cat > files/perf_params.cfg'" <<<"$PARAMS" 2>/dev/null
"${ADB[@]}" shell "rm -rf /sdcard/Android/data/$PKG/files/perf" >/dev/null 2>&1

thermal_max() {  # highest reading over all readable thermal zones, in deg C
  "${ADB[@]}" shell 'for z in /sys/class/thermal/thermal_zone*/temp; do cat $z 2>/dev/null; done' | tr -d '\r' \
    | awk 'BEGIN{m=0} {v=$1; if (v>1000) v=v/1000; if (v>m && v<120) m=v} END{printf "%.1f", m}'
}
skin_temp() {  # zone whose type mentions skin/battery, deg C; falls back to the hottest zone
  local v
  v=$("${ADB[@]}" shell 'for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); case "$t" in *skin*|*battery*|*quiet*) echo "$(cat $z/temp 2>/dev/null)";; esac; done' | tr -d '\r' | head -1)
  [ -n "$v" ] && awk -v v="$v" 'BEGIN{if (v>1000) v=v/1000; printf "%.1f", v}' || thermal_max
}
batt_level() { "${ADB[@]}" shell dumpsys battery | tr -d '\r' | awk '/level:/{print $2}'; }

T0=$(skin_temp); B0=$(batt_level)
"${ADB[@]}" logcat -c
"${ADB[@]}" shell dumpsys gfxinfo $PKG reset >/dev/null 2>&1
echo "== launch (am start -W)"
START_TS=$(date +%s)
ACT=$("${ADB[@]}" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $PKG | tr -d '\r' | tail -1)
"${ADB[@]}" shell am start -W -n "$ACT" >"$OUT/am_start.txt" 2>&1
TOTAL_MS=$(tr -d '\r' <"$OUT/am_start.txt" | awk '/TotalTime/{print $2}')
echo "   TotalTime ${TOTAL_MS:-?} ms"

if [ $QUICK = 1 ]; then LIMIT=420; else LIMIT=$(( RUNS * 10 + 60 + 30 + SOAK_MIN * 60 + 240 )); fi
[ $EMU = 1 ] && LIMIT=$(( LIMIT * 4 ))
echo "== waiting for the sequence (limit ${LIMIT}s); Ctrl-C leaves the app running"
RSS_MAX=0; TMAX=$T0; SF_DONE=0
while :; do
  sleep 10
  now=$(( $(date +%s) - START_TS ))
  LOG=$("${ADB[@]}" logcat -d -s godot:I 2>/dev/null | tr -d '\r')
  if grep -q 'PERF|SEQUENCE|DONE' <<<"$LOG"; then break; fi
  if ! "${ADB[@]}" shell pidof $PKG >/dev/null 2>&1 && [ $now -gt 30 ]; then echo "   app exited early"; break; fi
  [ $now -gt $LIMIT ] && { echo "   TIMEOUT"; break; }
  stage=$(grep -o 'PERF|SEQUENCE|start|[a-z_]*' <<<"$LOG" | tail -1 | sed 's/.*|//')
  printf '   %4ds  stage=%s\r' "$now" "${stage:-boot}"
  rss=$("${ADB[@]}" shell dumpsys meminfo $PKG 2>/dev/null | tr -d '\r' | awk '/TOTAL RSS:/{for(i=1;i<=NF;i++) if($i=="RSS:") print $(i+1)} /^ *TOTAL +[0-9]/{if(!r) r=$2} END{}' | head -1)
  [ -n "${rss:-}" ] && [ "$rss" -gt "$RSS_MAX" ] 2>/dev/null && RSS_MAX=$rss
  t=$(skin_temp); TMAX=$(awk -v a="$TMAX" -v b="$t" 'BEGIN{print (b>a)?b:a}')
  if [ "$stage" = perf_bar ] && [ $SF_DONE = 0 ]; then  # SurfaceFlinger frame timestamps of the running orbit
    sleep 8
    LAYER=$("${ADB[@]}" shell dumpsys SurfaceFlinger --list 2>/dev/null | tr -d '\r' | grep "$PKG" | head -1)
    [ -n "$LAYER" ] && "${ADB[@]}" shell dumpsys SurfaceFlinger --latency "$LAYER" >"$OUT/sf_latency.txt" 2>/dev/null
    SF_DONE=1
  fi
done
echo
T1=$(skin_temp); B1=$(batt_level)
END_TS=$(date +%s)
"${ADB[@]}" shell dumpsys gfxinfo $PKG framestats >"$OUT/gfxinfo.txt" 2>&1
"${ADB[@]}" shell dumpsys meminfo $PKG >"$OUT/meminfo.txt" 2>&1
"${ADB[@]}" shell dumpsys batterystats --charged $PKG >"$OUT/batterystats.txt" 2>&1
"${ADB[@]}" logcat -d -s godot:I >"$OUT/logcat.txt" 2>&1

# ---------------------------------------------------------------- pull
echo "== pull"
mkdir -p "$OUT/perf"
files=$("${ADB[@]}" shell "run-as $PKG ls files/perf" 2>/dev/null | tr -d '\r')
for f in $files; do "${ADB[@]}" exec-out "run-as $PKG cat files/perf/$f" >"$OUT/perf/$f" 2>/dev/null; done
[ -f "$OUT/perf/summary.csv" ] || "${ADB[@]}" pull "/sdcard/Android/data/$PKG/files/perf/." "$OUT/perf/" >/dev/null 2>&1
[ -f "$OUT/perf/summary.csv" ] || { grep 'PERF|' "$OUT/logcat.txt" | tail -40; die "no summary.csv pulled (is the APK a debug build? run-as needs it). Log: $OUT/logcat.txt"; }

# ---------------------------------------------------------------- report
DUR=$(( END_TS - START_TS ))
python3 - "$OUT" "$EMU" "$MODEL" "${TOTAL_MS:-0}" "$RSS_MAX" "$T0" "$T1" "$TMAX" "${B0:-0}" "${B1:-0}" "$DUR" "$APK_MB" "$QUICK" <<'PY' | tee "$OUT/report.txt"
import csv, sys, os
out, emu, model, total_ms, rss_kb, t0, t1, tmax, b0, b1, dur, apk_mb, quick = sys.argv[1:]
rows = list(csv.DictReader(open(os.path.join(out, "perf/summary.csv"))))
# device-level rows (07 §4/§6/§7/§8), measured by this script, not the engine
def add(fx, name, val, lim, op, unit, gate=True):
    st = "INFO"
    if gate:
        st = "PASS" if (val <= lim if op == "<=" else val >= lim) else "FAIL"
    rows.append(dict(fixture=fx, budget=name, value=str(val), op=op, limit=str(lim), unit=unit, status=st))
if float(total_ms) > 0: add("device", "am_start_total_time", float(total_ms), 4000, "<=", "ms")
if float(rss_kb) > 0: add("device", "rss_max", round(float(rss_kb) / 1024, 1), 500, "<=", "MB")
add("device", "skin_temp_rise", round(float(t1) - float(t0), 1), 8, "<=", "C", gate=False)
add("device", "temp_max_seen", float(tmax), 0, "<=", "C", gate=False)
if float(dur) > 0 and b0 != b1:
    add("device", "battery_drop_%/h_(USB: not valid)", round((float(b0) - float(b1)) * 3600 / float(dur), 1), 12, "<=", "%/h", gate=False)
add("device", "apk_size_debug_arm64", float(apk_mb), 90, "<=", "MB", gate=False)
# SurfaceFlinger latency (only meaningful on device): frames slower than 60 Hz + 1 ms during the bar orbit
sf = os.path.join(out, "sf_latency.txt")
if os.path.exists(sf):
    ts = []
    for line in open(sf).read().splitlines()[1:]:
        p = line.split()
        if len(p) == 3 and p[1] != "9223372036854775807" and int(p[1]) > 0:
            ts.append(int(p[1]))
    d = [(b - a) / 1e6 for a, b in zip(ts, ts[1:]) if b > a]
    if len(d) > 20:
        add("device", "sf_frames_within_vsync_pct", round(100.0 * sum(1 for x in d if x <= 17.7) / len(d), 1), 95, ">=", "%")
w = max(len(r["budget"]) for r in rows)
print("\n=== M0 budget table (07) — %s%s ===" % (model, "  [EMULATOR: numbers are NOT budgets, pipeline proof only]" if emu == "1" else ""))
if quick == "1": print("    (--quick: shortened run, soak/break sample sizes below the 07 acceptance runs)")
fails = 0; last = None
for r in rows:
    if r["fixture"] != last:
        print("-- %s" % r["fixture"]); last = r["fixture"]
    v = float(r["value"]); lim = float(r["limit"])
    if r["status"] == "FAIL": fails += 1
    print("  %-*s %12.3f  %s %-10.3f %-8s %s" % (w, r["budget"], v, r["op"], lim, r["unit"], r["status"]))
print("\nM0 RESULT: %s (%d FAIL)   out=%s" % ("FAIL" if fails else "PASS", fails, out))
open(os.path.join(out, "fails"), "w").write(str(fails))
PY
FAILS=$(cat "$OUT/fails" 2>/dev/null || echo 0)
[ $STRICT = 1 ] && [ "$FAILS" != 0 ] && exit 1
exit 0
