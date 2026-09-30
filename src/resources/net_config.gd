class_name NetConfig
extends Resource
## Network settings (docs/plan/04 §2.3). A fork points at its own relay by editing net_config.tres.

@export var relay_host := "160.191.243.188"
@export var relay_tcp_port := 8890  ## Noray control (TCP)
@export var relay_udp_port := 8809  ## Noray NAT registrar (UDP)
@export var direct_port := 7777
@export var max_players := 4
## Where the share-link landing page lives: `<share_base_url>/j/<CODE>`.
@export var share_base_url := "http://160.191.243.188:8891"
@export var timeout_sec := 10.0
@export var channel_count := 8
## How long a joiner tries the punched direct path before falling back to the relay.
@export var direct_try_sec := 3.0
