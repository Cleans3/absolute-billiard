# Noray relay (M4)

Self-hosted [foxssake/noray](https://github.com/foxssake/noray) (MIT) + a stdlib share-link page.
Clients only need `relay_host` in `src/resources/net_config.tres`; a fork points it at its own box.

## Ports
| Port | Proto | What | Open to the internet |
|---|---|---|---|
| 8890 | TCP | control: register / connect | yes |
| 8809 | UDP | remote-address registrar | yes |
| 49152–49251 | UDP | relay pool (2 per relayed player) | yes |
| 8892 | TCP | share-link page `/j/CODE` | yes |
| 8891 | TCP | metrics (bound to 127.0.0.1) | no |

## Docker
```bash
cp .env.example .env   # OID charset/length = the 6-char Crockford lobby code; do not change
docker compose up -d
```

## Bare host without Docker (what the reference VPS runs)
Noray needs `bun`; a host with no direct outbound can be fed from a workstation. `vps/deploy.sh`
builds the bundle (bun + noray + prod `node_modules`), copies it over SSH, installs the two systemd
units in `vps/`, and opens exactly the ports above.
`RELAY_SSH="user@host -i key" ./vps/deploy.sh`

## Lobby flow
Host: TCP `register-host` → `set-oid` (= lobby code) + `set-pid`; UDP pid → registrar (`OK`); ENet server
binds the same local port. Joiner: same registration, `connect <oid>` → host address → ENet client from
its registered local port (direct); silent for `direct_try_sec` → `connect-relay <oid>` → ENet client to the
relay port. The host never punches outward (Godot's ENet cannot share its socket), so an unforwarded
port-restricted NAT on the host side lands on the relay — measure that rate (04 §6).
