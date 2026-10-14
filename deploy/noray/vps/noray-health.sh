#!/usr/bin/env bash
# Noray once went silent after ~17 h: the process lived and accepted TCP but never answered, so every
# host saw "can't reach the relay". Ask it for a host id the way the game does; no answer in 5 s = restart.
port="${NORAY_SOCKET_PORT:-8890}"
port="${port%%[!0-9]*}"
if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && printf 'register-host\n' >&3 && head -c 7 <&3" 2>/dev/null | grep -q set-oid; then
	exit 0
fi
echo "noray did not answer register-host on :$port, restarting"
systemctl restart noray
