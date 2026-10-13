class_name JukeboxPlayer
extends Node3D
## The bar's music (docs/plan/07 §8, 06 P55): four CC0 electronic tracks played in turn from the first Round on, the same sample on every
## peer. The host holds the state (track + where in it we are); a state is `(track, offset)` and the playhead after it is pure arithmetic on
## the track lengths, so only a start, a skip and a (re)join ever cross the network. One AudioStreamPlayer3D at the jukebox plus a quiet
## 2D floor so the whole room has music; both on the Music bus. Quiet during the story beats (NIGHT_START) and the endings.

signal track_changed(index: int)

const TRACKS: Array[Dictionary] = [
	{path = "res://assets/audio/music/technomania101.ogg", title = "Technomania101", by = "Fupi"},
	{path = "res://assets/audio/music/slampe_synthwave_house.ogg", title = "Synthwave House", by = "Fupi"},
	{path = "res://assets/audio/music/cool_city.ogg", title = "Cool City", by = "MintoDog"},
	{path = "res://assets/audio/music/neon_hyperdrive.ogg", title = "Neon Hyperdrive", by = "Adiutorium"},
]
const SKIP_COOLDOWN_MSEC := 3000
const AUDIBLE: Array[int] = [GameLoop.Phase.INTERMISSION, GameLoop.Phase.ROUND_SETUP, GameLoop.Phase.ROUND_LIVE, GameLoop.Phase.ROUND_END, GameLoop.Phase.RECKONING]
const NEAR_DB := 2.0
const FLOOR_DB := -20.0
const FADE_SEC := 0.8
const DRIFT_SEC := 0.6       ## a player this far from the clock is re-seeked (output latency alone is under this) ...
const RESEEK_GAP_MSEC := 3000  ## ... and never more than once in this long, so a slow device cannot make it stutter
const REACH_SLACK_M := 0.5  ## the host's reach check allows a step more than the prompt did: the player kept walking

@export var game_loop: GameLoop
@export var world: WorldInteractions

## -1 until the host starts the music (first Round-time phase); then the index of the track the room is on.
var track := -1

var _t0 := 0                 ## local clock (msec) at which `track` was at 0.0 s
var _streams: Array[AudioStream] = []
var _near: AudioStreamPlayer3D
var _floor: AudioStreamPlayer
var _gain := 0.0             ## 0..1, eased: the fade in and out of the audible phases
var _next_skip_msec := 0     ## host: the 3 s gate
var _next_press_msec := 0    ## this peer: the same gate, for responsiveness
var _next_reseek_msec := 0
var _shown := -1
var _asked := false


func _ready() -> void:
	add_to_group(&"jukebox")
	for t in TRACKS:
		_streams.append(load(t.path))
	_near = AudioStreamPlayer3D.new()
	_near.bus = &"Music"
	_near.unit_size = 3.5
	_near.max_distance = 0.0
	_near.volume_db = NEAR_DB
	_near.finished.connect(_sync)
	add_child(_near)
	_floor = AudioStreamPlayer.new()
	_floor.bus = &"Music"
	_floor.volume_db = FLOOR_DB
	add_child(_floor)
	if game_loop != null:
		game_loop.phase_changed.connect(_on_phase)
		if multiplayer.is_server():  # a client asks on its first phase: the host's own MainLevel may not exist yet at its _ready
			_on_phase(game_loop.phase)
	var net := get_node_or_null(^"/root/NetManager")
	if net != null and net.has_signal(&"app_resumed"):
		net.connect(&"app_resumed", _ask_host)


## What the room hears now: the track and the second in it, advancing past the end of a track into the next.
func playhead() -> Dictionary:
	var t := track
	var off := float(Time.get_ticks_msec() - _t0) / 1000.0
	if t < 0:
		return {track = -1, offset = 0.0}
	for _i in TRACKS.size() * 4:  # a state older than a few laps is a bug, not a loop
		var len := _streams[t].get_length()
		if off < len:
			break
		off -= len
		t = (t + 1) % TRACKS.size()
	return {track = t, offset = maxf(off, 0.0)}


# --- the press: the existing hype interaction stays, and any press also skips (free, 3 s) -----------------------------------

## The local player used the jukebox. The host validates; a client asks.
func press() -> void:
	var now := Time.get_ticks_msec()
	if now < _next_press_msec:
		return
	_next_press_msec = now + SKIP_COOLDOWN_MSEC
	if multiplayer.is_server():
		skip(multiplayer.get_unique_id())
	else:
		request_jukebox_skip.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable", 3)
func request_jukebox_skip() -> void:
	if multiplayer.is_server():
		skip(multiplayer.get_remote_sender_id())


## Host: `peer_id` asked for the next track. Refused (silently: a press is free) when the music has not started, the gate is shut,
## or they are out of reach of the jukebox.
func skip(peer_id: int) -> bool:
	var now := Time.get_ticks_msec()
	if track < 0 or now < _next_skip_msec or not _in_reach(peer_id):
		return false
	_next_skip_msec = now + SKIP_COOLDOWN_MSEC
	jukebox_state.rpc((int(playhead().track) + 1) % TRACKS.size(), 0.0)
	return true


func _in_reach(peer_id: int) -> bool:
	if world == null:
		return true
	var at := global_position
	for n in get_tree().get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"jukebox":
			at = (n as Interactable).global_position
	var pos: Vector3 = world.player_position_source.call(peer_id)
	return pos.is_finite() and pos.distance_to(at) <= WorldInteractions.REACH_M + REACH_SLACK_M


## Host -> everyone: the room is on `p_track` at `offset_sec` (-1 = not started). Called on the start, on every skip, and as the
## answer to a (re)join; a bad frame changes nothing.
@rpc("authority", "call_local", "reliable", 3)
func jukebox_state(p_track: int, offset_sec: float) -> void:
	if p_track < -1 or p_track >= TRACKS.size() or not is_finite(offset_sec) or offset_sec < 0.0:
		return
	var skipped := track >= 0 and p_track != track
	track = p_track
	_t0 = Time.get_ticks_msec() - int(offset_sec * 1000.0)
	_next_reseek_msec = 0  # a frame from the host is the truth: follow it now, whatever the last seek was
	if skipped:
		var sfx := get_node_or_null(^"/root/Sfx")  # by path: a script that names an autoload does not compile under a `-s` probe
		if sfx != null:
			sfx.call(&"play", &"ui_switch", -2.0)
	_sync()


## A client asks where the music is (first phase it sees, back from the background); the host answers that peer only.
@rpc("any_peer", "call_remote", "reliable", 3)
func request_jukebox_state() -> void:
	if multiplayer.is_server():
		var p := playhead()
		jukebox_state.rpc_id(multiplayer.get_remote_sender_id(), p.track, p.offset)


func _ask_host() -> void:
	if not multiplayer.is_server():
		request_jukebox_state.rpc_id(1)


func _on_phase(_p: int) -> void:
	if multiplayer.is_server():
		if track < 0 and _audible():
			jukebox_state.rpc(randi() % TRACKS.size(), 0.0)
	elif not _asked:
		_asked = true
		_ask_host()


func _audible() -> bool:
	return game_loop == null or AUDIBLE.has(int(game_loop.phase))


# --- playback -----------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	var want := track >= 0 and _audible()
	_gain = move_toward(_gain, 1.0 if want else 0.0, delta / FADE_SEC)
	_near.volume_db = NEAR_DB + linear_to_db(maxf(_gain, 0.0001))
	_floor.volume_db = FLOOR_DB + linear_to_db(maxf(_gain, 0.0001))
	if _gain <= 0.0:
		if _near.playing:
			_near.stop()
			_floor.stop()
		return
	_sync()


## Put the players where the clock says: start the right track, or seek when they drifted.
func _sync() -> void:
	if track < 0 or not _audible():
		return
	var p := playhead()
	var stream := _streams[int(p.track)]
	var now := Time.get_ticks_msec()
	var drifted := now >= _next_reseek_msec and absf(_near.get_playback_position() - float(p.offset)) > DRIFT_SEC
	if _near.stream != stream or not _near.playing or drifted:
		_next_reseek_msec = now + RESEEK_GAP_MSEC
		_near.stream = stream
		_floor.stream = stream
		_near.play(float(p.offset))
		_floor.play(float(p.offset))
	if int(p.track) != _shown:
		_shown = int(p.track)
		track_changed.emit(_shown)
		if UIRouter.instance != null and _audible():
			UIRouter.instance.toast("Now playing: %s - %s" % [TRACKS[_shown].title, TRACKS[_shown].by])
