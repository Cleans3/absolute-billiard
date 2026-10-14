#!/usr/bin/env bash
# Build noray + bun on this workstation, ship it, (re)install the systemd units (noray, join, tunnel, and the noray health timer). Idempotent.
# RELAY_SSH="root@1.2.3.4 -i ~/.ssh/key" ./vps/deploy.sh   (uses ../.env, else ../.env.example)
set -euo pipefail
: "${RELAY_SSH:?set RELAY_SSH to the ssh target and options}"
here="$(cd "$(dirname "$0")/.." && pwd)"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
git clone -q --depth 1 https://github.com/foxssake/noray.git "$w/src"
npm i --silent --prefix "$w/b" bun
cp "$w/b/node_modules/bun/bin/bun.exe" "$w/bun"
(cd "$w/src" && "$w/bun" install --production >/dev/null)
env_file="$here/.env"; [ -f "$env_file" ] || env_file="$here/.env.example"
cp "$env_file" "$w/.env"; cp "$here/join_page.py" "$here/tunnel.py" "$here/vps/"*.service "$here/vps/"*.timer "$here/vps/noray-health.sh" "$w/"
tar -C "$w" -czf "$w/bundle.tgz" bun src .env join_page.py tunnel.py noray-health.sh noray.service join.service tunnel.service noray-health.service noray-health.timer
# shellcheck disable=SC2086
target="${RELAY_SSH%% *}"; opts="${RELAY_SSH#* }"
scp -q $opts "$w/bundle.tgz" "$target:/tmp/noray-bundle.tgz"
ssh $opts "$target" 'set -e
id noray >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin noray
mkdir -p /opt/noray && tar -C /opt/noray -xzf /tmp/noray-bundle.tgz && rm /tmp/noray-bundle.tgz
chown -R noray:noray /opt/noray && chmod 600 /opt/noray/.env && chmod 755 /opt/noray/noray-health.sh
mv /opt/noray/noray.service /opt/noray/join.service /opt/noray/tunnel.service /opt/noray/noray-health.service /opt/noray/noray-health.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now noray join tunnel noray-health.timer && systemctl restart noray join tunnel
sleep 2; systemctl is-active noray join tunnel'
