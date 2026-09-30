#!/usr/bin/env bash
# Run ON the relay box as root. Default-deny inbound, open ssh + the relay ports only.
# A 3-minute self-destruct timer disables ufw again unless you cancel it, so a bad rule cannot lock you out:
#   after this prints, open a NEW ssh session, then run: systemctl stop ufw-rollback.timer
set -euo pipefail
ufw allow 22/tcp
ufw allow 8890/tcp; ufw allow 8892/tcp; ufw allow 8893/tcp; ufw allow 8809/udp; ufw allow 49152:49351/udp
systemd-run --unit=ufw-rollback --on-active=180 ufw disable
ufw default deny incoming; ufw default allow outgoing
ufw --force enable
ufw status verbose
