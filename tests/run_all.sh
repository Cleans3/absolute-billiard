#!/usr/bin/env bash
# Every headless probe + the two-peer pair probes. Used by CI (.github/workflows/ci.yml) and by hand.
#   tests/run_all.sh            all probes
#   tests/run_all.sh physics    only tests/physics/*
# A probe passes when it exits 0, prints "OK" (or "... SKIP: reason") on a line of its own and no SCRIPT ERROR.
set -u
cd "$(dirname "$0")/.."
filter=${1:-}
fail=0
for p in $(find tests -name '*_probe.gd' -o -name probe.gd | sort); do
  [[ $p == *pair_probe.gd ]] && continue
  [[ -n $filter && $p != tests/$filter/* ]] && continue
  log=$(mktemp)
  timeout "${PROBE_TIMEOUT:-300}" godot --path . --headless -s "$p" >"$log" 2>&1; rc=$?
  if [ $rc = 0 ] && grep -qE '(^| )(OK|SKIP.*)$' "$log" && ! grep -q 'SCRIPT ERROR' "$log"; then
    echo "ok   $p"
  else
    echo "FAIL $p (rc=$rc)"; tail -15 "$log"; fail=1
  fi
  rm -f "$log"
done
for p in $(find tests -name '*pair_probe.gd' | sort); do
  [[ -n $filter && $p != tests/$filter/* ]] && continue
  bash tests/net/pair.sh "$p" || fail=1
done
if [[ -z $filter || $filter == net ]]; then
  python3 deploy/noray/tunnel.py --selftest || fail=1
fi
[ $fail = 0 ] && echo "ALL PROBES OK"
exit $fail
