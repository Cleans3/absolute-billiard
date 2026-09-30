#!/usr/bin/env bash
# Run ON the relay box as root. Default-deny inbound, open ssh + the relay ports only. Idempotent.
# A 3-minute self-destruct timer disables ufw again unless you cancel it, so a bad rule cannot lock you out:
#   after this prints, open a NEW ssh session, then run: systemctl stop ufw-rollback.timer
set -euo pipefail
# Start from "off": with ENABLED=yes in ufw.conf but no chains loaded (ufw.service disabled, box rebooted),
# every new `ufw allow` dies with "ERROR: problem running" while it flushes chains that are not there.
ufw disable
ufw allow 22/tcp
ufw allow 8890/tcp; ufw allow 8892/tcp; ufw allow 8893/tcp; ufw allow 8809/udp; ufw allow 49152:49351/udp
systemctl stop ufw-rollback.timer 2>/dev/null || true
systemd-run --unit=ufw-rollback --on-active=180 ufw disable
ufw default deny incoming; ufw default allow outgoing
ufw --force enable
systemctl enable ufw  # `ufw enable` only edits ufw.conf; without the unit the rules are gone after a reboot
ufw status verbose
