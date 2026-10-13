class_name FallCam
extends Cutscene
## Quota failure, the fall (docs/plan/09 §3.8, 06 P39): the camera drops through the opened floor into the MonsterMouth, the crew
## tumbling beside it, the outer teeth snap shut overhead, the screen goes to black and holds, optionally with one caption line
## (the Night's `short_line`). It ENDS ON BLACK: the host's next screen (the run's stats card on black) must go up in the
## `played` handler, in the same frame. Plays IN the room (on_stage false) when given the Trapdoor's mouth; with no mouth (the preview
## tool, the probe) it builds a small demo shaft and a mouth of its own on the stage.
## Options: "mouth" (MonsterMouth in the Pit), "drop_height" (metres from the camera's start down to the mouth's lip), "caption".

const LENGTH_SEC := 4.2
const T_LIP := 1.6  ## the camera crosses the lip
const T_SHUT := 0.15  ## the teeth begin to close this long after
const T_BLACK_FROM := 2.2
const T_BLACK_TO := 2.9
const T_CAPTION := 3.1
const BELOW_LIP_ACCEL := 3.0
const FLOOR_Y := -5.0  ## the lowest the camera goes (it is black by then)
const SHAFT_HALF := 1.5

var mouth: MonsterMouth
var drop_height := 3.4
var caption_text := ""
var with_fallers := true  ## the rest of the crew tumbling beside the camera; off in the room (F3b tweens the real bodies)

var _demo := false
var _fallers: Array[Node3D] = []
var _hands_phase := PackedFloat32Array()


func id() -> StringName:
	return &"fall"


func length_sec() -> float:
	return LENGTH_SEC


func configure(opts: Dictionary) -> void:
	super(opts)
	mouth = opts.get("mouth", mouth) as MonsterMouth
	drop_height = float(opts.get("drop_height", drop_height))
	caption_text = str(opts.get("caption", caption_text))
	with_fallers = bool(opts.get("fallers", mouth == null))
	on_stage = mouth == null


func _environment() -> Environment:
	if mouth != null:
		return null  # in the room: the room's own look
	return CutsceneKit.night_env(Color.BLACK, Color(0.1, 0.07, 0.08), 1.0, Color(0.05, 0.02, 0.03), 0.02)


func _fade_at(time: float) -> float:
	return smoothstep(T_BLACK_FROM, T_BLACK_TO, time)


func _build() -> void:
	if mouth == null:
		_demo = true
		_build_demo()
	mouth.auto = false
	for i in 4:
		_hands_phase.append(rng.randf() * TAU)
	var others := crew_size - 1 if with_fallers else 0  # the camera is the local player; the rest fall beside it
	for i in others:
		var pivot := Node3D.new()
		pivot.name = "Faller%d" % i
		add_child(pivot)
		var h := CrewDress.spawn_one(pivot, i + 1, crew_skins[i + 1] if i + 1 < crew_skins.size() else null)
		h.position = Vector3(0.0, -0.95, 0.0)  # tumble about the middle of the body, not the feet
		_fallers.append(pivot)


## Preview / probe only: a floor with a square hole over a concrete shaft, the mouth at its foot. The lip is at this node's origin.
func _build_demo() -> void:
	mouth = MonsterMouth.new()
	mouth.name = "DemoMouth"
	add_child(mouth)
	var s := CutsceneKit.Soup.new()
	var floor_y := drop_height - 1.6  # the camera starts at head height above the floor
	var wide := 6.0
	var col := Color("3a3330")
	s.box(Vector3(-(SHAFT_HALF + wide * 0.5), floor_y - 0.2, 0.0), Vector3(wide * 0.5, 0.2, SHAFT_HALF + wide), col)
	s.box(Vector3(SHAFT_HALF + wide * 0.5, floor_y - 0.2, 0.0), Vector3(wide * 0.5, 0.2, SHAFT_HALF + wide), col)
	s.box(Vector3(0.0, floor_y - 0.2, -(SHAFT_HALF + wide * 0.5)), Vector3(SHAFT_HALF, 0.2, wide * 0.5), col)
	s.box(Vector3(0.0, floor_y - 0.2, SHAFT_HALF + wide * 0.5), Vector3(SHAFT_HALF, 0.2, wide * 0.5), col)
	var wall := Color("2a2322")
	var mid := floor_y * 0.5
	s.box(Vector3(-SHAFT_HALF - 0.05, mid, 0.0), Vector3(0.05, mid, SHAFT_HALF), wall)
	s.box(Vector3(SHAFT_HALF + 0.05, mid, 0.0), Vector3(0.05, mid, SHAFT_HALF), wall)
	s.box(Vector3(0.0, mid, -SHAFT_HALF - 0.05), Vector3(SHAFT_HALF + 0.1, mid, 0.05), wall)
	s.box(Vector3(0.0, mid, SHAFT_HALF + 0.05), Vector3(SHAFT_HALF + 0.1, mid, 0.05), wall)
	CutsceneKit.add_mesh(self, s.mesh())
	CutsceneKit.omni(self, Vector3(0.0, floor_y + 2.4, 0.0), Color(1.0, 0.85, 0.6), 2.0, 9.0)  # the room's light, from above


# --- the timeline -------------------------------------------------------------------------------------------------------------------

## The camera's height above the lip at `time`: falls from `drop_height`, reaching the lip at T_LIP, then keeps its speed and accelerates.
func _height_at(time: float) -> float:
	if time <= T_LIP:
		var u := time / T_LIP
		return drop_height * (1.0 - u * u)
	var v := 2.0 * drop_height / T_LIP
	var d := time - T_LIP
	return maxf(-v * d - 0.5 * BELOW_LIP_ACCEL * d * d, FLOOR_Y)


func _update(time: float, _dt: float) -> void:
	var base := mouth.global_transform
	var y := _height_at(time)
	var swing := 1.1 * (1.0 - smoothstep(0.0, T_LIP, time))  # starts a little to the side, looking at the hole, ends straight above it
	var spin := 0.35 * TAU * time / LENGTH_SEC + 0.6
	var up_dir := Vector3(cos(spin), 0.0, sin(spin))
	var eye := Vector3(0.0, y, swing)
	var target := Vector3(0.0, y - 3.0, 0.0)
	var dir := (target - eye).normalized()
	var look := Basis.looking_at(dir, up_dir)
	camera.global_transform = base * Transform3D(look, eye)
	camera.fov = 62.0 + 38.0 * smoothstep(0.0, T_LIP + 0.6, time)
	mouth.pose(time)
	mouth.close_amount = smoothstep(T_LIP + T_SHUT, T_LIP + T_SHUT + 0.6, time)
	for i in _fallers.size():
		var a := TAU * i / maxi(_fallers.size(), 1) + 0.8 + 0.3 * time
		var below := 0.9 + 0.5 * i - 0.25 * smoothstep(0.0, T_LIP, time)  # they are ahead of the camera, falling into the mouth first
		var at := Vector3(cos(a) * (0.55 + 0.1 * i), y - below, sin(a) * (0.55 + 0.1 * i))
		_fallers[i].global_transform = base * Transform3D(Basis.from_euler(Vector3(time * (2.0 + i), time * 1.2 * (i + 1), time * 1.6)), at)
		var h := _fallers[i].get_child(0) as Humanoid
		var p := _hands_phase[i % 4]
		h.set_hand(0, Vector3(0.36, 1.85 + 0.2 * sin(time * 9.0 + p), -0.15))  # arms flung up
		h.set_hand(1, Vector3(-0.36, 1.85 + 0.2 * sin(time * 9.0 + p + 1.7), -0.15))
	if caption_text != "" and time >= T_CAPTION:
		caption_line(caption_text)
