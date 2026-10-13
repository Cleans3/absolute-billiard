class_name Cutscene
extends Node3D
## Base of every cutscene (docs/plan/09 §4.4, 06 P39, adhoc-1013c D13): LOCAL presentation, nothing here is networked. Playing one
## makes its own Camera3D the viewport's current one, opens a CutsceneShell (a modal at priority 100, so
## `UIRouter.blocking()` holds the game's input; a Skip button; a fade), builds its geometry, runs a timeline that is a pure function of the time `t` and of
## `cut_seed`, then restores the camera that was current and emits `finished(skipped)`. It frees nothing of the level.
##
## A subclass overrides `id()`, `length_sec()` (0 = open-ended, ends only on `finish()`), `_build()` (the geometry, in this node's
## space; runs once, in the tree), `_update(time, dt)` (pose everything for `time`; never accumulate state, so a step of any size or a
## seek gives the same picture), optionally `_environment()` and `_fade_at()`. No DirectionalLight: it would light the whole level.
## Where it plays: far from the room (`STAGE_ORIGIN`, set by CutscenePlayer) unless `on_stage` is false (FallCam plays in the room).

signal finished(skipped: bool)  ## once, when it ends: the timeline ran out, Skip, finish(), or abort()

const STAGE_ORIGIN := Vector3(500.0, 0.0, 500.0)  ## outside every room volume, so the room's lights and probes never reach a cutscene
const HIDE_GROUP := &"cutscene_hides"  ## HUD roots in this group are hidden while a cutscene plays, restored after (F3b tags them)
const MAX_CREW := 4
const MAX_STEP_SEC := 0.1  ## a hitch longer than this does not skip the choreography

var cut_seed := 0  ## every random choice comes from `rng`, seeded from this: same seed, same picture on every peer
var crew_size := 4  ## Humanoids in the scene, 1-4: the roster size
var crew_skins: Array[CharacterSkin] = []  ## one per seat; a missing one falls back to the seat's colour
var on_stage := true
var skippable := true
var manual_clock := false  ## true: only step() advances it (probes, the preview tool)
var fade_in := 0.25  ## seconds from black at the start
var fade_out := 0.25  ## seconds to black at the end (only when length_sec() > 0)
var t := 0.0
var playing := false
var camera: Camera3D
var shell: CutsceneShell
var rng := RandomNumberGenerator.new()

var _layer: CanvasLayer
var _prev_camera: Camera3D
var _hidden: Array[CanvasItem] = []


# --- what a subclass fills in ---------------------------------------------------------------------------------------------------

func id() -> StringName:
	return &""


func length_sec() -> float:
	return 0.0


func _build() -> void:
	pass


func _update(_time: float, _dt: float) -> void:
	pass


## The scene's own Environment (set on the camera, so the level's WorldEnvironment is untouched), or null to keep the level's.
func _environment() -> Environment:
	return null


## 0 = clear, 1 = black, at `time`.
func _fade_at(time: float) -> float:
	var a := 0.0
	if fade_in > 0.0:
		a = maxf(a, 1.0 - clampf(time / fade_in, 0.0, 1.0))
	var total := length_sec()
	if fade_out > 0.0 and total > 0.0:
		a = maxf(a, clampf((time - (total - fade_out)) / fade_out, 0.0, 1.0))
	return a


## Common options (CutscenePlayer.play passes the whole dictionary); a subclass reads its own keys after super().
func configure(opts: Dictionary) -> void:
	cut_seed = int(opts.get("seed", cut_seed))
	crew_size = clampi(int(opts.get("crew_size", crew_size)), 1, MAX_CREW)
	var skins: Variant = opts.get("skins", null)
	if skins is Array:
		crew_skins.clear()
		for s: Variant in skins:
			crew_skins.append(s as CharacterSkin)
	skippable = bool(opts.get("skippable", skippable))
	manual_clock = bool(opts.get("manual", manual_clock))


# --- lifecycle ------------------------------------------------------------------------------------------------------------------

func _ready() -> void:
	set_process(false)  # a script that overrides _process is enabled at READY; nothing runs until play()


func _process(delta: float) -> void:
	step(minf(delta, MAX_STEP_SEC))


## Builds the scene, takes the camera, opens the shell and starts the clock. The node must already be in the tree.
func play() -> void:
	if playing:
		return
	if not is_inside_tree():
		push_error("Cutscene.play(): add the cutscene to the tree first")
		return
	rng.seed = cut_seed
	t = 0.0
	camera = Camera3D.new()
	camera.name = "CutsceneCamera"
	camera.environment = _environment()
	add_child(camera)
	_prev_camera = get_viewport().get_camera_3d()
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)
	shell = CutsceneShell.new()
	_layer.add_child(shell)
	shell.skip_button.visible = skippable
	shell.skip_requested.connect(skip)
	shell.open()
	_build()  # after the shell exists: a scene may put a card in shell.dock
	camera.make_current()
	_hide_hud()
	playing = true
	_update(0.0, 0.0)
	shell.set_fade(_fade_at(0.0))
	set_process(not manual_clock)


## Advances the clock by `dt` seconds (the engine does this every frame unless `manual_clock`).
func step(dt: float) -> void:
	if not playing:
		return
	t += dt
	_update(t, dt)
	shell.set_fade(_fade_at(t))
	var total := length_sec()
	if total > 0.0 and t >= total:
		_end(false)


## The Skip button, Esc, or code: ends it now when it may be skipped.
func skip() -> void:
	if playing and skippable:
		_end(true)


## Ends it now whatever `skippable` says (a peer that came back from the background, the level being torn down). Reports skipped.
func abort() -> void:
	_end(true)


## An open-ended cutscene ends itself with this (TruckOutro's Continue button).
func finish() -> void:
	_end(false)


func caption_line(text: String) -> void:
	if shell != null:
		shell.show_caption(text)


func clear_caption() -> void:
	if shell != null:
		shell.hide_caption()


func _end(skipped: bool) -> void:
	if not playing:
		return
	playing = false
	set_process(false)
	_restore_camera()
	_restore_hud()
	if shell != null and is_instance_valid(shell):
		shell.close()  # hides it, so UIRouter releases the game's input
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	finished.emit(skipped)


func _restore_camera() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	if _prev_camera != null and is_instance_valid(_prev_camera) and _prev_camera.is_inside_tree():
		_prev_camera.make_current()
	else:
		camera.clear_current()


func _hide_hud() -> void:
	for n in get_tree().get_nodes_in_group(HIDE_GROUP):
		var item := n as CanvasItem
		if item != null and item.visible:
			_hidden.append(item)
			item.hide()


func _restore_hud() -> void:
	for item in _hidden:
		if is_instance_valid(item):
			item.show()
	_hidden.clear()
