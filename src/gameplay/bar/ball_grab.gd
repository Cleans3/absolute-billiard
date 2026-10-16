class_name BallGrab
extends Node3D
## MainLevel/BallGrab (docs/plan/08 §2.9 step 4, 06 P57): grab a resting object ball off the table and throw it. A foul: the crew pays
## the scratch fine, the grabber loses a Turn, a second grab in a Night also shocks and stuns them. The real ball never leaves the
## host's physics: it is frozen with its collider off and hidden on every peer while it is *out* (no Shot starts then); the grabber
## carries and throws a replica, and when that lands the host puts the real ball back on the cloth (`RoundDirector.place_back`, which the
## rest-frame guard announces). Bare world interactions, decided by the host into the payload, applied by every peer from the broadcast.

signal changed

const GRAB := &"ball_grab"    ## target = the ball's net_id
const THROW := &"ball_throw"  ## payload {dir}
const BACK := &"ball_back"    ## the host's broadcast only
const KINDS: Array[StringName] = [GRAB, THROW, BACK]
const REACH_M := 2.0
const HOLD_MAX_SEC := 8.0     ## a ball held this long slips back onto the table
const STUN_SEC := 3.0         ## the second grab of a Night: shocked and limp this long
const STUN_HOP := Vector3(0.0, 2.2, 0.0)
const HAND := Vector3(-0.26, 1.05, -0.32)  ## the left hand holding the ball, Humanoid space
const PROMPT_TEXT := "Grab the ball (foul!)"

@export var world: WorldInteractions

var out := {}       ## net_id -> the peer holding it (0 = in flight, landing soon)
var held := {}      ## peer -> net_id
var offenses := {}  ## host: peer -> grabs this Night

var _flights := {}  # net_id -> {from, vel, t_land, start}
var _replicas := {} # net_id -> MeshInstance3D
var _hand_on := {}  # peer -> true while this drives that body's left hand
var _prop: Interactable  # local: the prompt on the nearest grabbable ball
var _rd: RoundDirector
var _spawner: Node


func _ready() -> void:
	add_to_group(&"ball_grab")
	_rd = get_node_or_null(^"../RoundDirector") as RoundDirector
	if world != null:
		world.interaction_applied.connect(_on_applied)
		if world.game_loop != null:
			world.game_loop.night_started.connect(func(_n: int, _q: int) -> void: offenses.clear())
			world.game_loop.round_ended.connect(func(_r: StringName, _p: int) -> void: _clear())
	if _rd != null:
		_rd.rack_ready.connect(func(_s: int) -> void: _clear())
	multiplayer.peer_disconnected.connect(_on_peer_left)
	_prop = Interactable.new()
	_prop.name = "Prop"
	_prop.kind = GRAB
	_prop.prompt = PROMPT_TEXT
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.25
	shape.shape = sphere
	_prop.add_child(shape)
	add_child(_prop)
	_park_prop()
	set_process(true)  # the prompt follows the local player's nearest ball


func holds(peer_id: int) -> bool:
	return held.has(peer_id)


## A ball is off the table: no Shot starts (RoundDirector._validate_shot `ball_out`).
func any_out() -> bool:
	return not out.is_empty()


func request_throw(dir: Vector3) -> void:
	if world != null:
		world.request(THROW, 0, {&"dir": dir})


# --- host: validate and decide --------------------------------------------------------------------------------------------------

func validate_kind(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> StringName:
	match kind:
		GRAB:
			match world.hostile_policy:
				WorldInteractions.HostilePolicy.OFF:
					return &"hostile_off"
				WorldInteractions.HostilePolicy.FRIENDS_ONLY:
					if peer_id != 1 and not world.friends.has(peer_id):
						return &"hostile_friends_only"
			if not world._live():
				return &"not_live"
			if _rd == null or _rd.shot_in_progress or _rd.staging or _rd.table.sim.awake > 0:
				return &"balls_moving"
			if holds(peer_id):
				return &"has_ball"
			var towel := get_tree().get_first_node_in_group(&"footprints")
			if towel != null and int(towel.get(&"towel_holder")) == peer_id:
				return &"hands_full"
			var ball := _ball(target_id)
			if ball == null or ball.is_cue_ball or ball.is_pocketed or ball.retired or out.has(target_id):
				return &"no_prop"
			var pos: Vector3 = world.player_position_source.call(peer_id)
			if not pos.is_finite():
				return &"no_position"
			return &"" if Vector2(pos.x - ball.global_position.x, pos.z - ball.global_position.z).length() <= REACH_M else &"too_far"
		THROW:
			if not holds(peer_id):
				return &"no_ball"
			var dir: Variant = payload.get(&"dir", null)
			if not dir is Vector3 or not (dir as Vector3).is_finite() or (dir as Vector3).length() < 0.5:
				return &"bad_payload"
			return &""
	return &"host_only"  # `ball_back` is the host's own broadcast


func fill_kind(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> void:
	match kind:
		GRAB:
			var ball := _ball(target_id)
			ball.freeze = true
			ball.get_node(^"Shape").set_deferred(&"disabled", true)
			offenses[peer_id] = int(offenses.get(peer_id, 0)) + 1
			var shock: bool = offenses[peer_id] >= 2
			payload[&"net_id"] = target_id
			payload[&"shock"] = shock
			_fine()
			if _rd.current_shooter_id == peer_id:
				_rd.pass_turn(peer_id)
			else:
				_rd.skip_next_turn(peer_id)
			if shock:
				var spawner := _spawner_node()
				if spawner != null:
					spawner.call(&"knock", peer_id, STUN_HOP, STUN_SEC)
			get_tree().create_timer(HOLD_MAX_SEC).timeout.connect(func() -> void:
				if held.get(peer_id, -1) == target_id:
					_put_back(target_id))
		THROW:
			var id := int(held[peer_id])
			var p := _player(peer_id)
			var rack := get_tree().get_first_node_in_group(&"cue_rack") as CueRack
			var dir: Vector3 = (payload[&"dir"] as Vector3).normalized()
			var across := dir.cross(Vector3.UP).normalized() if absf(dir.y) < 0.99 else Vector3.RIGHT
			dir = dir.rotated(across, deg_to_rad(CueRack.THROW_UP_DEG))
			var from := p.humanoid.hand_world(1) if p != null else (world.player_position_source.call(peer_id) as Vector3) + Vector3(0.0, 1.2, 0.0)
			var vel := dir * CueRack.THROW_MPS
			var flight: Dictionary = rack._fly(peer_id, from, vel) if rack != null else {t_land = 0.5, land = from, hit = 0}
			payload[&"net_id"] = id
			payload[&"from"] = from
			payload[&"vel"] = vel
			payload[&"t_land"] = flight.t_land
			payload[&"land"] = flight.land
			payload[&"hit"] = flight.hit
			if int(flight.hit) != 0 and rack != null:
				rack._knock_later(flight.hit, peer_id, flight.t_land, from)
			get_tree().create_timer(float(flight.t_land) + 0.15).timeout.connect(_put_back.bind(id))


## Host: the crew pays the Night's scratch fine for a grab (02 §3.8, reason `ball_grab`).
func _fine() -> void:
	var econ := world.economy
	if econ == null:
		return
	var loop := world.game_loop
	var fine := EconomyManager.fine_for(loop.current_night()) if loop != null and not loop.nights.is_empty() else EconomyManager.FINE_MIN
	econ.add_cash(-fine, &"ball_grab")
	econ.fined.emit(&"ball_grab", fine)


## Host: the real ball back on the cloth near where it was, and every peer told.
func _put_back(net_id: int) -> void:
	if not multiplayer.is_server() or not out.has(net_id):
		return
	var ball := _ball(net_id)
	if ball != null and _rd != null:
		_rd.place_back(ball)
	world.world_interaction_applied.rpc(0, BACK, net_id, {&"net_id": net_id})


func _on_peer_left(peer_id: int) -> void:
	if multiplayer.is_server() and holds(peer_id):
		_put_back(int(held[peer_id]))


# --- every peer: apply --------------------------------------------------------------------------------------------------------

func _on_applied(peer_id: int, kind: StringName, _target: int, payload: Dictionary) -> void:
	if not KINDS.has(kind):
		return
	var id := int(payload.get(&"net_id", -1))
	var ball := _ball(id)
	match kind:
		GRAB:
			out[id] = peer_id
			held[peer_id] = id
			if ball != null:
				ball.visible = false
				_replica(id, ball)
			_sound(&"rail_b", ball.global_position if ball != null else Vector3.INF, -8.0, 1.6)
			if bool(payload.get(&"shock", false)):
				var sink := get_tree().get_first_node_in_group(&"dish_station") as DishStation
				if sink != null:
					sink.zap_fx(peer_id)
			if peer_id == multiplayer.get_unique_id():
				_toast("Foul: you grabbed a ball. You lose a Turn" + (" and get ZAPPED" if bool(payload.get(&"shock", false)) else ""))
		THROW:
			held.erase(peer_id)
			_drop_hand(peer_id)
			out[id] = 0
			_flights[id] = {from = payload.get(&"from", Vector3.ZERO), vel = payload.get(&"vel", Vector3.ZERO), t_land = float(payload.get(&"t_land", 0.0)), start = Time.get_ticks_msec()}
			_sound(&"ufo_whoosh", payload.get(&"from", Vector3.ZERO), -10.0, 1.6)
		BACK:
			for p: int in held.keys():
				if held[p] == id:
					held.erase(p)
					_drop_hand(p)
			out.erase(id)
			_flights.erase(id)
			_free_replica(id)
			if ball != null and not ball.is_pocketed and not ball.retired:
				ball.visible = true
	set_process(true)
	changed.emit()


func _clear() -> void:
	for p: int in held.keys():
		_drop_hand(p)
	held.clear()
	out.clear()
	_flights.clear()
	for id: int in _replicas.keys():
		_free_replica(id)
	changed.emit()


func _replica(id: int, ball: Ball) -> void:
	_free_replica(id)
	var m := MeshInstance3D.new()
	m.name = "Replica%d" % id
	var mi := ball.get_node_or_null(^"Mesh") as MeshInstance3D
	m.mesh = mi.mesh if mi != null else SphereMesh.new()
	m.layers = 1 | Humanoid.MIRROR_LAYER
	m.top_level = true
	add_child(m)
	m.global_position = ball.global_position
	_replicas[id] = m


func _free_replica(id: int) -> void:
	var m: Node = _replicas.get(id)
	_replicas.erase(id)
	if m != null and is_instance_valid(m):
		m.queue_free()


# --- every frame: the ball in the hand, in the air; the local prompt -----------------------------------------------------------

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for p: int in held:
		var body := _player(p)
		var m: MeshInstance3D = _replicas.get(held[p])
		if body == null or m == null:
			continue
		var limp := body.mode == Player.Mode.RAGDOLL
		if not limp:
			body.humanoid.set_hand(1, HAND)
			_hand_on[p] = true
		m.global_position = body.humanoid.hand_world(1) + (-body.global_basis.z.normalized()) * 0.05
	for id: int in _flights.keys():
		var f: Dictionary = _flights[id]
		var t := (now - int(f.start)) / 1000.0
		var m: MeshInstance3D = _replicas.get(id)
		if m == null:
			continue
		if t >= float(f.t_land):
			m.visible = false  # landed: the house racks the real one back
			continue
		m.global_position = (f.from as Vector3) + (f.vel as Vector3) * t + Vector3(0.0, -CueRack.GRAVITY, 0.0) * (0.5 * t * t)
	_place_prop()


## The prompt sits on the nearest object ball in front of the local player the host would let them grab; parked out of reach otherwise.
func _place_prop() -> void:
	var me := _player(multiplayer.get_unique_id())
	if me == null or _rd == null or world == null or not world._live() or _rd.shot_in_progress or _rd.staging or holds(multiplayer.get_unique_id()):
		_park_prop()
		return
	var ahead := -me.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized()
	var best: Ball = null
	var best_d := REACH_M
	for b in _rd.get_balls():
		if b.is_cue_ball or b.is_pocketed or b.retired or out.has(b.net_id):
			continue
		var to := b.global_position - me.global_position
		to.y = 0.0
		var d := to.length()
		if d < best_d and ahead.angle_to(to / maxf(d, 0.001)) < deg_to_rad(40.0):
			best = b
			best_d = d
	if best == null:
		_park_prop()
		return
	_prop.target_id = best.net_id
	_prop.global_position = Vector3(best.global_position.x, me.global_position.y, best.global_position.z)


func _park_prop() -> void:
	if _prop != null and _prop.is_inside_tree():
		_prop.global_position = Vector3(0.0, -50.0, 0.0)


func _drop_hand(peer: int) -> void:
	if not _hand_on.has(peer):
		return
	_hand_on.erase(peer)
	var p := _player(peer)
	if p != null:
		p.humanoid.clear_hand(1)


func _ball(net_id: int) -> Ball:
	if _rd == null:
		return null
	for b in _rd.get_balls():
		if is_instance_valid(b) and b.net_id == net_id:
			return b
	return null


func _spawner_node() -> Node:
	if _spawner == null:
		_spawner = get_tree().get_first_node_in_group(&"player_spawner")
	return _spawner


func _player(peer: int) -> Player:
	var s := _spawner_node()
	return s.call(&"get_player", peer) as Player if s != null else null


func _sound(sound: StringName, at: Vector3, db: float, pitch: float) -> void:
	var sfx := get_node_or_null(^"/root/Sfx")
	if sfx == null:
		return
	if at.is_finite():
		sfx.call(&"play_at", sound, at, db, pitch)
	else:
		sfx.call(&"play", sound, db, pitch)


func _toast(text: String) -> void:
	if UIRouter.instance != null:
		UIRouter.instance.toast(text, &"bad")
