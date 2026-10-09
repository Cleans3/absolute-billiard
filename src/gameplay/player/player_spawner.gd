class_name PlayerSpawner
extends MultiplayerSpawner
## Host spawns one PlayerSlot per roster peer once every peer has loaded MainLevel; the engine
## replicates them (04 §4). Slot spacing keeps walkers from spawning inside each other.

signal local_player_spawned(player: CharacterBody3D)

const SLOT := preload("res://src/gameplay/player/PlayerSlot.tscn")
const SEAT_SPACING := 1.0
const SPAWN_ROW := Vector3(-1.5, 0.0, 1.2)  ## seat 0's spot: open floor between the table and the tables, clear of kick_stool at the origin
const NOWHERE := Vector3(INF, INF, INF)  ## get_player_position() for an unknown peer: fails any reach test
const KNOCK_SEC := 2.0
const SHOVE_MPS := 3.5         ## [tune] horizontal speed of a thrown drink's knock
const BLAST_MPS := 4.5         ## [tune] ... of a bomb ball's
const BLAST_RADIUS_M := 2.5
const HOP_MPS := 1.5
const STUMBLE_STAT := &"player_stumble_per_min"  ## econ's Mystery debuff; read per peer, 1 Hz tick


var _stumble_clock := 0.0


func _ready() -> void:
	add_to_group(&"player_spawner")
	spawn_function = _make_slot
	set_process(NetManager.is_host())
	if NetManager.is_host():
		NetManager.all_peers_ready.connect(_spawn_all)


## Host: a Player Effect with `player_stumble_per_min` trips each peer at that rate (Poisson, ticked at 1 Hz).
func _process(delta: float) -> void:
	_stumble_clock += delta
	if _stumble_clock < 1.0:
		return
	var dt := _stumble_clock
	_stumble_clock = 0.0
	var fx := get_node_or_null(^"../EffectManager") as EffectManager
	if fx == null:
		return
	for slot in _slots().get_children():
		var peer := (slot as PlayerSlot).peer_id
		var per_min := fx.get_stat(STUMBLE_STAT, peer, 0.0)
		if per_min > 0.0 and randf() < 1.0 - exp(-per_min / 60.0 * dt):
			var a := randf() * TAU
			knock(peer, Vector3(cos(a) * 2.5, HOP_MPS, sin(a) * 2.5))


## Host entry (06 P15): every peer, this one included, ragdolls `peer_id`'s Player; `impulse` is a velocity change in m/s.
func knock(peer_id: int, impulse: Vector3, seconds := KNOCK_SEC) -> void:
	if NetManager.is_host():
		apply_knock.rpc(peer_id, impulse, seconds)


@rpc("authority", "call_local", "reliable", 3)
func apply_knock(peer_id: int, impulse: Vector3, seconds: float) -> void:
	var slot := _slots().get_node_or_null(str(peer_id)) as PlayerSlot
	if slot != null:
		slot.player.knock(impulse, seconds)


## Shove `peer_id` away from `from` (a thrower, a blast): a flat push plus a hop.
func knock_away(peer_id: int, from: Vector3, speed := SHOVE_MPS) -> void:
	var at := get_player_position(peer_id)
	if not at.is_finite():
		return
	var d := Vector3(at.x - from.x, 0.0, at.z - from.z) if from.is_finite() else Vector3.ZERO
	d = d.normalized() if d.length() > 0.01 else Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
	knock(peer_id, d * speed + Vector3.UP * HOP_MPS)


## Everyone within BLAST_RADIUS_M (flat) of `origin` goes down.
func knock_blast(origin: Vector3) -> void:
	for slot in _slots().get_children():
		var peer := (slot as PlayerSlot).peer_id
		var at := get_player_position(peer)
		if at.is_finite() and Vector2(at.x - origin.x, at.z - origin.z).length() <= BLAST_RADIUS_M:
			knock_away(peer, origin, BLAST_MPS)


## Host-side proximity checks (03 WorldInteractions) call this.
func get_player_position(peer_id: int) -> Vector3:
	var slot := _slots().get_node_or_null(str(peer_id)) as PlayerSlot
	return slot.player_position() if slot != null else NOWHERE


func get_player(peer_id: int) -> Player:
	var slot := _slots().get_node_or_null(str(peer_id)) as PlayerSlot
	return slot.player if slot != null else null


func get_local_player() -> CharacterBody3D:
	for s in _slots().get_children():
		if (s as PlayerSlot).is_local():
			return (s as PlayerSlot).player
	return null


func _slots() -> Node:
	return get_node(spawn_path)


func _spawn_all() -> void:
	for e in NetManager.get_roster():
		spawn({peer_id = e.peer_id, seat = e.seat})


func _make_slot(data: Dictionary) -> Node:
	var slot: PlayerSlot = SLOT.instantiate()
	slot.peer_id = data.peer_id
	slot.position = SPAWN_ROW + Vector3(data.seat * SEAT_SPACING, 0.0, 0.0)
	slot.local_player_ready.connect(local_player_spawned.emit)
	return slot
