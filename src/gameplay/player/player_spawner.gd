class_name PlayerSpawner
extends MultiplayerSpawner
## Host spawns one PlayerSlot per roster peer once every peer has loaded MainLevel; the engine
## replicates them (04 §4). Slot spacing keeps walkers from spawning inside each other.

signal local_player_spawned(player: CharacterBody3D)

const SLOT := preload("res://src/gameplay/player/PlayerSlot.tscn")
const SEAT_SPACING := 1.0
const NOWHERE := Vector3(INF, INF, INF)  ## get_player_position() for an unknown peer: fails any reach test


func _ready() -> void:
	spawn_function = _make_slot
	if NetManager.is_host():
		NetManager.all_peers_ready.connect(_spawn_all)


## Host-side proximity checks (03 WorldInteractions) call this.
func get_player_position(peer_id: int) -> Vector3:
	var slot := _slots().get_node_or_null(str(peer_id)) as PlayerSlot
	return slot.player_position() if slot != null else NOWHERE


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
	slot.position = Vector3(data.seat * SEAT_SPACING, 0.0, 0.0)
	slot.local_player_ready.connect(local_player_spawned.emit)
	return slot
