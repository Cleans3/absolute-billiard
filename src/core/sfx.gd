extends Node
## Sound service (docs/plan/07 §8, 06 P54): the one autoload that turns what the game already says into sound. Nothing else calls it
## except the slot machine and the jukebox, which are this feature's own files. It finds its sources with `SceneTree.node_added`:
## `ImpactFx.fx_fired` (every table sound, on the host at the real moment and on a client at the ball's playback tick, never a host
## Jolt contact), `WorldInteractions.interaction_applied`, `EconomyManager.cash_changed`, every `BaseButton` press, and the staging
## props (polled: they have no start signal). Two pools of players (2D for UI, 3D for the room) on the SFX bus; the Music bus is the
## jukebox's. The sound list with its signals is docs/plan/07 §8.
## A leaf script on purpose (it names no gameplay class): sources are matched by their script's class_name and talked to dynamically, so
## the autoload compiles at boot without pulling the whole game in behind it. The slot machine and the jukebox reach it BY PATH
## (`/root/Sfx`): a script that names an autoload does not compile under a `-s` probe, which compiles those two before any autoload exists.

const DIR := "res://assets/audio/sfx/"
const POOL_UI := 6
const POOL_3D := 14
const DUCK_DB := -10.0
const HARD_MPS := 8.0   ## ImpactFx.HARD_MPS: an impact at this speed or more is full volume
const HOVER_M := 1.45   ## RoundStaging.HOVER_ABOVE_BED: where the saucer hangs over the cloth
## Table sounds: the hardness layer by impact strength (0..1 of HARD_MPS), and the dB floor of the quietest audible hit.
const SOFT_BELOW := 0.25
const MED_BELOW := 0.6
const FLOOR_DB := -26.0
const SOURCES: Array[StringName] = [&"ImpactFx", &"WorldInteractions", &"EconomyManager", &"RoundStaging", &"Trapdoor"]  ## script class_names hooked at node_added
## Interaction kind -> [sound, dB, pitch]; kinds not listed make no sound here (the jukebox and the slot play their own).
const PROP_SOUND := {
	&"go_live": [&"ready_on", -2.0, 1.0],
	&"bump_table": [&"bump", -2.0, 1.0],
	&"kick_stool": [&"kick", -2.0, 1.0],
	&"flick_lights": [&"ui_switch", 0.0, 0.9],
	&"chalk_the_cue": [&"chalk", -2.0, 1.0],
	&"heckle": [&"lose", -9.0, 1.25],
	&"lean_on_rail": [&"lean", -6.0, 1.0],
	&"cue_rack": [&"rail_b", -10.0, 1.3],  # a cue knocks out of / into its slot (08 §2.9)
	&"throw_drink": [&"glass", -2.0, 1.0],
	&"bar_buy": [&"glass", -6.0, 1.0],
	&"bar_serve": [&"glass", -6.0, 1.0],
}

var stats := {}   ## sound name -> times played since boot (probes)

var _cache := {}
var _ui: Array[AudioStreamPlayer] = []
var _room: Array[AudioStreamPlayer3D] = []
var _next_ui := 0
var _next_room := 0
var _duck: Tween
var _staging: Node   ## MainLevel/Staging (RoundStaging)
var _stage_kind := &""
var _stage_t := -1.0
var _trapdoor: Node3D   ## MainLevel/Trapdoor
var _trap_open := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL_UI:
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		add_child(p)
		_ui.append(p)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = &"SFX"
		p.unit_size = 6.0
		p.max_distance = 40.0
		add_child(p)
		_room.append(p)
	for sound: StringName in [&"cue_tip", &"clack_soft_a", &"clack_soft_b", &"clack_med_a", &"clack_med_b", &"clack_hard_a", &"clack_hard_b", &"rail_a", &"rail_b", &"pocket_drop", &"ui_click_a"]:
		stream(sound)  # warm the break's sounds: the first load must not land mid-shot
	Settings.apply_audio()
	get_tree().node_added.connect(_on_node_added)


## The sound `name` (assets/audio/sfx/<name>.ogg), cached; null and one warning when the file is missing.
func stream(sound: StringName) -> AudioStream:
	if not _cache.has(sound):
		var path := DIR + String(sound) + ".ogg"
		if not ResourceLoader.exists(path):
			push_warning("Sfx: no sound '%s'" % sound)
			_cache[sound] = null
		else:
			_cache[sound] = load(path)
	return _cache[sound]


## A 2D sound (UI, stings). Returns the player so a caller may stop a loop.
func play(sound: StringName, db := 0.0, pitch := 1.0) -> AudioStreamPlayer:
	var s := stream(sound)
	if s == null:
		return null
	var p := _ui[_next_ui]
	_next_ui = (_next_ui + 1) % POOL_UI
	_start(p, sound, s, db, pitch)
	return p


## A sound in the room at `at` (world position).
func play_at(sound: StringName, at: Vector3, db := 0.0, pitch := 1.0) -> AudioStreamPlayer3D:
	var s := stream(sound)
	if s == null:
		return null
	var p := _room[_next_room]
	_next_room = (_next_room + 1) % POOL_3D
	p.global_position = at
	_start(p, sound, s, db, pitch)
	return p


func _start(p: Node, sound: StringName, s: AudioStream, db: float, pitch: float) -> void:
	stats[sound] = int(stats.get(sound, 0)) + 1
	p.stream = s
	p.volume_db = db
	p.pitch_scale = pitch
	p.play()


## Lowers the Music bus for `sec` and eases it back (a jackpot should be heard over the jukebox).
func duck(sec := 2.5, db := DUCK_DB) -> void:
	if _duck != null:
		_duck.kill()
	_duck = create_tween()
	_duck.tween_method(_set_duck, Settings.music_duck_db, db, 0.12)
	_duck.tween_interval(sec)
	_duck.tween_method(_set_duck, db, 0.0, 0.8)


func _set_duck(db: float) -> void:
	Settings.music_duck_db = db
	Settings.apply_audio()


# --- sources -----------------------------------------------------------------------------------------------------------

func _on_node_added(n: Node) -> void:
	if n is BaseButton:
		_hook_button(n)
	elif n is AudioStreamPlayer or n is AudioStreamPlayer3D or n is AudioStreamPlayer2D:
		if n.get(&"bus") == &"Master":
			n.set(&"bus", &"SFX")  # the cutscene, phone and bartender sounds that predate the buses: the Effects row covers them
	else:
		var kind := _class_of(n)
		if not SOURCES.has(kind) or n.has_meta(&"sfx"):  # (a node that leaves and re-enters the tree is hooked once)
			return
		n.set_meta(&"sfx", true)
		match kind:
			&"ImpactFx":
				n.connect(&"fx_fired", _on_fx.bind(n))
			&"WorldInteractions":
				n.connect(&"interaction_applied", _on_interaction)
			&"EconomyManager":
				n.connect(&"cash_changed", _on_cash)
			&"RoundStaging":
				_staging = n
			&"Trapdoor":
				_trapdoor = n
				_trap_open = false


static func _class_of(n: Node) -> StringName:
	var script := n.get_script() as Script
	return script.get_global_name() if script != null else &""


func _hook_button(b: BaseButton) -> void:
	if b.has_meta(&"sfx") or _is_debug(b):
		return
	b.set_meta(&"sfx", true)
	b.pressed.connect(_on_tap.bind(b))


func _is_debug(n: Node) -> bool:
	while n != null:
		var c := _class_of(n)
		if c == &"DebugPanel" or c == &"DebugStrip":
			return true
		n = n.get_parent()
	return false


func _on_tap(b: BaseButton) -> void:
	if b.theme_type_variation == &"PrimaryButton":
		play(&"ui_confirm", -6.0)
	else:
		play(&"ui_click_a" if randf() < 0.5 else &"ui_click_b", -4.0, randf_range(0.96, 1.04))


## ImpactFx kinds (impact_fx.gd `_fire`): the table's sounds sit at the table centre (the event carries no position).
func _on_fx(kind: StringName, strength: float, fx: Node) -> void:
	var spot := Vector3.ZERO
	var table: Node3D = fx.get(&"table")
	if table != null:
		spot = table.to_global(Vector3(0.0, table.call(&"cloth_y"), 0.0))
	if table_sound(kind, strength, spot):
		return
	match kind:
		&"scratch":
			play_at(&"pocket_drop", spot, -3.0)
			play(&"ui_error", -6.0, 0.75)
		&"penalty":
			play_at(&"pocket_drop", spot, -3.0)
			play(&"ui_error", -4.0, 1.0)
		&"trick":
			play(&"trick", -5.0)
		&"trick_minor":
			play(&"trick_minor", -6.0)
		&"jackpot":
			play(&"jackpot", -6.0)
			duck()
		&"cleared":
			play(&"fanfare", -4.0)
			duck()
		&"hazard":
			play(&"hazard", -5.0)
		&"drink":
			play(&"drink", -4.0)
		&"go":
			play(&"go", -4.0)
		&"time":
			play(&"time_up", -5.0)
		&"lost":
			play(&"lost", -8.0)


## The sound of one table event (`kick` = cue strike, `ball`, `rail`, `pot`) at `at`, every pitch times `pitch_mult`; false for any
## other kind. `_on_fx` plays the live ones; the instant replay (docs/plan/10 §3.7) plays a Shot's recorded ones again, slowed.
func table_sound(kind: StringName, strength: float, at: Vector3, pitch_mult := 1.0) -> bool:
	var t := clampf(strength / HARD_MPS, 0.0, 1.0)
	match kind:
		&"kick":
			play_at(&"cue_tip", at, lerpf(-12.0, 0.0, t), randf_range(0.96, 1.04) * pitch_mult)
		&"ball":
			var layer := "soft" if t < SOFT_BELOW else ("med" if t < MED_BELOW else "hard")
			play_at(StringName("clack_%s_%s" % [layer, "a" if randf() < 0.5 else "b"]), at, lerpf(FLOOR_DB, -1.0, pow(t, 0.6)), randf_range(0.95, 1.06) * pitch_mult)
		&"rail":
			play_at(&"rail_a" if randf() < 0.5 else &"rail_b", at, lerpf(FLOOR_DB, -2.0, pow(t, 0.6)), randf_range(0.95, 1.06) * pitch_mult)
		&"pot":
			play_at(&"pocket_drop", at, -3.0, randf_range(0.95, 1.05) * pitch_mult)
			play(&"ding", -9.0, minf(1.0 + 0.09 * maxf(strength - 1.0, 0.0), 2.0) * pitch_mult)  # strength = the combo count: a rising ding
		_:
			return false
	return true


func _on_interaction(_peer: int, kind: StringName, _target: int, _payload: Dictionary) -> void:
	if not PROP_SOUND.has(kind):
		return
	var row: Array = PROP_SOUND[kind]
	var at := _prop_at(kind)
	if at.is_finite():
		play_at(row[0], at, row[1], row[2])
	else:
		play(row[0], row[1], row[2])


func _prop_at(kind: StringName) -> Vector3:
	for n: Node3D in get_tree().get_nodes_in_group(&"interactable"):
		if n.call(&"effective_kind") == kind:
			return n.global_position
	return Vector3.INF


func _on_cash(_balance: int, delta: int, reason: StringName) -> void:
	if delta < 0 and (reason == &"shop" or reason == &"throw_drink" or reason == &"cue"):
		play(&"register", -5.0)
	elif delta > 0 and (reason == &"shot" or reason == &"tip" or reason == &"world"):
		play(&"coin", -6.0, clampf(0.85 + log(float(delta)) / log(10.0) * 0.1, 0.85, 1.4))


# --- staging props: no start signal, so the plan's own constants are read against the running clock ----------------------------

func _process(_delta: float) -> void:
	if is_instance_valid(_staging):
		_stage_step()
	if is_instance_valid(_trapdoor) and bool(_trapdoor.get(&"is_open")) != _trap_open:
		_trap_open = not _trap_open
		play_at(&"trap_open" if _trap_open else &"trap_close", _trapdoor.global_position, -3.0)


static func _crossed(from: float, to: float, at: float) -> bool:
	return from < at and at <= to


func _stage_step() -> void:
	var kind: StringName = _staging.get(&"kind")
	if kind != _stage_kind:
		_stage_kind = kind
		_stage_t = -1.0
	var table: Node3D = _staging.get(&"table")
	if kind == &"" or table == null:
		return
	var from := _stage_t
	var to: float = _staging.get(&"elapsed")
	_stage_t = to
	var cloth: float = table.call(&"cloth_y")
	var over := table.to_global(Vector3(0.0, cloth + HOVER_M, 0.0))
	if kind == &"setup":
		var vent: Node3D = _staging.get(&"vent")
		var mouth := vent.global_position if vent != null else over
		var n: int = (_staging.get(&"_balls") as Array).size()  # ponytail: a private read; the ball count is the plan's only other input
		if _crossed(from, to, 0.0):
			play_at(&"vent_open", mouth, -4.0)
		if _crossed(from, to, StagingPlan.UFO_OUT_FROM):
			play_at(&"ufo_whoosh", mouth, -6.0)
		if _crossed(from, to, StagingPlan.VENT_CLOSE_AT):
			play_at(&"vent_close", mouth, -4.0)
		for i in n:
			if _crossed(from, to, StagingPlan.reveal_start(i, n)):
				play_at(&"beam_blip", over, -9.0, 0.8 + 0.7 * float(i) / maxf(float(n - 1), 1.0))
		if _crossed(from, to, StagingPlan.last_in(n)):
			play_at(&"ufo_farewell", over, -6.0)
	else:
		var pit := table.to_global(Vector3(0.0, cloth, 0.0))
		if _crossed(from, to, StagingPlan.OPEN_AT):
			play_at(&"flap_open", pit, -3.0)
		if _crossed(from, to, StagingPlan.SHUT_AT):
			play_at(&"flap_shut", pit, -3.0)
