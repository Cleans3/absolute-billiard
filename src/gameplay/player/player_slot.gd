class_name PlayerSlot
extends Node3D
## One per roster peer (04 §4). Authority = its peer. Hosts the Player walker as child `Player`; the
## authority streams its pose at 10 Hz, everyone else renders the walker as a dumb puppet.

signal local_player_ready(player: CharacterBody3D)

const PLAYER := preload("res://src/gameplay/player/Player.tscn")
const POSE_HZ := 10.0
const POSE_BYTES := Player.POSE_BYTES

var peer_id := 0
var player: Player

var _accum := 0.0
var _net: Node  ## NetManager, by path: a `-s` probe compiles this script before the autoloads exist


func _ready() -> void:
	name = str(peer_id)
	_net = get_tree().root.get_node(^"NetManager")
	set_multiplayer_authority(peer_id)
	player = PLAYER.instantiate()
	player.name = "Player"
	add_child(player)
	if is_local():
		local_player_ready.emit(player)
	else:
		# Puppet (08 §2.6): avatar only, driven by the pose stream, no input, cue or camera.
		set_process(false)
		var who := _roster_entry()
		player.make_puppet(str(who.get("name", "P%d" % peer_id)), Player.SEAT_COLOURS[int(who.get("seat", 0)) % Player.SEAT_COLOURS.size()])


func is_local() -> bool:
	return is_multiplayer_authority()


func _process(delta: float) -> void:
	if _net.backgrounded:  # a paused phone sends nothing (04 §6)
		return
	_accum += delta
	if _accum >= 1.0 / POSE_HZ:
		_accum = 0.0
		push_player_pose.rpc(player.pack_pose())


## Layout and interpolation live in Player (`pack_pose` / `apply_pose`, 08 §5). Trusted (friends-only, 04 §6).
@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func push_player_pose(blob: PackedByteArray) -> void:
	if blob.size() != POSE_BYTES or multiplayer.get_remote_sender_id() != peer_id:
		return
	player.apply_pose(blob)


## Where this slot's walker is right now (the puppet's rendered position on remote peers).
func player_position() -> Vector3:
	return player.global_position


func _roster_entry() -> Dictionary:
	# looked up by path: a `-s` probe compiles this script before the autoloads exist
	for e: Dictionary in get_tree().root.get_node(^"NetManager").call(&"get_roster"):
		if e.peer_id == peer_id:
			return e
	return {}
