class_name DebugSession
extends Node

## What the phone debug panel does (adhoc-1012a): live physics edits, every shot recorded with the table it started from,
## rewind / replay, table resets, round and economy cheats. No UI in here: DebugPanel and DebugStrip call it, the probes
## under tests/debug drive it. Host-only (clients see their own numbers move at the next shot start, 04 §5). Gameplay never
## references this file.
##
## Replay is a RE-SIMULATION, not a recording: rewind puts every ball back where it was and zeroes it, then the recorded
## ShotIntent goes through the normal shot path (validator, scoring, tricks). Jolt on one machine reproduces a shot from
## the same state closely but not bit for bit (contact caches, float order), and a miscue draws `randf` — so each replay
## reports how far the balls ended from the original run (`ShotRecord.error_m`) instead of promising an identical one.

signal changed  ## recorded shots, tuning or table state changed: panels re-read
signal said(text: String)  ## one line of feedback for the panel's status bar

const SETTLE_SEC := 6.0  ## restored balls drop their clearance and come to rest well inside this
const MAX_RECORDS := 60
const PRESETS := ["break", "straight_in", "cut", "stun"]
const CUE_FIELDS := [&"power_cap_speed_mps", &"spin_offset_radius", &"miscue_threshold"]
const STATS := [&"cloth_friction_mult", &"cushion_restitution_mult", &"cue_ball_mass_mult", &"table_tilt_deg"]
const PRESET_TYPES := {
	cue = preload("res://src/resources/ball_types/cue.tres"),
	red = preload("res://src/resources/ball_types/red_basic.tres"),
	blue = preload("res://src/resources/ball_types/blue_mid.tres"),
	gold = preload("res://src/resources/ball_types/gold_prize.tres"),
	black = preload("res://src/resources/ball_types/black_penalty.tres"),
}


## One shot and the table it started from.
class ShotRecord extends RefCounted:
	var serial := 0
	var shot_id := ""  # "n<night>-r<round>-s<n>" (RoundDirector's), or "free" for a shot outside a live Round
	var intent: ShotIntent
	var shooter_id := 0
	var balls: Array[Dictionary] = []  # {net_id, type: BallType, pos: Vector3, active: bool}
	var shots_left := 0
	var round_points := 0
	var time_left := 0.0
	var cash := 0
	var final: Dictionary = {}  # net_id -> Vector3 (world), active balls only, when the shot ended
	var raw_points := 0
	var tricks: Array[StringName] = []
	var foul := false
	var done := false
	var replays := 0
	var error_m := -1.0  # worst ball distance between the last replay's end and the original's, -1 = never replayed

	## "n1-r2" of "n1-r2-s3"; empty for a sandbox shot.
	func round_id() -> String:
		var at := shot_id.rfind("-s")
		return shot_id.substr(0, at) if at > 0 else ""

	func label() -> String:
		var s := "#%d %s  p%.2f  aim %.0f°" % [serial, shot_id, intent.power, rad_to_deg(intent.aim_dir.angle())]
		if not done:
			return s + "  …"
		s += "  %+d pts" % raw_points
		if foul:
			s += "  FOUL"
		if not tricks.is_empty():
			s += "  " + String(tricks[0])
		if error_m >= 0.0:
			s += "  replay Δ %.1f mm" % (error_m * 1000.0)
		return s


var table: Table
var director: RoundDirector
var game_loop: GameLoop
var economy: EconomyManager
var effects: EffectManager
var shots: Array[ShotRecord] = []
var tuning_path := "user://debug_physics.cfg"
var replaying := false

var _serial := 0
var _pending_id := ""
var _open: ShotRecord
var _target: ShotRecord  # the record a replay in flight belongs to
var _apply_queued := false


func is_host() -> bool:
	return multiplayer.is_server()


func start() -> void:
	director.shot_started.connect(func(id: String, _shooter: int) -> void: _pending_id = id)
	table.sim.shot_started.connect(_on_sim_shot_started)
	director.shot_ended.connect(_on_shot_ended)
	table.sim.all_resting.connect(changed.emit)


func busy() -> bool:
	return table.sim.awake > 0 or director.shot_in_progress


func last() -> ShotRecord:
	return shots.back() if not shots.is_empty() else null


func _say(text: String) -> void:
	said.emit(text)


# ---------------------------------------------------------------- physics numbers

func spec() -> TableSpec:
	return table.spec


func field_value(field: StringName) -> float:
	return float(table.spec.get(field))


func field_default(field: StringName) -> float:
	return float(TableSpec.new().get(field))


func is_default(field: StringName) -> bool:
	return is_equal_approx(field_value(field), field_default(field))


## [min, max, step] from the field's @export_range; a bool has none.
func field_range(field: StringName) -> Vector3:
	for p in table.spec.get_property_list():
		if p.name == field and p.hint == PROPERTY_HINT_RANGE:
			var parts: PackedStringArray = String(p.hint_string).split(",")
			return Vector3(float(parts[0]), float(parts[1]), float(parts[2]) if parts.size() > 2 else 0.01)
	return Vector3(0.0, 1.0, 0.01)


func is_flag(field: StringName) -> bool:
	return typeof(table.spec.get(field)) == TYPE_BOOL


## Sets a LIVE field and applies it once per frame, however many sliders moved.
func set_field(field: StringName, value: float) -> void:
	table.spec.set_live(field, value)
	if not _apply_queued:
		_apply_queued = true
		_apply.call_deferred()


func _apply() -> void:
	_apply_queued = false
	table.apply_physics()
	changed.emit()


func set_defaults() -> void:
	var d := TableSpec.new()
	for f in TableSpec.LIVE_FIELDS:
		table.spec.set_live(f, float(d.get(f)))
	table.apply_physics()
	_say("physics: every number back to the defaults")
	changed.emit()


func stat_value(stat: StringName) -> float:
	match stat:
		&"cloth_friction_mult": return table.sim.cloth_friction_mult
		&"cushion_restitution_mult": return table.sim.cushion_restitution_mult
		&"cue_ball_mass_mult": return table.sim.cue_ball_mass_mult
		_: return table.sim.table_tilt_deg


func set_stat(stat: StringName, value: float) -> void:
	table.sim.set_stat(stat, value)
	changed.emit()


func set_tilt_direction_deg(deg: float) -> void:
	table.sim.set_tilt_direction(Vector2.from_angle(deg_to_rad(deg)))
	changed.emit()


func tilt_direction_deg() -> float:
	return rad_to_deg(table.sim.tilt_direction.angle()) if table.sim.tilt_direction != Vector2.ZERO else 0.0


func cue_value(field: StringName) -> float:
	return float(table.sim.active_cue.get(field))


func set_cue(field: StringName, value: float) -> void:
	table.sim.active_cue.set(field, value)
	changed.emit()


## `field = value` for every LIVE field that is not at its default: what to paste into TableSpec after a tuning session.
func tuning_text() -> String:
	var lines := PackedStringArray()
	for f in TableSpec.LIVE_FIELDS:
		if not is_default(f):
			lines.append("%s = %s" % [f, field_value(f)])
	return "\n".join(lines)


func save_tuning() -> void:
	var cfg := ConfigFile.new()
	for f in TableSpec.LIVE_FIELDS:
		cfg.set_value("physics", f, field_value(f))
	cfg.save(tuning_path)
	_say("physics: saved, loaded again at the next start in debug mode")


## True when a saved tuning existed and was applied.
func load_tuning() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(tuning_path) != OK:
		return false
	for f in TableSpec.LIVE_FIELDS:
		if cfg.has_section_key("physics", f):
			table.spec.set_live(f, float(cfg.get_value("physics", f)))
	table.apply_physics()
	changed.emit()
	return true


func clear_tuning() -> void:
	DirAccess.remove_absolute(tuning_path)
	set_defaults()


# ---------------------------------------------------------------- recorded shots

func _on_sim_shot_started(_ball: Ball, intent: ShotIntent) -> void:
	var id := _pending_id if director.shot_in_progress else "free"
	_pending_id = ""
	if replaying and _target != null:
		return  # the record being replayed already owns this shot
	var rec := ShotRecord.new()
	_serial += 1
	rec.serial = _serial
	rec.shot_id = id
	rec.intent = _copy_intent(intent)
	rec.shooter_id = intent.shooter_id
	for b in director.get_balls():
		rec.balls.append({net_id = b.net_id, type = b.ball_type, pos = b.global_position, active = _on_table(b)})
	if game_loop != null:
		rec.shots_left = game_loop.shots_left
		rec.round_points = game_loop.round_points
		rec.time_left = game_loop.time_left
	if economy != null:
		rec.cash = economy.cash
	shots.append(rec)
	if shots.size() > MAX_RECORDS:
		shots.pop_front()
	_open = rec
	changed.emit()


func _on_shot_ended(_id: String, _shooter: int, raw: int, ids: Array[StringName], foul: bool) -> void:
	var rec := _target if _target != null else _open
	if rec == null:
		return
	var final := _positions()
	if _target != null:
		rec.error_m = _distance(rec.final, final)
		rec.replays += 1
		_say("replay of #%d ended %.1f mm from the original" % [rec.serial, rec.error_m * 1000.0])
	else:
		rec.final = final
		rec.raw_points = raw
		rec.tricks = ids.duplicate()
		rec.foul = foul
		rec.done = true
	_open = null
	changed.emit()


static func _copy_intent(i: ShotIntent) -> ShotIntent:
	var c := ShotIntent.new()
	c.aim_dir = i.aim_dir
	c.power = i.power
	c.spin_offset = i.spin_offset
	c.elevation_deg = i.elevation_deg
	c.shooter_id = i.shooter_id
	c.called_pocket = i.called_pocket
	return c


static func _on_table(b: Ball) -> bool:
	return not b.retired and not b.is_pocketed


func _positions() -> Dictionary:
	var out := {}
	for b in director.get_balls():
		if _on_table(b):
			out[b.net_id] = b.global_position
	return out


## Worst distance between two end states; a ball on the table in only one of them counts as a whole table length.
func _distance(a: Dictionary, b: Dictionary) -> float:
	var worst := 0.0
	for id in a:
		worst = maxf(worst, (a[id] as Vector3).distance_to(b[id]) if b.has(id) else table.spec.length_m)
	for id in b:
		if not a.has(id):
			worst = maxf(worst, table.spec.length_m)
	return worst


## Puts the table back to the start of `rec`: every ball where it stood, balls that were gone stay gone, balls spawned
## since (a split) are retired; shots left, points, time and Cash come back too. Not the crowd, the Effects or the Turn.
func rewind(rec: ShotRecord) -> bool:
	if not _can_edit_table():
		return false
	var now := current_round_id()
	if now != "" and rec.round_id() != "" and rec.round_id() != now:
		_say("#%d is from Round %s; this is %s: re-rack or advance to it first" % [rec.serial, rec.round_id(), now])
		return false
	var by_id := {}
	for e in rec.balls:
		by_id[e.net_id] = e
	for b in director.get_balls():
		if not by_id.has(b.net_id):
			if not b.retired:
				b.retire()
			continue
		var e: Dictionary = by_id[b.net_id]
		if e.active:
			b.restore(e.pos)
			b.reset_physics_interpolation()
		elif not b.retired:
			b.retire()
	if game_loop != null and game_loop.phase == GameLoop.Phase.ROUND_LIVE:
		game_loop.shots_left = rec.shots_left
		game_loop.round_points = rec.round_points
		game_loop.time_left = rec.time_left
		game_loop.state_changed.emit()
	if economy != null and economy.cash != rec.cash:
		economy.add_cash(rec.cash - economy.cash, &"debug")
	director.current_shooter_id = rec.shooter_id
	_say("rewound to the start of #%d" % rec.serial)
	changed.emit()
	return true


## Rewind, let the table settle, fire the recorded intent through the normal shot path. Returns true when the shot ran.
func replay(rec: ShotRecord) -> bool:
	if replaying or not rewind(rec):
		return false
	replaying = true
	_target = rec
	await _settled()
	var ok := _fire(_copy_intent(rec.intent))
	if ok:
		await director.shot_ended
	else:
		_say("replay of #%d was refused" % rec.serial)
	_target = null
	replaying = false
	changed.emit()
	return ok


## "n1-r2": the Round RoundDirector is dealing, from the loop; empty without a GameLoop.
func current_round_id() -> String:
	if game_loop == null or game_loop.phase != GameLoop.Phase.ROUND_LIVE:
		return ""
	return "n%d-r%d" % [game_loop.current_night().night_number, game_loop.round_index]


## `rec` and every later shot of its Round, one after the other, each from the state the original left.
func replay_from(rec: ShotRecord) -> void:
	var from := shots.find(rec)
	if from < 0:
		return
	for r in shots.slice(from):
		if r.round_id() != rec.round_id():
			break
		if not await replay(r):
			break


## The live Round again from its first recorded shot (the rack dealt for it is the one that shot started from).
func replay_round() -> void:
	var id := current_round_id()
	for r in shots:
		if r.round_id() == id:
			await replay_from(r)
			return
	_say("no shot recorded in this Round yet")


func clear_shots() -> void:
	shots.clear()
	_open = null
	changed.emit()


func _settled() -> void:
	for i in 3:
		await get_tree().physics_frame
	var left := SETTLE_SEC
	while table.sim.awake > 0 and left > 0.0:
		await get_tree().physics_frame
		left -= 1.0 / Engine.physics_ticks_per_second


func _fire(intent: ShotIntent) -> bool:
	var cue := _cue_ball()
	if cue == null:
		return false
	intent.shooter_id = multiplayer.get_unique_id()
	if director.can_strike(cue):
		table.sim.request_shot(intent)
		return director.shot_in_progress
	cue.strike(intent, table.sim.active_cue)  # no live Round: a physics sandbox shot, nobody scores it
	return true


func _cue_ball() -> Ball:
	for b in director.get_balls():
		if b.is_cue_ball and _on_table(b):
			return b
	return null


## A test shot from the panel: `aim_deg` in the table plane (0 = down the long axis), `power` 0..1.
func fire(aim_deg: float, power: float, spin := Vector2.ZERO, elevation_deg := 0.0) -> bool:
	if not _can_edit_table():
		return false
	var i := ShotIntent.new()
	var d := table.global_transform.basis * Vector3(cos(deg_to_rad(aim_deg)), 0.0, sin(deg_to_rad(aim_deg)))
	i.aim_dir = Vector2(d.x, d.z).normalized()
	i.power = power
	i.spin_offset = spin
	i.elevation_deg = elevation_deg
	return _fire(i)


## Angle (table plane) from the cue ball to the nearest ball on the table, for a quick stun test; NAN when there is none.
func aim_at_nearest() -> float:
	var cue := _cue_ball()
	if cue == null:
		return NAN
	var best := INF
	var angle := NAN
	for b in director.get_balls():
		if b == cue or not _on_table(b):
			continue
		var d := table.to_local(b.global_position) - table.to_local(cue.global_position)
		if d.length() < best:
			best = d.length()
			angle = rad_to_deg(atan2(d.z, d.x))
	return angle


# ---------------------------------------------------------------- the table

func _can_edit_table() -> bool:
	if not is_host():
		_say("host only: this peer cannot change the table")
		return false
	if director.shot_in_progress or table.sim.awake > 0:
		_say("the balls are still moving: Stop them first")
		return false
	return true


## Every ball stilled where it is. A live shot resolves normally from there (fouls, score).
func stop_balls() -> void:
	if not is_host():
		return
	for b in director.get_balls():
		b.linear_velocity = Vector3.ZERO
		b.angular_velocity = Vector3.ZERO
	_say("balls stopped")


func reset_cue_ball() -> void:
	var cue := _cue_ball()
	if cue == null or not _can_edit_table():
		return
	var head: Vector3 = table.layout.spots.head
	cue.restore(_world(Vector2(head.x, head.z), cue))
	cue.reset_physics_interpolation()
	_say("cue ball on the head spot")
	changed.emit()


func clear_table() -> void:
	if not _can_edit_table():
		return
	for b in director.get_balls():
		if not b.is_cue_ball and not b.retired:
			b.retire()
	_say("table cleared, cue ball left")
	changed.emit()


## A DebugRackPresets layout dealt onto the Round's own balls (same types first, any other object ball after).
func apply_preset(preset: String) -> void:
	if not _can_edit_table():
		return
	var entries := DebugRackPresets.new().build(preset, table.spec)
	var free: Array[Ball] = director.get_balls()
	for e in entries:
		var want: BallType = PRESET_TYPES.get(String(e.type))
		var pick: Ball
		for b in free:
			if b.ball_type == want:
				pick = b
				break
		if pick == null:
			for b in free:
				if b.is_cue_ball == (e.type == &"cue"):
					pick = b
					break
		if pick == null:
			continue
		free.erase(pick)
		pick.restore(_world(Vector2(e.x, e.z), pick))
		pick.reset_physics_interpolation()
	for b in free:
		if not b.retired:
			b.retire()
	_say("rack: %s" % preset)
	changed.emit()


func _world(p: Vector2, b: Ball) -> Vector3:
	return table.to_global(Vector3(p.x, table.cloth_y() + b.radius + table.spec.clearance_margin_m, p.y))


## Deals the Round again (same seed = the same rack) and resets its shots, points and clock. Host, Round live.
func rerack(same_seed := true) -> bool:
	if game_loop == null or game_loop.phase != GameLoop.Phase.ROUND_LIVE:
		_say("no Round is live: press GO LIVE first")
		return false
	if not _can_edit_table():
		return false
	var config := game_loop.current_night()
	if not same_seed:
		game_loop.round_seed = hash([game_loop.round_seed, Time.get_ticks_usec()])
	game_loop.round_points = 0
	game_loop.shots_left = config.shots_per_round
	game_loop.time_left = config.round_time_limit_sec
	director.ball_overrides = economy.ball_overrides()
	director.start_round(economy.round_config(config), game_loop.round_index, game_loop.round_seed)
	game_loop.state_changed.emit()
	_say("Round re-racked (%s seed)" % ("same" if same_seed else "new"))
	changed.emit()
	return true


# ---------------------------------------------------------------- game

func advance() -> void:
	if game_loop != null and is_host():
		game_loop.advance()
		_say("advanced: %s" % GameLoop.Phase.keys()[game_loop.phase])
		changed.emit()


func add_cash(amount: int) -> void:
	if economy != null and is_host():
		economy.add_cash(amount, &"debug")
		_say("Cash %+d" % amount)


func add_shots(n: int) -> void:
	if game_loop != null and is_host():
		game_loop.shots_left = maxi(game_loop.shots_left + n, 0)
		game_loop.state_changed.emit()


func add_time(seconds: float) -> void:
	if game_loop != null and is_host():
		game_loop.time_left = maxf(game_loop.time_left + seconds, 0.0)
		game_loop.state_changed.emit()


## Applies a Drink's or an Event's Effects to the host (and every peer, through EffectManager.apply).
func apply_effects(list: Array[Effect], label: String) -> void:
	if effects == null or not is_host():
		return
	for e in list:
		effects.apply(e.id, multiplayer.get_unique_id(), multiplayer.get_unique_id())
	_say("applied %s" % label)
