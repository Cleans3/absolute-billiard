class_name CameraRigs
extends Node3D
## MainLevel/Cameras: the tripod rigs, the fixed ceiling camera, the pot-time Camera_Mult and rig movement (docs/plan/02 §3.2, 03 §3.7).
## Rig count and tier come from the Shop (mirrored `owned`), so every peer builds the same set; the host
## moves them and streams poses at 4 Hz only while something moves (07 §3: silent at rest).
## One tripod to start (BASE_RIGS 1, 06 P33 U5) plus the `CeilingCam`, which is not a rig: never scored, never moved, same on every peer.

const POSE_PERIOD := 0.25
const SETTLE_SENDS := 4  # unreliable: keep repeating the resting pose this many periods
const GRAB_REACH := 3.0
const POCKET_LIFT := 0.15  # aim the ray a little above the cloth so it does not start inside it
## Floor position + yaw per rig; rig 1 is the base tripod, 2–4 the spare tripods. [tune]
const SPOTS: Array = [
	[Vector3(0.0, 0.0, -6.7), PI],  # the base tripod: the north wall, broadside on the whole table (it was cam_2; the south-west spot was dropped as the base)
	[Vector3(-2.6, 0.0, -0.3), 0.0],  # ≥ 1 m from every bar prop, so a prompt never has two candidates
	[Vector3(-5.2, 0.0, -3.5), -PI / 2.0],
	[Vector3(5.2, 0.0, -3.5), PI / 2.0],
]

@export var table: Table
@export var economy: EconomyManager
@export var world: WorldInteractions
@export var round_director: Node
@export var spawner: Node  # PlayerSpawner: get_player_position(peer_id)

var rigs: Array[CameraRig] = []
var ceiling: CeilingCam  # the fixed top-down camera over the table: feeds the TV, outside `rigs` on purpose
var last_rig := &""  # the rig that won the latest score
var last_quality := 0.0

## Any rig's holder changed (host: a grab/place; client: a pose packet). The Player derives CARRY from it.
signal holders_changed

var _accum := 0.0
var _settle := 0
var _sent: PackedFloat32Array
var _sent_holders: PackedInt32Array


func _ready() -> void:
	if economy != null:
		economy.owned_changed.connect(_sync_rigs)
	if world != null:
		world.camera_move_requested.connect(_on_move_requested)
	_build_ceiling()
	_sync_rigs()
	set_physics_process(multiplayer.is_server())


## The ceiling pod above the table (CeilingCam: lens down, OFFSET_Z south of the lamp's rod). Built on every peer, never networked.
func _build_ceiling() -> void:
	ceiling = CeilingCam.new()
	ceiling.name = "CeilingCam"
	ceiling.table = table
	add_child(ceiling)
	var centre := table.global_position if table != null else Vector3.ZERO
	ceiling.global_position = Vector3(centre.x, CeilingCam.EYE_Y, centre.z + CeilingCam.OFFSET_Z)


## Camera_Mult for a pot in `pocket_id`; 1.0 when there is nothing to score.
func camera_mult(pocket_id: StringName) -> float:
	var pocket := table.get_pocket(pocket_id) if table != null and pocket_id != &"" else null
	if pocket == null or rigs.is_empty():
		return 1.0
	var target := table.to_global(pocket.position) + Vector3.UP * POCKET_LIFT
	var exclude: Array[RID] = []
	if round_director != null:
		for ball: Ball in round_director.call(&"get_balls"):
			exclude.append(ball.get_rid())
	var win := CameraScorer.best(rigs, target, get_world_3d().direct_space_state, exclude, 0xFFFFFFFF)
	last_rig = win.rig.camera_id
	last_quality = win.quality
	var fx := get_node_or_null(^"../EffectManager")
	var bonus: float = fx.get_stat(&"stream_camera_bonus_mult", EffectManager.ALL_PEERS, 1.0) if fx != null else 1.0
	return CameraScorer.camera_mult(win.rig.tier_mult(), win.quality, bonus)


## The Player's use-prop for a rig: WorldInteractions validates `move_camera` reach against an Interactable
## whose target_id is the rig number (08 §5), and the same prop drives the "Grab camera" prompt.
func _grab_prop(rig_number: int) -> Interactable:
	var prop := Interactable.new()
	prop.interaction = FxCatalog.interaction(&"move_camera")
	prop.target_id = rig_number
	prop.prompt = "Grab camera"
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = Bar.REACH_ZONE_RADIUS
	shape.shape = sphere
	prop.add_child(shape)
	return prop


func _sync_rigs() -> void:
	var count: int = economy.rig_count() if economy != null else EconomyManager.BASE_RIGS
	var tier: int = economy.camera_tier() if economy != null else 1
	while rigs.size() < count:
		var rig := CameraRig.new()
		var i := rigs.size()
		rig.camera_id = StringName("cam_%d" % (i + 1))
		rig.position = SPOTS[i][0]
		rig.rotation.y = SPOTS[i][1]
		add_child(rig)
		rig.add_child(_grab_prop(i + 1))
		rigs.append(rig)
	for rig in rigs:
		rig.tier = tier
	_settle = SETTLE_SENDS  # a resume/purchase: let clients see the full set


# --- movement (host) ---------------------------------------------------------------------------

## target_id = rig number (1-based), 0 = the nearest rig; payload `place_at: Vector3` puts it down there.
func _on_move_requested(peer_id: int, target_id: int, payload: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var pos := _player_pos(peer_id)
	var rig := rigs[target_id - 1] if target_id >= 1 and target_id <= rigs.size() else _nearest(pos)
	if rig == null:
		return
	if rig.held_by == peer_id:
		rig.held_by = 0
		if payload.has(&"place_at"):
			rig.global_position = payload[&"place_at"]
	elif rig.held_by == 0 and (not pos.is_finite() or pos.distance_to(rig.global_position) <= GRAB_REACH):
		for other in rigs:
			if other.held_by == peer_id:
				other.held_by = 0  # one rig per pair of hands
		rig.held_by = peer_id
	_settle = SETTLE_SENDS
	holders_changed.emit()


func _nearest(pos: Vector3) -> CameraRig:
	var best: CameraRig
	var best_d := GRAB_REACH
	for rig in rigs:
		var d := pos.distance_to(rig.global_position) if pos.is_finite() else 0.0
		if d <= best_d:
			best = rig
			best_d = d
	return best


func _player_pos(peer_id: int) -> Vector3:
	return spawner.call(&"get_player_position", peer_id) if spawner != null else Vector3.INF


func _physics_process(delta: float) -> void:
	var centre := table.global_position if table != null else Vector3.ZERO
	for rig in rigs:
		if rig.held_by != 0:
			var p := _player_pos(rig.held_by)
			if p.is_finite():
				rig.global_position = Vector3(p.x, 0.0, p.z)
			rig.aim_at(centre)
	_accum += delta
	if _accum < POSE_PERIOD:
		return
	_accum = 0.0
	var poses := _poses()
	var holders := _holders()
	if poses != _sent or holders != _sent_holders:
		_sent = poses
		_sent_holders = holders
		_settle = SETTLE_SENDS
	if _settle > 0:
		_settle -= 1
		push_rig_poses.rpc(poses, holders)


func _poses() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for rig in rigs:
		out.append_array([rig.position.x, rig.position.y, rig.position.z, rig.rotation.y])
	return out


func _holders() -> PackedInt32Array:
	var out := PackedInt32Array()
	for rig in rigs:
		out.append(rig.held_by)
	return out


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func push_rig_poses(poses: PackedFloat32Array, holders: PackedInt32Array) -> void:
	var moved := false
	for i in mini(rigs.size(), poses.size() / 4):
		rigs[i].position = Vector3(poses[i * 4], poses[i * 4 + 1], poses[i * 4 + 2])
		rigs[i].rotation.y = poses[i * 4 + 3]
	for i in mini(rigs.size(), holders.size()):
		if rigs[i].held_by != holders[i]:
			rigs[i].held_by = holders[i]
			moved = true
	if moved:
		holders_changed.emit()
