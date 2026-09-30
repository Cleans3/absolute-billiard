#!/usr/bin/env bash
# Two headless peers on localhost ENet: ./tests/net/pair.sh tests/net/pair_probe.gd
# Host starts first, client joins once the host prints LISTENING. Both must exit 0 and print "... OK".
# Probes read `--role=host|client --port=N` via OS.get_cmdline_user_args().
set -u
probe="${1:?usage: pair.sh <probe.gd> [extra probe args]}"; shift
cd "$(dirname "$0")/../.."
port=$((20000 + RANDOM % 20000))
log="$(mktemp -d)"; export PAIR_DIR="$log"  # probes trade small files here (e.g. the lobby code)
run() { timeout "${PAIR_TIMEOUT:-60}" godot --path . --headless -s "$probe" -- --role="$1" --port="$port" "${@:2}" >"$log/$1.log" 2>&1; echo $? >"$log/$1.rc"; }
run host "$@" & hp=$!
for _ in $(seq 100); do grep -q LISTENING "$log/host.log" 2>/dev/null && break; sleep 0.2; done
run client "$@" & cp=$!
wait $hp $cp
rc=0
for r in host client; do
	if [ "$(cat "$log/$r.rc")" != 0 ] || ! grep -q " OK$" "$log/$r.log"; then
		echo "PAIR FAIL ($r, rc=$(cat "$log/$r.rc"))"; tail -25 "$log/$r.log"; rc=1
	fi
done
[ $rc = 0 ] && echo "PAIR OK ($(basename "$probe"))"
rm -rf "$log"
exit $rc
