class_name Footprints
extends Node3D
## MainLevel/Footprints (docs/plan/08 §2.9 step 4, 06 P57): muddy prints where anyone walks on the table, and the towel that wipes them.
## A picture only: the prints never touch a ball. Every peer stamps them itself from the bodies it draws (the pose stream's positions),
## into one dirt image over the cloth; a wipe is a bare world interaction (`towel_wipe`), so a wiped patch is clean on every peer. One
## towel hangs at the table's north-east corner (`take_towel`: take it / hang it back).

signal changed

const TAKE := &"take_towel"
const WIPE := &"towel_wipe"
const KINDS: Array[StringName] = [TAKE, WIPE]
const IMG := Vector2i(512, 256)   ## the dirt image over the cloth (~1 cm a pixel on the 2x table)
const STEP_M := 0.32              ## a print every this far walked on the table
const FOOT := Vector2(0.045, 0.11) ## half-width, half-length of a print
const FOOT_SIDE := 0.1            ## left and right of the walking line
const ON_LID_SLACK := 0.25        ## how far over the lid a body may be and still count as standing on it
const DIRT := Color(0.24, 0.16, 0.08)
const DIRT_ALPHA := 0.6
const WIPE_R := 0.4
const WIPE_LEFT := 0.15           ## what a wipe leaves of the dirt under it
const WIPE_COOLDOWN_MSEC := 350
const WIPE_AHEAD := 0.55          ## the wipe lands this far ahead of the wiper's feet
const EDGE_REACH := 1.4           ## a wiper this far from the cloth's edge, or on it, reaches it
const UPLOAD_MSEC := 100
const TOWEL_HAND := Vector3(-0.24, 1.0, -0.3)
const TOWEL_SIZE := Vector3(0.28, 0.02, 0.22)
const HOOK_PROP := Vector3(0.35, 0.0, -0.25)  ## the towel's Interactable on the floor, from the table's north-east corner (table space)
const WIPE_SEC := 0.35

@export var world: WorldInteractions
@export var table: Table

var towel_holder := 0  ## peer holding the towel, 0 = on its hook

var _img: Image
var _tex: ImageTexture
var _quad: MeshInstance3D
var _dirty := false
var _uploaded_at := 0
var _last := {}       # peer -> {pos: Vector2 (table-local xz), left: bool}
var _cool := {}       # host: peer -> msec
var _wipes := {}      # peer -> msec, the hand's swipe
var _towel: MeshInstance3D
var _prop: Interactable
var _hand_on := {}
var _spawner: Node


func _ready() -> void:
	add_to_group(&"footprints")
	_img = Image.create(IMG.x, IMG.y, false, Image.FORMAT_RGBA8)
	_img.fill(Color(DIRT, 0.0))
	_tex = ImageTexture.create_from_image(_img)
	if table != null:
		_build()
	if world != null:
		world.interaction_applied.connect(_on_applied)
	var rd := get_node_or_null(^"../RoundDirector")
	if rd != null:
		rd.connect(&"rack_ready", func(_s: int) -> void: clear_all())
	multiplayer.peer_disconnected.connect(_on_peer_left)


# --- state ----------------------------------------------------------------------------------------------------------------------

func holds_towel(peer_id: int) -> bool:
	return towel_holder != 0 and towel_holder == peer_id


## How dirty the cloth is: the share of its pixels with any print on them (probes).
func dirt_fraction() -> float:
	var n := 0
	for y in range(0, IMG.y, 4):
		for x in range(0, IMG.x, 4):
			if _img.get_pixel(x, y).a > 0.05:
				n += 1
	return float(n) / float((IMG.x / 4) * (IMG.y / 4))


## The dirt at a table-local cloth point, 0..1 (probes).
func dirt_at(local_xz: Vector2) -> float:
	var px := _px(local_xz)
	return _img.get_pixelv(px).a / DIRT_ALPHA if Rect2i(Vector2i.ZERO, IMG).has_point(px) else 0.0


func clear_all() -> void:
	_img.fill(Color(DIRT, 0.0))
	_last.clear()
	_dirty = true


func request_wipe(at: Vector3) -> void:
	if world != null:
		world.request(WIPE, 0, {&"at": at})


## Host: one peer back from the background learns who holds the towel (the prints are every peer's own picture).
func resync_peer(peer_id: int) -> void:
	if towel_holder != 0:
		world.world_interaction_applied.rpc_id(peer_id, towel_holder, TAKE, 0, {&"op": &"take"})


# --- host ---------------------------------------------------------------------------------------------------------------------

func validate_kind(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> StringName:
	match kind:
		TAKE:
			var near := world._reach(peer_id, TAKE, target_id)
			if near != &"":
				return near
			if towel_holder == peer_id:
				return &""
			if towel_holder != 0:
				return &"has_towel"
			var grab := get_tree().get_first_node_in_group(&"ball_grab") as BallGrab
			return &"hands_full" if grab != null and grab.holds(peer_id) else &""
		WIPE:
			if not holds_towel(peer_id):
				return &"no_towel"
			if int(_cool.get(peer_id, 0)) > Time.get_ticks_msec():
				return &"cooldown"
			var pos: Vector3 = world.player_position_source.call(peer_id)
			if not pos.is_finite():
				return &"no_position"
			var l := table.to_local(pos)
			var hl := table.spec.length_m * 0.5
			var hw := table.spec.width_m * 0.5
			var off := Vector2(maxf(absf(l.x) - hl, 0.0), maxf(absf(l.z) - hw, 0.0)).length()
			if off > EDGE_REACH:
				return &"not_at_table"
			var at: Variant = payload.get(&"at", null)
			return &"" if at is Vector3 and (at as Vector3).is_finite() else &"bad_payload"
	return &"unknown_kind"


func fill_kind(peer_id: int, kind: StringName, _target_id: int, payload: Dictionary) -> void:
	match kind:
		TAKE:
			payload[&"op"] = &"put" if towel_holder == peer_id else &"take"
		WIPE:
			_cool[peer_id] = Time.get_ticks_msec() + WIPE_COOLDOWN_MSEC
			var l := table.to_local(payload[&"at"] as Vector3)
			var hl := table.spec.length_m * 0.5
			var hw := table.spec.width_m * 0.5
			payload[&"at"] = table.to_global(Vector3(clampf(l.x, -hl, hl), table.spec.bed_height_m, clampf(l.z, -hw, hw)))


func _on_peer_left(peer_id: int) -> void:
	if multiplayer.is_server() and towel_holder == peer_id:
		world.world_interaction_applied.rpc(peer_id, TAKE, 0, {&"op": &"put"})


# --- every peer ---------------------------------------------------------------------------------------------------------------

func _on_applied(peer_id: int, kind: StringName, _target: int, payload: Dictionary) -> void:
	match kind:
		TAKE:
			if payload.get(&"op", &"") == &"take":
				towel_holder = peer_id
			elif towel_holder == peer_id:
				_drop_hand(peer_id)
				towel_holder = 0
			_refresh_towel()
		WIPE:
			var at := table.to_local(payload.get(&"at", Vector3.ZERO) as Vector3)
			_wipe(Vector2(at.x, at.z))
			_wipes[peer_id] = Time.get_ticks_msec()
			_sound(&"lean", payload.get(&"at", Vector3.ZERO), -10.0, 1.4)
		_:
			return
	changed.emit()


func _build() -> void:
	var spec := table.spec
	_quad = MeshInstance3D.new()
	_quad.name = "Dirt"
	var plane := PlaneMesh.new()
	plane.size = Vector2(spec.length_m, spec.width_m)
	_quad.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _tex
	mat.roughness = 1.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_quad.material_override = mat
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)
	_quad.global_transform = table.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, spec.bed_height_m + 0.0015, 0.0))
	var corner := Vector3(spec.length_m * 0.5 + spec.rail_width_m * 0.5, spec.bed_height_m + spec.rail_height_m + TOWEL_SIZE.y * 0.5, -(spec.width_m * 0.5 + spec.rail_width_m * 0.5))
	_towel = MeshInstance3D.new()
	_towel.name = "Towel"
	var box := BoxMesh.new()
	box.size = TOWEL_SIZE
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.92, 0.9, 0.82)
	cloth.roughness = 1.0
	box.material = cloth
	_towel.mesh = box
	_towel.layers = 1 | Humanoid.MIRROR_LAYER
	_towel.top_level = true
	add_child(_towel)
	_towel.set_meta(&"home", table.to_global(corner))
	_prop = Interactable.new()
	_prop.name = "Prop"
	_prop.kind = TAKE
	_prop.prompt = "Take the towel"
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = Bar.REACH_ZONE_RADIUS
	shape.shape = sphere
	_prop.add_child(shape)
	add_child(_prop)
	var home_floor := table.to_global(Vector3(corner.x, 0.0, corner.z) + HOOK_PROP)
	_prop.global_position = Vector3(home_floor.x, 0.0, home_floor.z)
	_refresh_towel()
	set_process(true)


func _refresh_towel() -> void:
	if _towel == null:
		return
	if towel_holder == 0:
		_towel.global_transform = Transform3D(Basis.IDENTITY, _towel.get_meta(&"home"))
	var me := multiplayer.get_unique_id()
	_prop.prompt = "Hang the towel back" if towel_holder == me else ("Take the towel" if towel_holder == 0 else "Someone has the towel")


# --- every frame: stamps, the towel in the hand, the upload ------------------------------------------------------------------

func _process(_delta: float) -> void:
	if table == null:
		return
	var spec := table.spec
	var lid := spec.bed_height_m + spec.rail_height_m
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	for n in get_tree().get_nodes_in_group(&"players"):
		var p := n as Player
		if p == null or p.mode == Player.Mode.RAGDOLL:
			continue
		var l := table.to_local(p.global_position)
		var peer := _peer_of(p)
		var on := absf(l.x) <= hl and absf(l.z) <= hw and l.y > lid - 0.05 and l.y < lid + ON_LID_SLACK
		if not on:
			_last.erase(peer)
			continue
		var here := Vector2(l.x, l.z)
		var last: Dictionary = _last.get(peer, {})
		if last.is_empty():
			_last[peer] = {pos = here, left = false}
			continue
		var walked := here - (last.pos as Vector2)
		if walked.length() < STEP_M:
			continue
		var dir := walked.normalized()
		var left: bool = not last.left
		var side := Vector2(-dir.y, dir.x) * (FOOT_SIDE if left else -FOOT_SIDE)
		_stamp(here + side, dir)
		_last[peer] = {pos = here, left = left}
	if towel_holder != 0:
		var h := _player(towel_holder)
		if h != null:
			var t := (Time.get_ticks_msec() - int(_wipes.get(towel_holder, -100000))) / 1000.0
			var swipe := Vector3(sin(t * 30.0) * 0.18, -0.2, -0.15) if t < WIPE_SEC else Vector3.ZERO
			if h.mode != Player.Mode.RAGDOLL:
				h.humanoid.set_hand(1, TOWEL_HAND + swipe)
				_hand_on[towel_holder] = true
			_towel.global_transform = Transform3D(h.global_basis.orthonormalized(), h.humanoid.hand_world(1))
	if _dirty and Time.get_ticks_msec() - _uploaded_at >= UPLOAD_MSEC:
		_tex.update(_img)
		_dirty = false
		_uploaded_at = Time.get_ticks_msec()


## One print at table-local `at`, its toe along `dir`.
func _stamp(at: Vector2, dir: Vector2) -> void:
	var c := _px(at)
	var ppm := Vector2(IMG.x / table.spec.length_m, IMG.y / table.spec.width_m)
	var reach := int(ceil(FOOT.y * maxf(ppm.x, ppm.y))) + 1
	var side := Vector2(-dir.y, dir.x)
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var p := c + Vector2i(dx, dy)
			if not Rect2i(Vector2i.ZERO, IMG).has_point(p):
				continue
			var m := Vector2(dx / ppm.x, dy / ppm.y)  # metres from the print's centre
			var along := m.dot(dir)
			var across := m.dot(side) / (FOOT.x * (0.75 if along < -FOOT.y * 0.35 else 1.0))  # a narrower heel
			var k := across * across + (along / FOOT.y) * (along / FOOT.y)
			if k > 1.0:
				continue
			var a := DIRT_ALPHA * (1.0 - k * k) * (0.75 + 0.25 * sin(float(p.x * 13 + p.y * 7)))
			var old := _img.get_pixelv(p)
			_img.set_pixelv(p, Color(DIRT, maxf(old.a, a)))
	_dirty = true


func _wipe(at: Vector2) -> void:
	var c := _px(at)
	var ppm := Vector2(IMG.x / table.spec.length_m, IMG.y / table.spec.width_m)
	var rx := int(ceil(WIPE_R * ppm.x))
	var ry := int(ceil(WIPE_R * ppm.y))
	for dy in range(-ry, ry + 1):
		for dx in range(-rx, rx + 1):
			var p := c + Vector2i(dx, dy)
			if not Rect2i(Vector2i.ZERO, IMG).has_point(p):
				continue
			var d := Vector2(dx / ppm.x, dy / ppm.y).length() / WIPE_R
			if d > 1.0:
				continue
			var old := _img.get_pixelv(p)
			_img.set_pixelv(p, Color(DIRT, old.a * lerpf(WIPE_LEFT, 1.0, d * d)))
	_dirty = true


func _px(local_xz: Vector2) -> Vector2i:
	var spec := table.spec
	return Vector2i(int((local_xz.x / spec.length_m + 0.5) * IMG.x), int((local_xz.y / spec.width_m + 0.5) * IMG.y))


func _drop_hand(peer: int) -> void:
	if not _hand_on.has(peer):
		return
	_hand_on.erase(peer)
	var p := _player(peer)
	if p != null:
		p.humanoid.clear_hand(1)


func _player(peer: int) -> Player:
	if _spawner == null:
		_spawner = get_tree().get_first_node_in_group(&"player_spawner")
	return _spawner.call(&"get_player", peer) as Player if _spawner != null else null


static func _peer_of(p: Player) -> int:
	var slot := p.get_parent() as PlayerSlot if p != null else null
	return slot.peer_id if slot != null else 0


func _sound(sound: StringName, at: Vector3, db: float, pitch: float) -> void:
	var sfx := get_node_or_null(^"/root/Sfx")
	if sfx != null:
		sfx.call(&"play_at", sound, at, db, pitch)
