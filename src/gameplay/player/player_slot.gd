class_name PlayerSlot
extends Node3D
## One per roster peer (04 §4). Authority = its peer. Hosts the Player walker as child `Player`; the
## authority streams its pose at 10 Hz, everyone else renders the walker as a dumb puppet.

signal local_player_ready(player: CharacterBody3D)

const PLAYER := preload("res://src/gameplay/player/Player.tscn")
const POSE_HZ := 10.0
const POSE_BYTES := 16
const SMOOTH := 12.0  ## puppet catch-up rate, 1/s

var peer_id := 0
var player: CharacterBody3D

var _head: Node3D
var _accum := 0.0
var _pose := PackedByteArray()
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0
var _has_pose := false


func _ready() -> void:
	name = str(peer_id)
	set_multiplayer_authority(peer_id)
	player = PLAYER.instantiate()
	player.name = "Player"
	add_child(player)
	_head = player.get_node("Head")
	_pose.resize(POSE_BYTES)
	if is_local():
		local_player_ready.emit(player)
	else:
		# Puppet: no input, no cue, no camera — only the body mesh follows the pose stream.
		player.process_mode = Node.PROCESS_MODE_DISABLED
		_head.get_node("CueController").queue_free()
		_head.get_node("headCam").queue_free()
		set_process(true)


func is_local() -> bool:
	return is_multiplayer_authority()


func _process(delta: float) -> void:
	if is_local():
		_accum += delta
		if _accum >= 1.0 / POSE_HZ:
			_accum = 0.0
			push_player_pose.rpc(_encode())
	elif _has_pose:
		var k := 1.0 - exp(-SMOOTH * delta)
		player.global_position = player.global_position.lerp(_target_pos, k)
		player.rotation.y = lerp_angle(player.rotation.y, _target_yaw, k)
		_head.rotation.x = lerpf(_head.rotation.x, _target_pitch, k)


## pos 3×f32 | yaw u16 (0..2π) | pitch s16 (±π/2) = 16 B. Trusted (friends-only, 04 §6).
@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func push_player_pose(blob: PackedByteArray) -> void:
	if blob.size() != POSE_BYTES or multiplayer.get_remote_sender_id() != peer_id:
		return
	_target_pos = Vector3(blob.decode_float(0), blob.decode_float(4), blob.decode_float(8))
	_target_yaw = blob.decode_u16(12) * TAU / 65536.0
	_target_pitch = blob.decode_s16(14) * (PI / 2.0) / 32767.0
	if not _has_pose:
		player.global_position = _target_pos
		_has_pose = true


func _encode() -> PackedByteArray:
	var p := player.global_position
	_pose.encode_float(0, p.x)
	_pose.encode_float(4, p.y)
	_pose.encode_float(8, p.z)
	_pose.encode_u16(12, int(wrapf(player.rotation.y, 0.0, TAU) / TAU * 65535.0))
	_pose.encode_s16(14, int(clampf(_head.rotation.x / (PI / 2.0), -1.0, 1.0) * 32767.0))
	return _pose


## Where this slot's walker is right now (the puppet's rendered position on remote peers).
func player_position() -> Vector3:
	return player.global_position
