class_name ReplayCut
extends Cutscene
## The instant replay on screen (docs/plan/10 §3.7): a Cutscene in the room (no stage of its own) that draws one stand-in per recorded
## ball where `ReplayPlan` says it was, through its own camera, with letterbox bars, a REPLAY tag, SLOW-MO while slowed and the trick's
## title as the caption. Any key, click or tap skips it. It never touches a real ball: InstantReplay hides them and brings them back.

const FOV := 55.0
const BAR_FRACTION := 0.09   ## letterbox bar height, of the screen
const SKIP_AFTER_SEC := 0.3  ## a press this soon after the start is the end of the shot, not a skip
const TAG_FONT := 30
const SLOW_PITCH := 0.65     ## pitch of a table sound heard at ReplayPlan.SLOW (a real 0.3x would be a rumble), eased with the speed

var plan: ReplayPlan
var title := ""
var meshes: Array[Mesh] = []  ## one per track of `plan`
var mesh_layers := PackedInt32Array()
var sounds: Array[Dictionary] = []  ## {t, kind, strength} in recorded time, ascending: the Shot's table sounds (Sfx.table_sound)
var sound_at := Vector3.ZERO        ## where they are heard (Sfx puts the live ones at the cloth's centre too)
var sounds_played := 0              ## probes

var _heard_s := 0.0  # recorded time up to which the sounds have been played

var _ghosts: Array[MeshInstance3D] = []
var _slow_tag: Label
var _fx_hidden: Array[CanvasLayer] = []  # the FX banners and confetti (FxStage): read before the replay, off while it plays


func _init() -> void:
	on_stage = false
	fade_in = 0.2
	fade_out = 0.25


func id() -> StringName:
	return &"replay"


func length_sec() -> float:
	return plan.length() if plan != null else 0.0


func _build() -> void:
	camera.fov = FOV
	camera.cull_mask = StreamTv.FEED_MASK
	for i in meshes.size():
		var g := MeshInstance3D.new()
		g.name = "Ghost%d" % i
		g.mesh = meshes[i]
		g.layers = mesh_layers[i] if i < mesh_layers.size() else 1
		g.top_level = true
		add_child(g)
		_ghosts.append(g)
	_build_overlay()
	caption_line(title)
	_heard_s = plan.t0
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		if n is FxStage and n.visible:
			n.visible = false
			_fx_hidden.append(n)


func _on_end(_skipped: bool) -> void:
	for n in _fx_hidden:
		if is_instance_valid(n):
			n.visible = true
	_fx_hidden.clear()


func _update(time: float, _dt: float) -> void:
	if shell != null and not shell.visible:  # another modal displaced the shell: the screen is not ours any more
		abort.call_deferred()
		return
	var s := plan.source_time(time)
	for i in _ghosts.size():
		_ghosts[i].global_position = plan.position(i, s)
		_ghosts[i].visible = plan.visible(i, s)
	camera.global_transform = plan.camera(s)
	if _slow_tag != null:
		_slow_tag.visible = plan.is_slow(s)
	_play_sounds(s)


## Every recorded table sound in (last frame, `s`], at the pitch of the speed it is shown at; a seek backwards plays nothing.
func _play_sounds(s: float) -> void:
	if s < _heard_s:
		_heard_s = s
		return
	var sfx := get_node_or_null(^"/root/Sfx")  # by path: an autoload's name does not compile under a `-s` probe
	var slow := clampf((1.0 - plan.speed_at(s)) / (1.0 - ReplayPlan.SLOW), 0.0, 1.0)
	for e in sounds:
		var t: float = e.t
		if t <= _heard_s:
			continue
		if t > s:
			break
		sounds_played += 1
		if sfx != null:
			sfx.call(&"table_sound", e.kind, e.strength, sound_at, lerpf(1.0, SLOW_PITCH, slow))
	_heard_s = s


func _input(event: InputEvent) -> void:
	if not playing or t < SKIP_AFTER_SEC or event.is_echo():
		return
	if (event is InputEventKey or event is InputEventMouseButton or event is InputEventScreenTouch or event is InputEventJoypadButton) and event.is_pressed():
		get_viewport().set_input_as_handled()
		skip()


## The camera goes back only if it is still this replay's: a cutscene that took the screen keeps its own.
func _restore_camera() -> void:
	if camera != null and is_instance_valid(camera) and camera.is_current():
		super()


func _build_overlay() -> void:
	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_left = 0.0
		bar.anchor_right = 1.0
		bar.anchor_top = 0.0 if top else 1.0 - BAR_FRACTION
		bar.anchor_bottom = BAR_FRACTION if top else 1.0
		shell.add_child(bar)
		shell.move_child(bar, 0)  # under the fade, the caption and Skip
	var tag := _tag("● REPLAY", Color(1.0, 0.25, 0.25))
	tag.position = Vector2(28.0, 14.0)
	_slow_tag = _tag("SLOW-MO", Color(0.55, 0.9, 1.0))
	_slow_tag.position = Vector2(220.0, 14.0)
	_slow_tag.visible = false


func _tag(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override(&"font_size", TAG_FONT)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_constant_override(&"outline_size", 8)
	l.add_theme_color_override(&"font_outline_color", Color.BLACK)
	shell.add_child(l)
	return l
