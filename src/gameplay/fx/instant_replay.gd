class_name InstantReplay
extends Node
## MainLevel/InstantReplay (docs/plan/10 §3.7): every peer records the Shot it draws (each ball's drawn position per frame, the scoring
## pots) and, when the Shot was worth it (a paid trick of tier >= 2, or the table cleared), plays it back full screen with a slow-motion
## close-up on the key pot (ReplayCut). Presentation only and local: nothing is sent, no real ball is moved, the live game never slows.
## A replay of a Round's last Shot holds that Round's clean-up until it ends (`holds_table`, RoundDirector.release_cleanup).

signal started
signal ended(skipped: bool)

const START_DELAY := 1.2      ## seconds after shot_ended: the trick banner reads first
const MIN_TIER := 2           ## FxCombo.trick_tier a trick needs (KickShot, Combo3, Carom, RailRunner)
const MAX_RECORD_SEC := 20.0
const MAX_FRAMES := 1500
const CLEARED_TITLE := "TABLE CLEARED!"
const PHASES := [GameLoop.Phase.ROUND_LIVE, GameLoop.Phase.ROUND_END, GameLoop.Phase.INTERMISSION]
const SOUND_KINDS: Array[StringName] = [&"kick", &"ball", &"rail", &"pot"]  ## the ImpactFx.fx_fired kinds that are table sounds (Sfx.table_sound)

## Off in a headless run (probes, tools), like RoundDirector.skip_staging; a probe that tests the replay turns it on.
static var enabled := DisplayServer.get_name() != "headless"

@export var round_director: RoundDirector
@export var table: Table
@export var game_loop: GameLoop

var recording := false
var cut: ReplayCut  ## the replay on screen, null when none

var _t0_usec := 0
var _times := PackedFloat32Array()
var _index := {}  # Ball -> track index
var _tracks: Array[PackedVector3Array] = []
var _shown: Array[PackedByteArray] = []
var _meshes: Array[Mesh] = []
var _layers := PackedInt32Array()
var _pots: Array[Dictionary] = []  # {t, track, pocket: StringName}, scoring pots in order
var _sounds: Array[Dictionary] = []  # {t, kind, strength}: the Shot's table sounds as this peer heard them (ImpactFx.fx_fired)
var _pending := -1.0  # seconds until a decided replay starts; < 0 = none
var _title := ""
var _hidden: Array[Ball] = []  # real balls this replay hid


func _ready() -> void:
	set_process(false)
	if table != null:
		table.sim.shot_started_net.connect(_on_shot_started)
	if round_director != null:
		round_director.ball_potted.connect(_on_potted)
		round_director.shot_ended.connect(_on_shot_ended)
		round_director.rack_ready.connect(func(_seed: int) -> void: cancel())
	if game_loop != null:
		game_loop.phase_changed.connect(_on_phase)
	var fx := get_node_or_null(^"../ImpactFx")  # absent where a probe builds no FX: the replay is silent
	if fx != null:
		fx.fx_fired.connect(_on_fx_fired)


## A replay is decided or on screen: the Round's clean-up must wait for it.
func holds_table() -> bool:
	return _pending >= 0.0 or is_playing()


func is_playing() -> bool:
	return cut != null and cut.playing


func frame_count() -> int:
	return _times.size()


func pot_count() -> int:
	return _pots.size()


func sound_count() -> int:
	return _sounds.size()


## Is a Shot worth a replay? Pure (the probe and _on_shot_ended share it).
static func qualifies(trick_ids: Array[StringName], scoring_pots: int, foul: bool, cleared: bool) -> bool:
	if foul or scoring_pots <= 0:
		return false
	return cleared or best_tier(trick_ids) >= MIN_TIER


static func best_tier(trick_ids: Array[StringName]) -> int:
	var best := 0
	for id in trick_ids:
		best = maxi(best, FxCombo.trick_tier(TrickShot.multiplier_for(id)))
	return best


## The highest-paying trick's banner title, else the clear's.
static func title_for(trick_ids: Array[StringName]) -> String:
	var best := &""
	for id in trick_ids:
		if best == &"" or TrickShot.multiplier_for(id) > TrickShot.multiplier_for(best):
			best = id
	return String(ImpactFx.TRICK_TITLES.get(best, CLEARED_TITLE)) if best != &"" else CLEARED_TITLE


## Stops a decided or playing replay now (the real balls come back, a held clean-up goes on).
func cancel() -> void:
	_pending = -1.0
	if is_playing():
		cut.abort()  # -> _on_cut_finished
	else:
		_release()


# --- recording ------------------------------------------------------------------------------------------------------------------

func _on_shot_started(_shot_id: int, _shooter_id: int, _base_tick: int) -> void:
	cancel()  # the next Shot: the screen belongs to the table again
	_times.clear()
	_index.clear()
	_tracks.clear()
	_shown.clear()
	_meshes.clear()
	_layers.clear()
	_pots.clear()
	_sounds.clear()
	_t0_usec = Time.get_ticks_usec()
	recording = enabled
	set_process(recording)


func _on_potted(ball: Ball, _shot_id: String, pocket_id: StringName) -> void:
	if not recording or ball == null or ball.is_cue_ball or round_director.value_of(ball.ball_type) <= 0:
		return
	_sample()  # the frame the pot is drawn on is in the recording
	_pots.append({t = _now(), track = _track_of(ball), pocket = pocket_id})


## ImpactFx fires on the host at the real moment and on a client at the playback tick: the time it is heard is the time it is drawn.
func _on_fx_fired(kind: StringName, strength: float) -> void:
	if recording and SOUND_KINDS.has(kind):
		_sounds.append({t = _now(), kind = kind, strength = strength})


func _now() -> float:
	return (Time.get_ticks_usec() - _t0_usec) / 1000000.0


func _process(delta: float) -> void:
	if recording:
		if _now() > MAX_RECORD_SEC or _times.size() >= MAX_FRAMES:
			recording = false
		else:
			_sample()
	if _pending >= 0.0:
		_pending -= delta
		if _pending < 0.0:
			_start()
	set_process(recording or _pending >= 0.0)


func _sample() -> void:
	var t := _now()
	if not _times.is_empty() and t <= _times[_times.size() - 1]:
		return
	_times.append(t)
	var n := _times.size()
	for b in round_director.get_balls():
		if not is_instance_valid(b):
			continue
		var i := _track_of(b)
		var tr := _tracks[i]
		var p := b.get_global_transform_interpolated().origin
		while tr.size() < n - 1:  # a ball that came into the Shot late (a split) was not there before
			tr.append(p)
			_shown[i].append(0)
		tr.append(p)
		_shown[i].append(1 if b.is_visible_in_tree() and not b.retired else 0)
		_tracks[i] = tr
	for i in _tracks.size():  # a ball that left the set (freed) holds its last place, hidden
		if _tracks[i].size() < n:
			var last := _tracks[i][_tracks[i].size() - 1] if not _tracks[i].is_empty() else Vector3.ZERO
			_tracks[i].append(last)
			_shown[i].append(0)


func _track_of(b: Ball) -> int:
	if _index.has(b):
		return _index[b]
	var i := _tracks.size()
	_index[b] = i
	_tracks.append(PackedVector3Array())
	_shown.append(PackedByteArray())
	var mi := b.get_node_or_null(^"Mesh") as MeshInstance3D
	_meshes.append(mi.mesh if mi != null else null)
	_layers.append(mi.layers if mi != null else 1)
	return i


# --- deciding and playing -------------------------------------------------------------------------------------------------------

func _on_shot_ended(_shot_id: String, _shooter_id: int, _raw_points: int, trick_ids: Array[StringName], foul: bool) -> void:
	if not recording and _times.is_empty():
		return
	if recording:
		_sample()
	recording = false
	if not enabled or not bool(Settings.value(&"instant_replay")) or not _phase_ok() or _times.size() < 2:
		return
	if not qualifies(trick_ids, _pots.size(), foul, round_director.is_table_cleared()):
		return
	_title = title_for(trick_ids)
	_pending = START_DELAY
	set_process(true)


func _phase_ok() -> bool:
	return game_loop == null or PHASES.has(game_loop.phase)


func _on_phase(_phase: int) -> void:
	if not _phase_ok():
		cancel()


func _start() -> void:
	_pending = -1.0
	var held := round_director.has_method(&"is_cleanup_held") and round_director.is_cleanup_held()
	if not _phase_ok() or UIRouter.blocking() or (round_director.staging and not held) or _pots.is_empty():
		_release()
		return
	var key: Dictionary = _pots[_pots.size() - 1]
	var key_t := minf(float(key.t), _times[_times.size() - 1])
	var pocket := _pocket_global(key.pocket, int(key.track), key_t)
	var cloth := table.to_global(Vector3(0.0, table.cloth_y(), 0.0))
	var xf := Transform3D(table.global_transform.basis, cloth)
	var half_w := table.spec.width_m * 0.5 * table.global_transform.basis.z.length()
	var plan := ReplayPlan.make(_times, _tracks, _shown, int(key.track), key_t, pocket, xf, half_w)
	if plan.length() <= 0.0:
		_release()
		return
	for b in round_director.get_balls():
		if is_instance_valid(b) and b.visible:
			b.visible = false
			_hidden.append(b)
	cut = ReplayCut.new()
	cut.name = "ReplayCut"
	cut.plan = plan
	cut.title = _title
	cut.meshes = _meshes.duplicate()
	cut.mesh_layers = _layers.duplicate()
	cut.sounds = _sounds.duplicate()
	cut.sound_at = cloth
	add_child(cut)
	cut.finished.connect(_on_cut_finished, CONNECT_ONE_SHOT)
	cut.play()
	started.emit()


## The key pocket's centre at cloth height; the key ball's place when the pot's pocket id is unknown.
func _pocket_global(pocket_id: StringName, track: int, at: float) -> Vector3:
	var y := table.cloth_y()
	if table.pockets.has(pocket_id):
		var p: Vector3 = table.pockets[pocket_id].position
		return table.to_global(Vector3(p.x, y, p.z))
	var tr := _tracks[track]
	var k := clampi(_times.bsearch(at, false) - 1, 0, tr.size() - 1)
	var q := table.to_local(tr[k])
	return table.to_global(Vector3(q.x, y, q.z))


func _on_cut_finished(skipped: bool) -> void:
	var c := cut
	cut = null
	if c != null and is_instance_valid(c):
		c.queue_free()
	_release()
	ended.emit(skipped)


## The real balls come back as they were and a held clean-up goes on.
func _release() -> void:
	for b in _hidden:
		if is_instance_valid(b):
			b.visible = true
	_hidden.clear()
	if round_director != null and round_director.has_method(&"release_cleanup"):
		round_director.release_cleanup()
