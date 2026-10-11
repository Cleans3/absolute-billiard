class_name NetConfig
extends Resource
## Network settings (docs/plan/04 §2.3). A fork points at its own relay by editing net_config.tres.

@export var relay_host := "160.191.243.191"
@export var relay_tcp_port := 8890  ## Noray control (TCP)
@export var relay_udp_port := 8809  ## Noray NAT registrar (UDP)
@export var tunnel_host := ""  ## tunnel relay (06 P10); empty = relay_host
@export var tunnel_tcp_port := 8893  ## tunnel control (TCP); its UDP ports come back in the answer
@export var direct_port := 7777
@export var max_players := 4
## Where the share-link landing page lives: `<share_base_url>/j/<CODE>`.
@export var share_base_url := "http://160.191.243.191:8892"  ## join_page.py port (8891 = Noray metrics, localhost only)
@export var timeout_sec := 10.0
@export var channel_count := 8
## How long a joiner tries the punched direct path before falling back to the relay.
@export var direct_try_sec := 3.0
## ENet peer timeouts (04 §6): a phone that backgrounds for up to ~30 s must not be dropped. ENet only
## disconnects after `timeout_min_ms` without an ack (and never waits past `timeout_max_ms`).
@export var peer_timeout_limit := 32
@export var peer_timeout_min_ms := 45000
@export var peer_timeout_max_ms := 60000
## ENet packet throttle (04 §6). ENet drops unreliable packets at the sender in proportion to a throttle that closes when a
## reliable round trip runs long and reopens slowly. Two things walked it to ~0 on every link: a server host at "unlimited"
## bandwidth (0) made ENet clamp every client's throttle to 1-4 of 32 in its first 1 s pass, and RTT jitter (two frame loops
## quantise every RTT) closed it further. The 10 Hz pose stream, a few bytes a second, then stopped for seconds and a puppet
## kept its last mode. So the server gets a bandwidth cap no link reaches, and the throttle never closes: deceleration 0,
## acceleration at ENetPacketPeer.PACKET_THROTTLE_SCALE so it reopens at once if it ever is below.
@export var bandwidth_bytes_per_sec := 100000000
@export var throttle_interval_ms := 5000
@export var throttle_acceleration := 32
@export var throttle_deceleration := 0
