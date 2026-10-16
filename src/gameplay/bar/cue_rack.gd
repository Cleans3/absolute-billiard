class_name CueRack
extends Node3D
## MainLevel/CueRack (docs/plan/08 §2.9, 06 P57): the wall rack that holds the campaign's five cues, and every cue in the room: in a
## hand, flying, on the floor. A player needs a cue in hand to shoot (`holds`). Every change is a bare world interaction (`KINDS`): the
## host validates (`validate_kind`) and decides the whole outcome into the payload (`fill_kind`: the slot, the flight and its landing,
## who is hit, whether the cue breaks), and every peer plays the broadcast the same way (`_on_applied`), so nothing here streams. Knocks
## and fines ride their own RPCs (`PlayerSpawner.knock`, `EconomyManager.add_cash`). The whole state goes out when a campaign starts or
## resumes and to a peer back from the background (`_cue_rack_state_rpc`).

signal changed

const SLOTS := 5                       ## the campaign's cues; ids 1..SLOTS
const KIND := &"cue_rack"              ## take / put back at the rack
const SWING_KIND := &"cue_swing"
const THROW_KIND := &"cue_throw"
const PICKUP_KIND := &"cue_pickup"     ## target_id = the cue id lying on the floor
const BUY_KIND := &"cue_buy"           ## at the counter (the Bartender's Drinks tab)
const KINDS: Array[StringName] = [KIND, SWING_KIND, THROW_KIND, PICKUP_KIND, BUY_KIND]
const BOARD := Vector3(1.1, 1.9, 0.2)  ## the wooden back board (w, h, depth from the wall: past the wainscot's chair rail, 0.14 m), its bottom BOARD_Y over the floor
const BOARD_Y := 0.2
const SLOT_GAP := 0.2                  ## between two standing cues
const STICK_BUTT_Y := 0.3              ## a racked cue's butt over the floor
const HOLD_HAND := Vector3(0.28, 0.95, -0.30)  ## the right hand holding a cue upright, a little ahead of the body so its owner sees it, in the Humanoid's space (front is -z)
const HOLD_FROM_BUTT := 0.9            ## the hand grips this far up from the butt
const LEAN_DEG := 8.0                  ## the held cue leans out from the body
const TIP_FORWARD_DEG := 12.0          ## ... and its tip forward, into its owner's first-person view
const PROP_AHEAD := 0.35               ## the Interactable stands this far in front of the board, on the floor
## Swing (08 §2.9 step 2) [tune]
const SWING_SEC := 0.4
const SWING_HIT_AT := 0.18             ## seconds into the swing the host lands a hit
const SWING_RANGE_M := 1.7
const SWING_CONE_DEG := 50.0
const SWING_COOLDOWN_MSEC := 800
const SWING_SHOULDER := Vector3(0.24, 1.38, 0.0)  ## the arc's centre, Humanoid space
const SWING_ARM := 0.42
const SWING_FROM_DEG := 60.0           ## the stick's angle from straight up toward the back at the wind-up ...
const SWING_TO_DEG := -100.0           ## ... and past forward-down at the follow-through
const SWING_GRIP := 0.2                ## swung, the hand holds it this far from the butt
const HITS_TO_BREAK := 4
## Throw [tune]
const THROW_MPS := 9.0
const THROW_UP_DEG := 6.0
const THROW_COOLDOWN_MSEC := 1000
const THROW_POSE_SEC := 0.3
const THROW_HAND := Vector3(0.25, 1.45, -0.55)
const THROWS_TO_BREAK := 3             ## the third throw breaks it on landing
const GRAVITY := 9.8
const FLIGHT_MAX_SEC := 2.0
const FLIGHT_STEP := 1.0 / 60.0
const TUMBLE_RAD_S := 14.0
const FLIGHT_MASK := 2 | 8             ## what a player body collides with: the room, the props, the table's lid, the players (08 §2.1)
const ROOM_HALF := 6.8                 ## a landing stays inside the walls
const LIE_Y := 0.016                   ## a lying stick's centre over its support
## A hit: away from the hitter, up a little, limp for KNOCK_SEC (PlayerSpawner.KNOCK_SEC)
const KNOCK_MPS := 3.5
const KNOCK_UP_MPS := 2.0
const KNOCK_SEC := 2.0
const PICKUP_REACH_M := 2.0
const BROKEN_SEC := 2.5
const PRICE_FINES := 2                 ## a new cue costs this many of the Night's scratch fine

## Off in a headless run (no probe that predates the rack needs a cue) and for the windowed tools (SoloSupport); the game sets nothing.
static var required := DisplayServer.get_name() != "headless"
## The host's clock for cooldowns and landings (probes step it).
static var clock: Callable = Time.get_ticks_msec

static var _stick_mat: StandardMaterial3D

@export var world: WorldInteractions

var slot_cue := PackedInt32Array()  ## per slot: the cue id in it, 0 = empty
var held := {}                      ## peer id -> cue id
var on_floor := {}                  ## cue id -> Vector3, where it lies (or will, once its flight lands)

var _wear := {}         # host: cue id -> Vector2i(throws, hits)
var _cool := {}         # host: "peer:kind" -> msec
var _landed_at := {}    # cue id -> local msec its flight lands (pickups wait for it)
var _flights := {}      # cue id -> {from, vel, t_land, land, yaw, breaks, start}
var _swings := {}       # peer -> local msec the swing started
var _throw_pose := {}   # peer -> local msec the throw started
var _racked: Array[MeshInstance3D] = []
var _carried := {}      # peer id -> MeshInstance3D, the held stick
var _loose := {}        # cue id -> {mesh, prop}: flying or on the floor
var _halves: Array[Dictionary] = []  # {nodes, until}
var _hand_on := {}      # peer id -> true while this rack drives that body's right hand
var _prop: Interactable
var _spawner: Node


func _ready() -> void:
	add_to_group(&"cue_rack")
	_build()
	_fill_rack(SLOTS)
	if world != null:
		world.interaction_applied.connect(_on_applied)
	multiplayer.peer_disconnected.connect(_on_peer_left)


# --- state ----------------------------------------------------------------------------------------------------------------------

func holds(peer_id: int) -> bool:
	return held.has(peer_id)


func cues_on_rack() -> int:
	var n := 0
	for c in slot_cue:
		n += 1 if c != 0 else 0
	return n


## The campaign's cues still intact: on the rack, in a hand, or loose (what the checkpoint saves as `cues_left`).
func intact_count() -> int:
	return cues_on_rack() + held.size() + on_floor.size()


## Host: what a new cue costs at the counter tonight.
func price() -> int:
	var loop := world.game_loop if world != null else null
	return PRICE_FINES * (EconomyManager.fine_for(loop.current_night()) if loop != null and not loop.nights.is_empty() else EconomyManager.FINE_MIN)


## Host: a campaign starts (5) or resumes (its saved `cues_left`): every intact cue back on the rack, nobody holding one, every peer told.
func reset_campaign(cues: int) -> void:
	if not multiplayer.is_server():
		return
	_fill_rack(cues)
	if not multiplayer.get_peers().is_empty():
		_cue_rack_state_rpc.rpc(slot_cue, _holder_pairs(), PackedInt32Array(on_floor.keys()), PackedVector3Array(on_floor.values()))


## Host: one peer back from the background gets the whole rack (RoundDirector.send_full_state).
func resync_peer(peer_id: int) -> void:
	_cue_rack_state_rpc.rpc_id(peer_id, slot_cue, _holder_pairs(), PackedInt32Array(on_floor.keys()), PackedVector3Array(on_floor.values()))


@rpc("authority", "call_remote", "reliable", 3)
func _cue_rack_state_rpc(slots: PackedInt32Array, holders: PackedInt32Array, floor_ids: PackedInt32Array, floor_pos: PackedVector3Array) -> void:
	if slots.size() != SLOTS or holders.size() % 2 != 0 or floor_ids.size() != floor_pos.size():
		return
	_clear_loose()
	for peer: int in held.keys():
		_drop_hand(peer)
	slot_cue = slots.duplicate()
	held.clear()
	for i in range(0, holders.size(), 2):
		held[holders[i]] = holders[i + 1]
	for i in floor_ids.size():
		on_floor[floor_ids[i]] = floor_pos[i]
	_refresh()


func _fill_rack(cues: int) -> void:
	_clear_loose()
	for peer: int in held.keys():
		_drop_hand(peer)
	held.clear()
	_wear.clear()
	slot_cue.resize(SLOTS)
	for i in SLOTS:
		slot_cue[i] = i + 1 if i < clampi(cues, 0, SLOTS) else 0
	_refresh()


func _clear_loose() -> void:
	for cue: int in _loose.keys():
		_free_loose(cue)
	on_floor.clear()
	_flights.clear()
	_landed_at.clear()


func _holder_pairs() -> PackedInt32Array:
	var out := PackedInt32Array()
	for peer: int in held:
		out.append(peer)
		out.append(int(held[peer]))
	return out


# --- host: validate and decide --------------------------------------------------------------------------------------------------

## Host (WorldInteractions._validate): why `peer_id` may not do `kind` now, or &"". Reach for the rack's own kinds is the caller's.
func validate_kind(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> StringName:
	match kind:
		KIND:
			return validate(peer_id, payload)
		SWING_KIND, THROW_KIND:
			if not holds(peer_id):
				return &"no_cue"
			var p := _player(peer_id)
			if p != null and p.mode != Player.Mode.WALK:
				return &"not_walking"
			if int(_cool.get("%d:%s" % [peer_id, kind], 0)) > int(clock.call()):
				return &"cooldown"
			if kind == THROW_KIND:
				var dir: Variant = payload.get(&"dir", null)
				if not dir is Vector3 or not (dir as Vector3).is_finite() or (dir as Vector3).length() < 0.5:
					return &"bad_payload"
			return &""
		PICKUP_KIND:
			if holds(peer_id):
				return &"has_cue"
			if not on_floor.has(target_id):
				return &"no_prop"
			if int(_landed_at.get(target_id, 0)) > Time.get_ticks_msec():
				return &"not_landed"
			var pos: Vector3 = world.player_position_source.call(peer_id)
			if not pos.is_finite():
				return &"no_position"
			return &"" if pos.distance_to(on_floor[target_id]) <= PICKUP_REACH_M else &"too_far"
		BUY_KIND:
			var near := world._reach(peer_id, &"bar_buy", 0)  # the counter's own prop
			if near != &"":
				return near
			if holds(peer_id):
				return &"has_cue"
			return &"cues_full" if intact_count() >= SLOTS else &""  # no Cash for it is a credit buy (step 3, DishStation), not a refusal
	return &"unknown_kind"


## Host (WorldInteractions._validate, `cue_rack`): take / put.
func validate(peer_id: int, payload: Dictionary) -> StringName:
	match payload.get(&"op", &""):
		&"take":
			if holds(peer_id):
				return &"has_cue"
			return &"rack_empty" if cues_on_rack() == 0 else &""
		&"put":
			return &"" if holds(peer_id) else &"no_cue"
	return &"bad_payload"


## Host (WorldInteractions._apply_bar): decides the outcome into the payload the broadcast carries. The rack's own state changes in
## `_on_applied`, on every peer alike; the knocks and the fines the host schedules here.
func fill_kind(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> void:
	match kind:
		KIND:
			fill(peer_id, payload)
		SWING_KIND:
			_cool["%d:%s" % [peer_id, kind]] = int(clock.call()) + SWING_COOLDOWN_MSEC
			var cue := int(held[peer_id])
			var victim := _swing_target(peer_id)
			var breaks := false
			if victim != 0:
				var w: Vector2i = _wear.get(cue, Vector2i.ZERO)
				w.y += 1
				_wear[cue] = w
				breaks = w.y >= HITS_TO_BREAK
				_knock_later(victim, peer_id, SWING_HIT_AT)
			payload[&"cue"] = cue
			payload[&"hit"] = victim
			payload[&"breaks"] = breaks
			if breaks:
				_fine_later(SWING_HIT_AT)
		THROW_KIND:
			_cool["%d:%s" % [peer_id, kind]] = int(clock.call()) + THROW_COOLDOWN_MSEC
			var cue := int(held[peer_id])
			var w: Vector2i = _wear.get(cue, Vector2i.ZERO)
			w.x += 1
			_wear[cue] = w
			var p := _player(peer_id)
			var dir: Vector3 = (payload[&"dir"] as Vector3).normalized()
			var right := dir.cross(Vector3.UP).normalized() if absf(dir.y) < 0.99 else Vector3.RIGHT
			dir = dir.rotated(right, deg_to_rad(THROW_UP_DEG)) if right.length() > 0.0 else dir
			var from := p.humanoid.hand_world(0) if p != null else (world.player_position_source.call(peer_id) as Vector3) + Vector3(0.0, 1.4, 0.0)
			var vel := dir * THROW_MPS
			var flight := _fly(peer_id, from, vel)
			payload[&"cue"] = cue
			payload[&"from"] = from
			payload[&"vel"] = vel
			payload[&"t_land"] = flight.t_land
			payload[&"land"] = flight.land
			payload[&"yaw"] = atan2(vel.x, vel.z)
			payload[&"hit"] = flight.hit
			payload[&"breaks"] = w.x >= THROWS_TO_BREAK
			if flight.hit != 0:
				_knock_later(flight.hit, peer_id, flight.t_land, from)
			if w.x >= THROWS_TO_BREAK:
				_fine_later(flight.t_land)
		PICKUP_KIND:
			payload[&"cue"] = target_id
		BUY_KIND:
			var used := {}
			for c in slot_cue:
				used[c] = true
			for c: int in held.values():
				used[c] = true
			for c: int in on_floor:
				used[c] = true
			for id in range(1, SLOTS + 1):
				if not used.has(id):
					payload[&"cue"] = id
					break
			var cost := price()
			payload[&"price"] = cost
			_wear.erase(int(payload.get(&"cue", 0)))
			if world.economy != null and not world.economy.try_spend_cash(cost, &"cue"):
				payload[&"credit"] = true  # the Cash does not cover it: the buyer owes it at the sink (DishStation)


## Host (`cue_rack`): picks the slot and the cue into the payload.
func fill(peer_id: int, payload: Dictionary) -> void:
	var take: bool = payload.get(&"op", &"") == &"take"
	for i in SLOTS:
		if (slot_cue[i] != 0) == take:
			payload[&"slot"] = i
			payload[&"cue"] = slot_cue[i] if take else int(held[peer_id])
			return


## Host: the nearest other player within reach of the swing and inside its cone, 0 for none. A hit obeys the host toggle only (06 P57).
func _swing_target(peer_id: int) -> int:
	var me := _player(peer_id)
	if me == null:
		return 0
	var ahead := -me.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized()
	var best := 0
	var best_d := SWING_RANGE_M
	for n in get_tree().get_nodes_in_group(&"players"):
		var other := n as Player
		var other_id := _peer_of(other)
		if other == null or other == me or other_id == 0 or other.mode == Player.Mode.RAGDOLL or not _may_hit(peer_id):
			continue
		var to := other.global_position - me.global_position
		to.y = 0.0
		var d := to.length()
		if d < best_d and (d < 0.3 or rad_to_deg(ahead.angle_to(to / maxf(d, 0.001))) <= SWING_CONE_DEG):
			best = other_id
			best_d = d
	return best


## The host toggle (03 §3.4 layer 4) is the one guard a cue hit obeys.
func _may_hit(peer_id: int) -> bool:
	if world == null:
		return true
	match world.hostile_policy:
		WorldInteractions.HostilePolicy.OFF:
			return false
		WorldInteractions.HostilePolicy.FRIENDS_ONLY:
			return peer_id == 1 or world.friends.has(peer_id)
	return true


## Host: the thrown stick's flight at request time against the room: the first player it meets is hit (`hit`), a wall drops it to the
## floor under the hit, anything else is where it lands. {t_land, land, hit}.
func _fly(peer_id: int, from: Vector3, vel: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	var me := _player(peer_id)
	if me != null:
		exclude.append(me.get_rid())
	var g := Vector3(0.0, -GRAVITY, 0.0)
	var pos := from
	var t := 0.0
	while t < FLIGHT_MAX_SEC:
		var nt := t + FLIGHT_STEP
		var npos := from + vel * nt + g * (0.5 * nt * nt)
		var q := PhysicsRayQueryParameters3D.create(pos, npos, FLIGHT_MASK, exclude)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var span := pos.distance_to(npos)
			var th := t + FLIGHT_STEP * clampf(pos.distance_to(hit.position) / maxf(span, 0.000001), 0.0, 1.0)
			var victim := hit.collider as Player
			var victim_id := _peer_of(victim)
			if victim_id != 0 and _may_hit(peer_id):
				return {t_land = th, land = _floor_under(victim.global_position + vel.normalized() * 0.3), hit = victim_id}
			var normal: Vector3 = hit.normal
			var land: Vector3 = hit.position
			if normal.y < 0.5:
				land = _floor_under(land + normal * 0.12)
			else:
				land += Vector3(0.0, LIE_Y, 0.0)
			return {t_land = th, land = _clamp_room(land), hit = 0}
		pos = npos
		t = nt
	return {t_land = FLIGHT_MAX_SEC, land = _floor_under(pos), hit = 0}


func _floor_under(p: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0.0, 0.05, 0.0), p - Vector3(0.0, 10.0, 0.0), FLIGHT_MASK)
	var past: Array[RID] = []
	for n in get_tree().get_nodes_in_group(&"players"):  # a stick falls past a body to the floor
		if n is CollisionObject3D:
			past.append((n as CollisionObject3D).get_rid())
	q.exclude = past
	var hit := space.intersect_ray(q)
	var y: float = (hit.position as Vector3).y if not hit.is_empty() else 0.0
	return _clamp_room(Vector3(p.x, y + LIE_Y, p.z))


static func _clamp_room(p: Vector3) -> Vector3:
	return Vector3(clampf(p.x, -ROOM_HALF, ROOM_HALF), p.y, clampf(p.z, -ROOM_HALF, ROOM_HALF))


## Host: knock `victim` away from `from_peer` (or from the point `from`) after `delay` seconds.
func _knock_later(victim: int, from_peer: int, delay: float, from := Vector3.INF) -> void:
	var spawner := get_tree().get_first_node_in_group(&"player_spawner")
	if spawner == null:
		return
	var src := from if from.is_finite() else (world.player_position_source.call(from_peer) as Vector3)
	get_tree().create_timer(maxf(delay, 0.0)).timeout.connect(func() -> void:
		var at: Vector3 = world.player_position_source.call(victim)
		if not at.is_finite():
			return
		var away := at - src
		away.y = 0.0
		away = away.normalized() if away.length() > 0.01 else Vector3.FORWARD
		spawner.call(&"knock", victim, away * KNOCK_MPS + Vector3(0.0, KNOCK_UP_MPS, 0.0), KNOCK_SEC))


## Host: the crew pays the Night's scratch fine for a broken cue, when it breaks (02 §3.8, reason `cue_broken`).
func _fine_later(delay: float) -> void:
	var econ := world.economy if world != null else null
	var loop := world.game_loop if world != null else null
	if econ == null:
		return
	var fine := EconomyManager.fine_for(loop.current_night()) if loop != null and not loop.nights.is_empty() else EconomyManager.FINE_MIN
	get_tree().create_timer(maxf(delay, 0.0)).timeout.connect(func() -> void:
		econ.add_cash(-fine, &"cue_broken")
		econ.fined.emit(&"cue_broken", fine))


# --- every peer: apply --------------------------------------------------------------------------------------------------------

## Every peer, from `world_interaction_applied`: the change the host decided.
func _on_applied(peer_id: int, kind: StringName, _target: int, payload: Dictionary) -> void:
	if not KINDS.has(kind):
		return
	var cue := int(payload.get(&"cue", 0))
	var now := Time.get_ticks_msec()
	match kind:
		KIND:
			var slot := int(payload.get(&"slot", -1))
			if slot < 0 or slot >= SLOTS or cue <= 0:
				return
			if payload.get(&"op", &"") == &"take":
				slot_cue[slot] = 0
				held[peer_id] = cue
			else:
				slot_cue[slot] = cue
				_drop_hand(peer_id)
				held.erase(peer_id)
		SWING_KIND:
			_swings[peer_id] = now
			_sound(&"ufo_whoosh", _hand_of(peer_id), -12.0, 1.8)
			if int(payload.get(&"hit", 0)) != 0:
				get_tree().create_timer(SWING_HIT_AT).timeout.connect(func() -> void: _sound(&"kick", _hand_of(peer_id), -2.0, 1.1))
			if bool(payload.get(&"breaks", false)):
				get_tree().create_timer(SWING_HIT_AT).timeout.connect(func() -> void: _break_in_hand(peer_id))
		THROW_KIND:
			if cue <= 0:
				return
			_drop_hand(peer_id)
			held.erase(peer_id)
			_throw_pose[peer_id] = now
			var t_land := float(payload.get(&"t_land", 0.0))
			_flights[cue] = {
				from = payload.get(&"from", Vector3.ZERO), vel = payload.get(&"vel", Vector3.ZERO), t_land = t_land,
				land = payload.get(&"land", Vector3.ZERO), yaw = float(payload.get(&"yaw", 0.0)), breaks = bool(payload.get(&"breaks", false)),
				start = now,
			}
			_landed_at[cue] = now + int(t_land * 1000.0)
			on_floor[cue] = payload.get(&"land", Vector3.ZERO)
			_sound(&"ufo_whoosh", payload.get(&"from", Vector3.ZERO), -10.0, 1.4)
		PICKUP_KIND:
			if cue <= 0:
				return
			_free_loose(cue)
			on_floor.erase(cue)
			_flights.erase(cue)
			_landed_at.erase(cue)
			held[peer_id] = cue
			_sound(&"rail_b", _hand_of(peer_id), -10.0, 1.3)
		BUY_KIND:
			if cue <= 0:
				return
			held[peer_id] = cue
	_refresh()


## A swing's fourth hit: the cue snaps in the swinger's hand.
func _break_in_hand(peer_id: int) -> void:
	if not held.has(peer_id):
		return
	var at := _hand_of(peer_id)
	_drop_hand(peer_id)
	held.erase(peer_id)
	_spawn_halves(at, randf() * TAU)
	_break_sound()
	_refresh()


## A thrown cue lands: it lies there, or (its third throw) snaps.
func _land(cue: int) -> void:
	var f: Dictionary = _flights[cue]
	_flights.erase(cue)
	_sound(&"rail_a", f.land, -6.0, 0.9)
	if f.breaks:
		_free_loose(cue)
		on_floor.erase(cue)
		_landed_at.erase(cue)
		_spawn_halves(f.land, f.yaw)
		_break_sound()
		_refresh()
		return
	var l: Dictionary = _loose.get(cue, {})
	if not l.is_empty():
		(l.mesh as MeshInstance3D).global_transform = _lying(f.land, f.yaw)


## The snap (the fine's banner is the HUD's, from `EconomyManager.fined`).
func _break_sound() -> void:
	_sound(&"kick", Vector3.INF, -3.0, 0.7)


## Host: a peer that leaves puts its cue back, told to everyone as an ordinary `put`.
func _on_peer_left(peer_id: int) -> void:
	if not multiplayer.is_server() or not holds(peer_id) or world == null:
		return
	var payload := {&"op": &"put"}
	fill(peer_id, payload)
	world.world_interaction_applied.rpc(peer_id, KIND, 0, payload)


# --- local requests (the Player's keys and touch buttons) ------------------------------------------------------------------------

func request_swing() -> void:
	if world != null:
		world.request(SWING_KIND, 0, {})


## `dir`: where the camera looks.
func request_throw(dir: Vector3) -> void:
	if world != null:
		world.request(THROW_KIND, 0, {&"dir": dir})


func request_buy() -> void:
	if world != null:
		world.request(BUY_KIND, 0, {})


# --- the rack on the wall -------------------------------------------------------------------------------------------------------

## The stick's look, shared by the racked cues and the held ones.
static func stick_material() -> StandardMaterial3D:
	if _stick_mat == null:
		_stick_mat = StandardMaterial3D.new()
		_stick_mat.albedo_color = Color(0.78, 0.6, 0.38)
		_stick_mat.roughness = 0.45
	return _stick_mat


static func stick_mesh(length := CueController.CUE_LEN_M) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.008
	m.bottom_radius = 0.015
	m.height = length
	m.radial_segments = 8
	m.rings = 1
	m.material = stick_material()
	return m


func _build() -> void:
	var board := MeshInstance3D.new()
	board.name = "Board"
	var box := BoxMesh.new()
	box.size = BOARD
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.32, 0.19, 0.1)
	wood.roughness = 0.8
	box.material = wood
	board.mesh = box
	board.position = Vector3(0.0, BOARD_Y + BOARD.y * 0.5, BOARD.z * 0.5)
	add_child(board)
	var rail := MeshInstance3D.new()  # the brass bar the cues lean into
	rail.name = "Rail"
	var bar := BoxMesh.new()
	bar.size = Vector3(BOARD.x * 0.92, 0.04, 0.05)
	var brass := StandardMaterial3D.new()
	brass.albedo_color = Color(0.8, 0.62, 0.25)
	brass.metallic = 0.8
	brass.roughness = 0.35
	bar.material = brass
	rail.mesh = bar
	rail.position = Vector3(0.0, STICK_BUTT_Y + CueController.CUE_LEN_M * 0.8, BOARD.z + 0.035)
	add_child(rail)
	var sign := Label3D.new()
	sign.name = "Sign"
	sign.text = "CUES"
	sign.font_size = 64
	sign.pixel_size = 0.0025
	sign.outline_size = 12
	sign.modulate = Color(1.0, 0.85, 0.5)
	sign.position = Vector3(0.0, BOARD_Y + BOARD.y - 0.08, BOARD.z + 0.01)
	add_child(sign)
	for i in SLOTS:
		var s := MeshInstance3D.new()
		s.name = "Cue%d" % (i + 1)
		s.mesh = stick_mesh()
		s.layers = 1 | Humanoid.MIRROR_LAYER
		s.position = Vector3((i - (SLOTS - 1) * 0.5) * SLOT_GAP, STICK_BUTT_Y + CueController.CUE_LEN_M * 0.5, BOARD.z + 0.03)
		add_child(s)
		_racked.append(s)
	_prop = Prop.new()
	_prop.name = "Prop"
	_prop.rack = self
	_prop.kind = KIND
	_prop.prompt = "Take a cue"
	_prop.position = Vector3(0.0, 0.0, PROP_AHEAD)
	_prop.add_child(_zone(Bar.REACH_ZONE_RADIUS))
	add_child(_prop)


static func _zone(radius: float) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	return shape


func _refresh() -> void:
	for i in _racked.size():
		_racked[i].visible = i < slot_cue.size() and slot_cue[i] != 0
	for peer: int in _carried.keys():
		if not held.has(peer):
			_carried[peer].queue_free()
			_carried.erase(peer)
	for peer: int in held:
		if not _carried.has(peer):
			var m := MeshInstance3D.new()
			m.name = "Held%d" % peer
			m.mesh = stick_mesh()
			m.layers = 1 | Humanoid.MIRROR_LAYER  # in the mirror too
			m.top_level = true
			m.visible = false
			add_child(m)
			_carried[peer] = m
	for cue: int in on_floor:
		if not _loose.has(cue):
			_make_loose(cue)
	for cue: int in _loose.keys():
		if not on_floor.has(cue):
			_free_loose(cue)
	_refresh_prompt()
	_update_processing()
	changed.emit()


func _update_processing() -> void:
	set_process(not held.is_empty() or not _flights.is_empty() or not _throw_pose.is_empty() or not _halves.is_empty())


## A loose cue: its stick (flying, then lying) and the prop that picks it up.
func _make_loose(cue: int) -> void:
	var m := MeshInstance3D.new()
	m.name = "Loose%d" % cue
	m.mesh = stick_mesh()
	m.layers = 1 | Humanoid.MIRROR_LAYER
	m.top_level = true
	add_child(m)
	var land: Vector3 = on_floor[cue]
	var f: Dictionary = _flights.get(cue, {})
	m.global_transform = _lying(land, float(f.get(&"yaw", 0.0))) if f.is_empty() else _in_flight(f, 0.0)
	var prop := Interactable.new()
	prop.name = "Pickup%d" % cue
	prop.kind = PICKUP_KIND
	prop.target_id = cue
	prop.prompt = "Pick up the cue"
	prop.add_child(_zone(0.6))
	add_child(prop)
	prop.global_position = land
	_loose[cue] = {mesh = m, prop = prop}


func _free_loose(cue: int) -> void:
	var l: Dictionary = _loose.get(cue, {})
	_loose.erase(cue)
	for k in [&"mesh", &"prop"]:
		var n: Node = l.get(k)
		if n != null and is_instance_valid(n):
			n.queue_free()


## Two halves of a snapped cue, lying crossed for BROKEN_SEC.
func _spawn_halves(at: Vector3, yaw: float) -> void:
	if not at.is_finite():
		return
	var nodes: Array[Node3D] = []
	for i in 2:
		var m := MeshInstance3D.new()
		m.mesh = stick_mesh(CueController.CUE_LEN_M * 0.5)
		m.top_level = true
		add_child(m)
		var y := yaw + (0.5 if i == 0 else -0.6)
		var base := _floor_under(at)
		m.global_transform = _lying(base + Vector3(cos(y), 0.0, -sin(y)) * 0.18 * (1.0 if i == 0 else -1.0), y)
		nodes.append(m)
	_halves.append({nodes = nodes, until = Time.get_ticks_msec() + int(BROKEN_SEC * 1000.0)})
	_update_processing()


## A stick lying on its side at `at` (its centre), pointing along `yaw`.
static func _lying(at: Vector3, yaw: float) -> Transform3D:
	var axis := Vector3(sin(yaw), 0.0, cos(yaw))  # the stick's length
	var side := Vector3.UP.cross(axis).normalized()
	return Transform3D(Basis(side, axis, side.cross(axis)), at)


## The flying stick `t` seconds after the throw: the ballistic arc, tumbling end over end about the axis across the throw.
static func _in_flight(f: Dictionary, t: float) -> Transform3D:
	var vel: Vector3 = f.vel
	var pos: Vector3 = (f.from as Vector3) + vel * t + Vector3(0.0, -GRAVITY, 0.0) * (0.5 * t * t)
	var fwd := vel.normalized() if vel.length() > 0.01 else Vector3.FORWARD
	var across := fwd.cross(Vector3.UP).normalized() if absf(fwd.y) < 0.99 else Vector3.RIGHT
	var axis := Vector3.UP.rotated(across, -TUMBLE_RAD_S * t)  # stays square to `across`: the stick tumbles end over end
	return Transform3D(Basis(across, axis, across.cross(axis)), pos)


## What the local player would do here.
func _refresh_prompt() -> void:
	if _prop == null:
		return
	if holds(multiplayer.get_unique_id()):
		_prop.prompt = "Put the cue back"
	else:
		_prop.prompt = "Take a cue" if cues_on_rack() > 0 else "No cues on the rack"


# --- every frame ----------------------------------------------------------------------------------------------------------------

## Each holder's stick in their right hand (upright while they walk, carry or sit; swung through its arc), the throw's arm, the flying
## sticks and the broken halves. In CUE the aim stick is the CueController's (the puppet's), and a limp body or a cutscene that is posing
## the crew is left alone: the stick hides, the hand goes back to the body.
func _process(_delta: float) -> void:
	if _spawner == null:
		_spawner = get_tree().get_first_node_in_group(&"player_spawner")
	var now := Time.get_ticks_msec()
	var posed := get_tree().get_first_node_in_group(Cutscene.PLAYING_GROUP) != null
	for peer: int in held:
		var stick: MeshInstance3D = _carried.get(peer)
		var p := _player(peer)
		if stick == null:
			continue
		if p == null or posed or p.mode == Player.Mode.CUE or p.mode == Player.Mode.RAGDOLL:
			stick.visible = false
			if p != null and not posed and p.mode == Player.Mode.CUE:
				_drop_hand(peer)
			continue
		var s := float(now - int(_swings.get(peer, -100000))) / (SWING_SEC * 1000.0)
		if s >= 0.0 and s < 1.0:
			_pose_swing(p, stick, s)
		else:
			_swings.erase(peer)
			_pose_hold(p, stick)
		_hand_on[peer] = true
		stick.visible = true
	for peer: int in _throw_pose.keys():
		var p := _player(peer)
		if now - int(_throw_pose[peer]) > THROW_POSE_SEC * 1000.0 or p == null or posed:
			_throw_pose.erase(peer)
			if p != null and not posed and not held.has(peer):
				p.humanoid.clear_hand(0)
		elif not held.has(peer):
			p.humanoid.set_hand(0, THROW_HAND)
	for cue: int in _flights.keys():
		var f: Dictionary = _flights[cue]
		var t := (now - int(f.start)) / 1000.0
		if t >= float(f.t_land):
			_land(cue)
			continue
		var l: Dictionary = _loose.get(cue, {})
		if not l.is_empty():
			(l.mesh as MeshInstance3D).global_transform = _in_flight(f, t)
	for i in range(_halves.size() - 1, -1, -1):
		if now >= int(_halves[i].until):
			for n: Node in _halves[i].nodes:
				n.queue_free()
			_halves.remove_at(i)
	_update_processing()


func _pose_hold(p: Player, stick: MeshInstance3D) -> void:
	p.humanoid.set_hand(0, HOLD_HAND)
	var hand := p.humanoid.hand_world(0)
	var up := p.global_basis.y.normalized()
	var right := p.global_basis.x.normalized()
	var ahead := -p.global_basis.z.normalized()
	var axis := (up + right * tan(deg_to_rad(LEAN_DEG)) + ahead * tan(deg_to_rad(TIP_FORWARD_DEG))).normalized()
	_place_stick(stick, hand - axis * HOLD_FROM_BUTT, axis, p.global_basis.z.normalized())


## The overhead swing at phase `s` (0..1): a quick wind-up to the back, then down through the front.
func _pose_swing(p: Player, stick: MeshInstance3D, s: float) -> void:
	var k := ease(s / 0.3, 0.5) * 0.25 if s < 0.3 else 0.25 + ease((s - 0.3) / 0.7, 0.4) * 0.75
	var phi := deg_to_rad(lerpf(SWING_FROM_DEG * 1.3, SWING_TO_DEG, k) if s >= 0.3 else lerpf(0.0, SWING_FROM_DEG * 1.3, k / 0.25))
	var d_local := Vector3(0.08, cos(phi), sin(phi)).normalized()  # +z is the body's back
	p.humanoid.set_hand(0, SWING_SHOULDER + d_local * SWING_ARM)
	var hand := p.humanoid.hand_world(0)
	var axis := (p.global_basis * d_local).normalized()
	_place_stick(stick, hand - axis * SWING_GRIP, axis, p.global_basis.x.normalized())


## The stick from its butt along `axis`; `ref` is any direction not along it (for the roll).
static func _place_stick(stick: MeshInstance3D, butt: Vector3, axis: Vector3, ref: Vector3) -> void:
	var side := axis.cross(ref).normalized()
	if side.length() < 0.01:
		side = axis.cross(Vector3.UP).normalized() if absf(axis.y) < 0.99 else Vector3.RIGHT
	stick.global_transform = Transform3D(Basis(side, axis, side.cross(axis)), butt + axis * CueController.CUE_LEN_M * 0.5)


## The body's right hand back to its stance (it no longer holds a cue, or the aim stick has it now).
func _drop_hand(peer: int) -> void:
	if not _hand_on.has(peer):
		return
	_hand_on.erase(peer)
	var p := _player(peer)
	if p != null:
		p.humanoid.clear_hand(0)


func _player(peer: int) -> Player:
	if _spawner == null:
		_spawner = get_tree().get_first_node_in_group(&"player_spawner")
	return _spawner.call(&"get_player", peer) as Player if _spawner != null else null


static func _peer_of(p: Player) -> int:
	var slot := p.get_parent() as PlayerSlot if p != null else null
	return slot.peer_id if slot != null else 0


func _hand_of(peer: int) -> Vector3:
	var p := _player(peer)
	return p.humanoid.hand_world(0) if p != null else Vector3.INF


## Sfx by path (an autoload's name does not compile under a `-s` probe); INF = a 2D sound.
func _sound(sound: StringName, at: Vector3, db: float, pitch: float) -> void:
	var sfx := get_node_or_null(^"/root/Sfx")
	if sfx == null:
		return
	if at.is_finite():
		sfx.call(&"play_at", sound, at, db, pitch)
	else:
		sfx.call(&"play", sound, db, pitch)


## The rack's Interactable: the request names `take` or `put` from what the local player holds.
class Prop extends Interactable:
	var rack: CueRack

	func try_use(payload := {}) -> bool:
		var p := payload.duplicate()
		p[&"op"] = &"put" if rack.holds(multiplayer.get_unique_id()) else &"take"
		return super(p)
