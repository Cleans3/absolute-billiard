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
## A STAGE part never draws the bar: every VisualInstance3D under it is on `STAGE_LAYER` and its camera sees only that layer, no farther
## than `STAGE_FAR` (adhoc-1014b C1). `prepare()` builds everything hidden and unopened, so CutscenePlayer can do it under black and the
## part's first shown frame builds and compiles nothing (C3); `play()` prepares when nobody did.

signal finished(skipped: bool)  ## once, when it ends: the timeline ran out, Skip, finish(), or abort()

const STAGE_ORIGIN := Vector3(500.0, 0.0, 500.0)  ## outside every room volume, so the room's lights and probes never reach a cutscene
const HIDE_GROUP := &"cutscene_hides"  ## HUD roots in this group are hidden while a cutscene plays, restored after (F3b tags them)
const PLAYING_GROUP := &"cutscene_playing"  ## a cutscene is in this group while it plays: whoever poses the crew's bodies leaves them alone
const MAX_CREW := 4
const MAX_STEP_SEC := 0.1  ## a hitch longer than this does not skip the choreography
const STAGE_LAYER := 1 << 15  ## render layer 16 (the bar and its mirror use 10-14 and 20): a stage part and its camera live on this one alone
const STAGE_FAR := 250.0  ## the stage camera's far plane: nothing a stage part builds is farther, and the bar (~700 m away) is never in range
const WARM_GROUP := &"viewport_warm"  ## nodes with `warm() -> bool` that draw their own SubViewports once on request (Mirror's window pass, StreamTv's feeds): the intro's black prepare asks
const HOLD_GROUP := &"cutscene_hold"  ## nodes with `cutscene_hold(on: bool, on_stage: bool)`: told when a cutscene takes the camera and when it gives it back

## Playback speed of every engine-driven cutscene clock (probes, the preview tool: 20 = a 6 s beat in 0.3 s). 1 in the game.
static var time_scale := 1.0
## How many cutscenes hold the camera right now (a counter: a cut goes 1, 0, 1 within one call). QualityManager and the Mirror stand down while it is above 0.
static var holding := 0

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
var prepared := false  ## built (hidden, shell unopened) and waiting for play()
var camera: Camera3D
var shell: CutsceneShell
var rng := RandomNumberGenerator.new()

var _layer: CanvasLayer
var _held := false  # counted in `holding`
var _prev_camera: Camera3D
var _hidden: Array[Node] = []  # CanvasItems and CanvasLayers in group HIDE_GROUP that were visible


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


func _exit_tree() -> void:
	_hold(false)  # a level freed mid-cutscene must not leave `holding` up


func _process(delta: float) -> void:
	step(minf(delta, MAX_STEP_SEC) * time_scale)


## One more (`on`) or one fewer cutscene owns the camera: counted in `holding`, and every node in HOLD_GROUP hears it. Never below 0.
## Receivers are idempotent: a cut calls off and on again back to back.
static func hold(tree: SceneTree, on: bool, stage: bool) -> void:
	holding = maxi(holding + (1 if on else -1), 0)
	if tree != null:
		tree.call_group(HOLD_GROUP, &"cutscene_hold", on, stage)


func _hold(on: bool) -> void:
	if on == _held:
		return
	_held = on
	hold(get_tree(), on, on_stage)


## Builds everything but shows nothing: the camera (not current), the shell (created, NOT opened: UIRouter keeps one modal at a priority, so
## opening it now would hide the cutscene on screen), `_build()` and, on a stage, the render-layer walk. A stage part stays hidden with its
## process off. play() calls it when nobody did; CutscenePlayer calls it under black before a stage part is due.
func prepare() -> void:
	if prepared:
		return
	if not is_inside_tree():
		push_error("Cutscene.prepare(): add the cutscene to the tree first")
		return
	prepared = true
	rng.seed = cut_seed
	t = 0.0
	if on_stage:
		visible = false  # before _build(): what it adds is born hidden
	camera = Camera3D.new()
	camera.name = "CutsceneCamera"
	camera.environment = _environment()
	add_child(camera)
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)
	shell = CutsceneShell.new()
	_layer.add_child(shell)
	shell.skip_button.visible = skippable
	shell.skip_requested.connect(skip)
	_build()  # the shell exists: a scene may put a card in shell.dock
	if on_stage:
		for n: Node in find_children("*", "VisualInstance3D", true, false):  # meshes, lights, labels, multimeshes: the camera culls by this
			(n as VisualInstance3D).layers = STAGE_LAYER
		camera.cull_mask = STAGE_LAYER
		camera.far = STAGE_FAR


## Poses the scene at `time` without playing it (the pose play() starts from is `pose_at(0.0)`): CutscenePlayer's warm draws.
func pose_at(time: float) -> void:
	_update(time, 0.0)


## The times a warm draw poses the scene at, the first one first. A light that comes on later in the timeline (a brake lamp, a door
## beam) is a pipeline the first frame it is lit: drawing the scene lit, under black, compiles it before the shot.
func warm_times() -> PackedFloat32Array:
	var total := length_sec()
	if total <= 0.0:
		return PackedFloat32Array([0.0, 3.0])
	return PackedFloat32Array([0.0, 0.15 * total, 0.4 * total, 0.7 * total, 0.95 * total])


## Takes the camera, opens the shell and starts the clock. The node must already be in the tree.
func play() -> void:
	if playing:
		return
	if not is_inside_tree():
		push_error("Cutscene.play(): add the cutscene to the tree first")
		return
	prepare()
	_prev_camera = get_viewport().get_camera_3d()
	visible = true
	shell.open()
	_hold(true)
	camera.make_current()
	_hide_hud()
	playing = true
	add_to_group(PLAYING_GROUP)
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


## A scene that changed the world (the in-room beats move the crew, work the door) puts it in its end state here; runs once, before
## the camera and the HUD come back, whether the timeline ran out, Skip was pressed or abort() was called.
func _on_end(_skipped: bool) -> void:
	pass


func _end(skipped: bool) -> void:
	if not playing:
		return
	playing = false
	remove_from_group(PLAYING_GROUP)
	set_process(false)
	_on_end(skipped)
	_hold(false)
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
		if (n is CanvasItem or n is CanvasLayer) and bool(n.get(&"visible")):  # TouchControls is a CanvasLayer
			_hidden.append(n)
			n.set(&"visible", false)


func _restore_hud() -> void:
	for n in _hidden:
		if is_instance_valid(n):
			n.set(&"visible", true)
	_hidden.clear()
