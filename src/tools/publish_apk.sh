#!/usr/bin/env bash
# Build the debug APK and put it on the relay box's share page: phone opens http://<relay>:8892/ and installs.
# Usage: src/tools/publish_apk.sh [--no-build]   RELAY_SSH overrides the ssh target (default root@160.191.243.188).
set -euo pipefail
cd "$(dirname "$0")/../.."
relay="${RELAY_SSH:-root@160.191.243.188}"
[ "${1:-}" = --no-build ] || bash src/tools/android_export.sh
scp -q build/android/ab.apk "$relay:/opt/noray/ab.apk.tmp"
scp -q deploy/noray/join_page.py "$relay:/opt/noray/join_page.py"
ssh "$relay" 'cd /opt/noray && mv ab.apk.tmp ab.apk && chown noray:noray ab.apk join_page.py && systemctl restart join'
echo "APK live: http://${relay#*@}:8892/"
