class_name Phone
extends Node3D
## The wall phone behind the counter (docs/plan/09 §2.2, §3.2). Rings until someone answers the first Intermission of a Night:
## the body shakes, a "RING RING" bubble pulses and a procedural bell plays. Moe then talks through it on speaker: his
## subtitle in a speech bubble above the phone and lower, slower blips (BartenderVoice x0.6 pitch, x1.4 length). Pure
## presentation: StoryDirector decides when it rings, and the host-validated `answer_phone` interaction decides who picked up.
## The mesh is built in code with vertex colours on Humanoid's shared material, so the phone adds no material (07 budget).

const RING_EVERY_SEC := 1.7
const RING_SEC := 1.0  ## the bell sample's length: the body shakes while it plays
const SHAKE_RAD := 0.07
const MIX_RATE := 22050
const MOE_PITCH := 0.6
const MOE_LENGTH := 1.4

var prop: Interactable  ## the use target on the floor in front of it; only live while the phone rings
var voice: BartenderVoice  ## Moe
var bubble: SpeechBubble
var rings := 0  ## bell cycles since the last set_ringing(true), for probes

var _ringing := false
var _t := 0.0
var _body: MeshInstance3D
var _bell: AudioStreamPlayer3D


func _ready() -> void:
	add_to_group(&"story_phone")
	_body = MeshInstance3D.new()
	_body.mesh = _build_mesh()
	_body.material_override = Humanoid._shared_material()
	_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_body)
	voice = BartenderVoice.new()
	voice.pitch_mult = MOE_PITCH
	voice.length_mult = MOE_LENGTH
	add_child(voice)
	bubble = SpeechBubble.new()
	bubble.position = Vector3(0.0, 0.2, 0.1)
	add_child(bubble)
	_bell = AudioStreamPlayer3D.new()
	_bell.stream = _render_bell()
	_bell.unit_size = 5.0
	_bell.max_distance = 22.0
	_bell.volume_db = -6.0
	add_child(_bell)
	set_process(false)
	_apply_prop()


## Bar hands over the floor Interactable; it is only a target while the phone rings, so a quiet phone never shows a prompt.
func bind_prop(p: Interactable) -> void:
	prop = p
	_apply_prop()


func is_ringing() -> bool:
	return _ringing


func set_ringing(on: bool) -> void:
	if on == _ringing:
		return
	_ringing = on
	_t = RING_EVERY_SEC  # the first ring comes at once
	rings = 0
	if not on:
		_bell.stop()
		_body.rotation = Vector3.ZERO
		if bubble.text() == "RING RING":
			bubble.hide_line()
	set_process(on)
	_apply_prop()


## One line of Moe's call: the subtitle for `seconds` and the babble.
func say(line: String, seconds: float) -> void:
	bubble.show_line("Moe: " + line, seconds)
	voice.speak(line)


func _apply_prop() -> void:
	if prop == null or not prop.is_inside_tree():
		return
	prop.collision_layer = Interactable.LAYER if _ringing else 0
	prop.prompt = "Answer the phone" if _ringing else ""


func _process(delta: float) -> void:
	_t += delta
	if _t >= RING_EVERY_SEC:
		_t = 0.0
		rings += 1
		_bell.play()
		bubble.show_line("RING RING", RING_SEC)
	_body.rotation.z = sin(_t * 90.0) * SHAKE_RAD if _t < RING_SEC else 0.0


# --- the model: a red bakelite wall phone, facing +Z (into the room) ----------------------------------------------------------

func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var red := Color(0.62, 0.10, 0.08)
	var cream := Color(0.93, 0.88, 0.74)
	var brass := Color(0.78, 0.62, 0.25)
	var black := Color(0.10, 0.09, 0.09)
	_box(st, Vector3(0.0, -0.02, 0.02), Vector3(0.20, 0.26, 0.04), red)       # the back plate and body
	_box(st, Vector3(0.0, -0.03, 0.048), Vector3(0.11, 0.11, 0.012), cream)    # the dial
	_box(st, Vector3(0.0, -0.03, 0.056), Vector3(0.03, 0.03, 0.006), black)    # its hub
	_box(st, Vector3(-0.045, 0.135, 0.03), Vector3(0.07, 0.05, 0.05), brass)   # the two bells
	_box(st, Vector3(0.045, 0.135, 0.03), Vector3(0.07, 0.05, 0.05), brass)
	_box(st, Vector3(-0.12, 0.02, 0.05), Vector3(0.04, 0.26, 0.04), black)     # the handset on its cradle: bar and two cups
	_box(st, Vector3(-0.12, 0.16, 0.05), Vector3(0.07, 0.06, 0.07), black)
	_box(st, Vector3(-0.12, -0.12, 0.05), Vector3(0.07, 0.06, 0.07), black)
	return st.commit()


## An axis-aligned box as 12 triangles, one flat colour (Godot's front face is clockwise).
static func _box(st: SurfaceTool, c: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	for axis in 3:
		for s: float in [1.0, -1.0]:
			var n := Vector3.ZERO
			n[axis] = s
			var ia := (axis + 1) % 3 if s > 0.0 else (axis + 2) % 3  # u x v = n
			var ib := (axis + 2) % 3 if s > 0.0 else (axis + 1) % 3
			var u := Vector3.ZERO
			u[ia] = h[ia]
			var v := Vector3.ZERO
			v[ib] = h[ib]
			var mid := c + n * h[axis]
			var p := [mid - u - v, mid + u - v, mid + u + v, mid - u + v]
			for i in [0, 2, 1, 0, 3, 2]:
				st.set_color(color)
				st.set_normal(n)
				st.add_vertex(p[i])


## Two bursts of the 440 + 480 Hz telephone pair, warbled at 20 Hz.
static func _render_bell() -> AudioStreamWAV:
	var n := int(RING_SEC * MIX_RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / MIX_RATE
		var gate := 1.0 if (t < 0.4 or (t >= 0.5 and t < 0.9)) else 0.0
		var warble := 0.65 + 0.35 * sin(TAU * 20.0 * t)
		var wave := (sin(TAU * 440.0 * t) + sin(TAU * 480.0 * t)) * 0.5
		data.encode_s16(i * 2, int(clampf(wave * warble * gate * 0.5, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
