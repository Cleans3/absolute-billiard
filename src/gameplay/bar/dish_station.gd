class_name DishStation
extends Node3D
## MainLevel/DishStation (docs/plan/08 §2.9 step 3, 06 P57): the sink on the north wall left of the door where a player who bought a cue on credit
## washes the debt off. A credit buy (`cue_buy` with `credit` in its payload) shocks the buyer, who is then put at the sink; every
## washed plate (`wash_dish`, a bare world interaction) takes a share of the cue's price off their debt. Nobody in debt shoots, and a
## Night that ends with a debt left is lost (GameLoop._reckon). Like the rack: the host decides into the payload, every peer applies
## the broadcast, the whole state goes out at a campaign start / resume and to a peer back from the background (`_dish_state_rpc`).

signal changed

const KIND := &"wash_dish"
const WASHES_PER_CUE := 10       ## plates a cue's price takes to wash off [tune]
const WASH_SEC := 0.9            ## one plate: the scrub, and the host's cooldown
const SHOCK_SEC := 1.2           ## the debtor is limp this long
const SHOCK_HOP := Vector3(0.0, 2.6, 0.0)
const SHOCK_COLOR := Color(0.35, 0.9, 1.0)
const CABINET := Vector3(0.9, 0.9, 0.6)  ## w, h, depth from the wall
const PROP_AT := Vector3(0.3, 0.0, 0.95)  ## the Interactable on the floor in front (local; +z faces the room)
const STAND_AT := Vector3(0.0, 0.0, 1.05) ## where a dragged debtor is put, facing the sink
const PLATES_SHOWN := 10
const PLATE_R := 0.11
const PLATE_H := 0.018

@export var world: WorldInteractions

var debts := {}  ## peer id -> $ owed

var _cool := {}           # host: peer -> msec
var _scrubs := {}         # peer -> local msec the scrub started
var _washed := 0          # plates on the clean stack (a picture)
var _drag_at := -1        # local msec after which the local debtor is put at the sink (once standing); -1 = none
var _dirty: Array[MeshInstance3D] = []
var _clean: Array[MeshInstance3D] = []
var _prop: Interactable
var _spawner: Node
var _zaps: Array[Dictionary] = []  # {label, until}


func _ready() -> void:
	add_to_group(&"dish_station")
	_build()
	if world != null:
		world.interaction_applied.connect(_on_applied)
	multiplayer.peer_disconnected.connect(_on_peer_left)
	_refresh()


# --- state ----------------------------------------------------------------------------------------------------------------------

func owes(peer_id: int) -> bool:
	return debt_of(peer_id) > 0


func debt_of(peer_id: int) -> int:
	return int(debts.get(peer_id, 0))


func total_debt() -> int:
	var t := 0
	for v: int in debts.values():
		t += maxi(v, 0)
	return t


## What one plate takes off a debt: a tenth of tonight's cue price, rounded up.
func pay_per_plate() -> int:
	var rack := get_tree().get_first_node_in_group(&"cue_rack") as CueRack
	var price := rack.price() if rack != null else 2 * EconomyManager.FINE_MIN
	return maxi(1, ceili(float(price) / WASHES_PER_CUE))


## Host: a campaign starts (no debt) or resumes (its saved `cue_debt`, owed by the host's seat). Every peer is told.
func reset_campaign(host_debt := 0) -> void:
	if not multiplayer.is_server():
		return
	debts.clear()
	if host_debt > 0:
		debts[multiplayer.get_unique_id()] = host_debt
	_washed = 0
	_refresh()
	if not multiplayer.get_peers().is_empty():
		_push_state()


func resync_peer(peer_id: int) -> void:
	_dish_state_rpc.rpc_id(peer_id, PackedInt32Array(debts.keys()), PackedInt32Array(debts.values()))


func _push_state() -> void:
	_dish_state_rpc.rpc(PackedInt32Array(debts.keys()), PackedInt32Array(debts.values()))


@rpc("authority", "call_remote", "reliable", 3)
func _dish_state_rpc(peers: PackedInt32Array, amounts: PackedInt32Array) -> void:
	if peers.size() != amounts.size():
		return
	debts.clear()
	for i in peers.size():
		if amounts[i] > 0:
			debts[peers[i]] = amounts[i]
	_refresh()


## Host: a leaver's debt stays with the crew, on the host's seat.
func _on_peer_left(peer_id: int) -> void:
	if not multiplayer.is_server() or not owes(peer_id):
		return
	var me := multiplayer.get_unique_id()
	debts[me] = debt_of(me) + debt_of(peer_id)
	debts.erase(peer_id)
	_refresh()
	_push_state()


# --- host: validate and decide --------------------------------------------------------------------------------------------------

func validate(peer_id: int, _payload: Dictionary) -> StringName:
	if not owes(peer_id):
		return &"no_debt"
	var near := world._reach(peer_id, KIND, 0)
	if near != &"":
		return near
	if int(_cool.get(peer_id, 0)) > Time.get_ticks_msec():
		return &"cooldown"
	return &""


func fill(peer_id: int, payload: Dictionary) -> void:
	_cool[peer_id] = Time.get_ticks_msec() + int(WASH_SEC * 1000.0)
	payload[&"pay"] = mini(pay_per_plate(), debt_of(peer_id))


# --- every peer: apply --------------------------------------------------------------------------------------------------------

func _on_applied(peer_id: int, kind: StringName, _target: int, payload: Dictionary) -> void:
	if kind == CueRack.BUY_KIND and bool(payload.get(&"credit", false)):
		debts[peer_id] = debt_of(peer_id) + int(payload.get(&"price", 0))
		_shock(peer_id)
		_refresh()
	elif kind == KIND:
		var pay := int(payload.get(&"pay", 0))
		debts[peer_id] = maxi(debt_of(peer_id) - pay, 0)
		if debts[peer_id] == 0:
			debts.erase(peer_id)
		_washed = (_washed + 1) % (PLATES_SHOWN + 1)
		_scrubs[peer_id] = Time.get_ticks_msec()
		_sound(&"pocket_drop", global_position + Vector3(0.0, CABINET.y, 0.0), -8.0, 1.7)
		if not owes(peer_id) and peer_id == multiplayer.get_unique_id():
			_toast("Debt washed off: you can shoot again")
		_refresh()


## The credit buy's punishment, on every peer: the zap over the debtor; the host knocks them and hands their Turn on; their own client
## flashes and, once they stand, puts them at the sink.
func _shock(peer_id: int) -> void:
	zap_fx(peer_id)
	if multiplayer.is_server():
		var spawner := _spawner_node()
		if spawner != null:
			spawner.call(&"knock", peer_id, SHOCK_HOP, SHOCK_SEC)
		var rd := world.round_director if world != null else null
		if rd != null and rd.has_method(&"pass_turn"):
			rd.call(&"pass_turn", peer_id)
	if peer_id == multiplayer.get_unique_id():
		_drag_at = Time.get_ticks_msec() + 300  # the knock lands first
		_toast("No Cash for the cue: ZAP! Wash $%d off at the sink" % debt_of(peer_id))
	set_process(true)


## The zap on every peer (a credit buy here, a second ball grab in BallGrab): the sound, a ZAP! over the body, a cyan flash on the
## zapped player's own screen. The knock is the caller's.
func zap_fx(peer_id: int) -> void:
	var p := _player(peer_id)
	var at := p.global_position + Vector3(0.0, 2.0, 0.0) if p != null else global_position
	_sound(&"zap", at, -2.0, 1.0)
	var l := Label3D.new()
	l.text = "ZAP!"
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 96
	l.pixel_size = 0.004
	l.outline_size = 16
	l.modulate = SHOCK_COLOR
	l.top_level = true
	add_child(l)
	l.global_position = at
	_zaps.append({label = l, until = Time.get_ticks_msec() + 1200})
	if peer_id == multiplayer.get_unique_id():
		for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
			if n is FxStage:
				(n as FxStage).flash(SHOCK_COLOR, 0.9, 0.7)
	set_process(true)


# --- the sink ---------------------------------------------------------------------------------------------------------------------

func _build() -> void:
	var cab := MeshInstance3D.new()
	cab.name = "Cabinet"
	var box := BoxMesh.new()
	box.size = CABINET
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.85, 0.85, 0.8)
	wood.roughness = 0.6
	box.material = wood
	cab.mesh = box
	cab.position = Vector3(0.0, CABINET.y * 0.5, CABINET.z * 0.5)
	add_child(cab)
	var basin := MeshInstance3D.new()  # the steel tub let into the top
	basin.name = "Basin"
	var tub := BoxMesh.new()
	tub.size = Vector3(0.5, 0.06, 0.38)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.55, 0.58, 0.62)
	steel.metallic = 0.9
	steel.roughness = 0.25
	tub.material = steel
	basin.mesh = tub
	basin.position = Vector3(0.0, CABINET.y - 0.02, CABINET.z * 0.5)
	add_child(basin)
	var tap := MeshInstance3D.new()
	tap.name = "Tap"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.015
	cyl.bottom_radius = 0.02
	cyl.height = 0.3
	cyl.material = steel
	tap.mesh = cyl
	tap.position = Vector3(0.0, CABINET.y + 0.15, 0.08)
	add_child(tap)
	var plate_mat := StandardMaterial3D.new()
	plate_mat.albedo_color = Color(0.95, 0.95, 0.92)
	var dirt_mat := StandardMaterial3D.new()
	dirt_mat.albedo_color = Color(0.55, 0.45, 0.3)
	for i in PLATES_SHOWN:
		_dirty.append(_plate(Vector3(-0.32, CABINET.y + PLATE_H * (i + 0.5), CABINET.z * 0.5), dirt_mat))
		_clean.append(_plate(Vector3(0.32, CABINET.y + PLATE_H * (i + 0.5), CABINET.z * 0.5), plate_mat))
	var sign := Label3D.new()
	sign.name = "Sign"
	sign.text = "DISHES"
	sign.font_size = 48
	sign.pixel_size = 0.0025
	sign.outline_size = 10
	sign.modulate = Color(0.8, 0.95, 1.0)
	sign.position = Vector3(0.0, CABINET.y - 0.15, CABINET.z + 0.005)  # on the cabinet's front: the wall above is the Corner Pocket sign's
	add_child(sign)
	_prop = Interactable.new()
	_prop.name = "Prop"
	_prop.kind = KIND
	_prop.prompt = "Dirty dishes"
	_prop.position = PROP_AT
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = Bar.REACH_ZONE_RADIUS
	shape.shape = sphere
	_prop.add_child(shape)
	add_child(_prop)


func _plate(at: Vector3, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = PLATE_R
	c.bottom_radius = PLATE_R * 0.8
	c.height = PLATE_H
	c.radial_segments = 14
	c.rings = 1
	c.material = mat
	m.mesh = c
	m.position = at
	add_child(m)
	return m


func _refresh() -> void:
	var owed := ceili(float(total_debt()) / pay_per_plate()) if total_debt() > 0 else 0
	for i in _dirty.size():
		_dirty[i].visible = i < mini(owed, PLATES_SHOWN)
	for i in _clean.size():
		_clean[i].visible = i < _washed
	var me := multiplayer.get_unique_id()
	if _prop != null:
		_prop.prompt = ("Wash a plate (-$%d, $%d left)" % [mini(pay_per_plate(), debt_of(me)), debt_of(me)]) if owes(me) else "Dirty dishes"
	changed.emit()


# --- every frame: the scrub, the drag to the sink, the zap labels --------------------------------------------------------------

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for peer: int in _scrubs.keys():
		var p := _player(peer)
		var t := (now - int(_scrubs[peer])) / 1000.0
		if p == null or t >= WASH_SEC:
			_scrubs.erase(peer)
			if p != null:
				p.humanoid.clear_hand(1)
			continue
		var c := p.humanoid.to_local(global_transform * Vector3(0.0, CABINET.y + 0.05, CABINET.z * 0.5))
		p.humanoid.set_hand(1, c + Vector3(cos(t * 14.0), 0.0, sin(t * 14.0)) * 0.08)  # the left hand scrubs round in the basin
	if _drag_at >= 0 and now >= _drag_at:
		var me := _player(multiplayer.get_unique_id())
		if me == null or not owes(multiplayer.get_unique_id()):
			_drag_at = -1
		elif me.mode == Player.Mode.WALK:
			_drag_at = -1
			me.global_position = global_transform * STAND_AT
			me.velocity = Vector3.ZERO
			var to := global_position - me.global_position
			me.rotation.y = atan2(-to.x, -to.z)  # the body looks along -z
	for i in range(_zaps.size() - 1, -1, -1):
		if now >= int(_zaps[i].until):
			(_zaps[i].label as Node).queue_free()
			_zaps.remove_at(i)
	set_process(not _scrubs.is_empty() or _drag_at >= 0 or not _zaps.is_empty())


func _spawner_node() -> Node:
	if _spawner == null:
		_spawner = get_tree().get_first_node_in_group(&"player_spawner")
	return _spawner


func _player(peer: int) -> Player:
	var s := _spawner_node()
	return s.call(&"get_player", peer) as Player if s != null else null


func _sound(sound: StringName, at: Vector3, db: float, pitch: float) -> void:
	var sfx := get_node_or_null(^"/root/Sfx")  # by path: an autoload's name does not compile under a `-s` probe
	if sfx != null:
		sfx.call(&"play_at", sound, at, db, pitch)


func _toast(text: String) -> void:
	if UIRouter.instance != null:
		UIRouter.instance.toast(text, &"bad")
