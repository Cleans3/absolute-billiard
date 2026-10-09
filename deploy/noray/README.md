# Noray relay (M4)

Self-hosted [foxssake/noray](https://github.com/foxssake/noray) (MIT) for the lobby code and the direct
punch, `tunnel.py` (stdlib) as the any-NAT fallback relay (06 P10), and a stdlib share-link page.
Clients only need `relay_host` in `src/resources/net_config.tres`; a fork points it at its own box.

## Ports
| Port | Proto | What | Open to the internet |
|---|---|---|---|
| 8890 | TCP | control: register / connect | yes |
| 8809 | UDP | remote-address registrar | yes |
| 49152–49251 | UDP | Noray's own relay pool (unused by this game, see Lobby flow) | yes |
| 8893 | TCP | tunnel relay control: `host CODE` / `join CODE` | yes |
| 49252–49351 | UDP | tunnel relay, 1 port per relayed joiner | yes |
| 8892 | TCP | share-link page `/j/CODE`, APK download `/` (`src/tools/publish_apk.sh`) | yes |
| 8891 | TCP | metrics (bound to 127.0.0.1) | no |

## Docker
```bash
cp .env.example .env   # OID charset/length = the 6-char Crockford lobby code; do not change
docker compose up -d
```

## Bare host without Docker (what the reference VPS runs)
Noray needs `bun`; a host with no direct outbound can be fed from a workstation. `vps/deploy.sh`
builds the bundle (bun + noray + prod `node_modules`), copies it over SSH, installs the three systemd
units in `vps/`, and opens exactly the ports above.
`RELAY_SSH="user@host -i key" ./vps/deploy.sh`

## Lobby flow
Host: TCP `register-host` → `set-oid` (= lobby code) + `set-pid`; UDP pid → registrar (`OK`); ENet server
binds the same local port, then registers the code with the tunnel relay (`host <oid>`, connection kept
open). Joiner: same Noray registration, `connect <oid>` → host address → ENet client from its registered
local port while the host punches back from ENet's own socket (`ENetConnection.socket_send`). Silent for
`direct_try_sec` → `join <oid>` on the tunnel relay → both sides get one UDP port and a token, each sends
`AB<token>` to that port, and the relay forwards everything else between the two addresses it learned.

Why not Noray's relay: it addresses a player by the ip:port its registrar saw, and a symmetric NAT (many
mobile carriers, some home ISPs) gives every destination port a different one, so a host behind such a
NAT is unreachable. The tunnel learns the address on the very port it relays on. Check it with
`python3 tunnel.py --selftest`, and end to end with
`tests/net/pair.sh tests/net/pair_probe.gd --noray --relay-only` (add `--tunnel=127.0.0.1` for a local one).
