class_name LoadingScreen
extends CanvasLayer
## Start-to-bar overlay (docs/plan/04 §4). NetManager adds it to the tree root at start_session, so it outlives the
## scene change, and it ends itself once the local player stands in the bar. Every stage names what it waits for:
## LOADING (the loader's %), BUILDING (MainLevel._ready), WAITING (the host's barrier: players N/M, who is still loading).

signal cancelled
signal finished

enum Stage { LOADING, BUILDING, WAITING }

const LOAD_SHARE := 0.8  ## of the bar the loader's own progress fills; BUILDING and WAITING sit past it
const MIRROR_WAIT_S := 4.0  ## the longest it holds the overlay for the wall mirror's room capture

var stage := Stage.LOADING
var _progress := 0.0
var _elapsed := 0.0
var _done := PackedInt32Array()
var _roster: Array[Dictionary] = []
var _mirror_wait := 0.0

@onready var _stage: Label = %Stage
@onready var _bar: ProgressBar = %Bar
@onready var _detail: Label = %Detail
@onready var _cancel: Button = %Cancel


func _ready() -> void:
	_cancel.pressed.connect(cancelled.emit)
	_bar.add_theme_stylebox_override(&"background", _box(Color(0.25, 0.17, 0.12)))  # the project theme draws no ProgressBar
	_bar.add_theme_stylebox_override(&"fill", _box(Color(0.89, 0.67, 0.25)))
	_refresh()


func _process(delta: float) -> void:
	_elapsed += delta
	if stage == Stage.WAITING and _player_stands() and _mirror_done(delta):
		finished.emit()
		queue_free()
		return
	_refresh()


func set_stage(s: Stage) -> void:
	stage = s
	_refresh()


func set_progress(fraction: float) -> void:
	_progress = clampf(fraction, 0.0, 1.0)
	_refresh()


func set_players(done: PackedInt32Array, roster: Array[Dictionary]) -> void:
	_done = done
	_roster = roster
	_refresh()


static func _box(color: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(6)
	return b


## The local PlayerSlot has replicated into the new MainLevel: the bar is playable.
func _player_stands() -> bool:
	var scene := get_tree().current_scene
	var spawner := scene.get_node_or_null(^"PlayerSpawner") if scene != null else null
	return spawner != null and spawner.call(&"get_local_player") != null


## The wall mirror's room capture (six GPU readbacks, a hitch each) ends under this overlay and not on the intro's first frames
## (adhoc-1014b S5). A capture that never ends (no renderer, a lost device) holds the overlay MIRROR_WAIT_S at most.
func _mirror_done(delta: float) -> bool:
	var mirror := get_tree().get_first_node_in_group(&"mirror")
	if mirror == null or bool(mirror.get(&"is_captured")):
		return true
	_mirror_wait += delta
	return _mirror_wait >= MIRROR_WAIT_S


func _refresh() -> void:
	if not is_node_ready():
		return
	var secs := "%d s" % int(_elapsed)
	if _mirror_wait > 0.0:
		_stage.text = "Polishing the mirror…"
		_bar.value = 0.95
		_detail.text = secs
		return
	match stage:
		Stage.LOADING:
			_stage.text = "Loading the bar… %d%%" % int(_progress * 100.0)
			_bar.value = _progress * LOAD_SHARE
			_detail.text = secs
		Stage.BUILDING:
			_stage.text = "Building the room…"
			_bar.value = 0.9
			_detail.text = secs
		Stage.WAITING:
			var total := maxi(_roster.size(), 1)
			_stage.text = "Waiting for players %d/%d" % [mini(_done.size(), total), total]
			_bar.value = 0.9 + 0.1 * float(_done.size()) / float(total)
			var names := PackedStringArray()
			for e in _roster:
				if not _done.has(e.peer_id):
					names.append(e.name)
			_detail.text = "%s · %s" % ["Still loading: " + ", ".join(names) if not names.is_empty() else "Everyone is in", secs]
