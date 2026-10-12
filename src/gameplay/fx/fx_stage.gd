class_name FxStage
extends CanvasLayer

## Screen-space half of the chaos FX (docs/plan/10 §3): additive colour flash, banner text rows, confetti rain and
## cannons. Presentation only, local to this peer, never takes input. Sleeps (no process) while nothing plays.

const ROW_TRICK := 0
const ROW_COMBO := 1
const ROW_MINOR := 2
const ROW_Y := [0.24, 0.38, 0.5]  # fraction of the viewport height, per row
const ROW_SIZE := [0.13, 0.095, 0.06]  # font size as a fraction of the viewport height
const POP_SEC := 0.22
const HOLD_SEC := [1.5, 1.1, 0.9]
const OUT_SEC := 0.45
const RAIN_AMOUNT := 150
const CANNON_AMOUNT := 70

var _flash_rect: ColorRect
var _flash_mat: ShaderMaterial
var _flash := 0.0
var _flash_decay := 1.0
var _rows: Array[Label] = []
var _row_t := PackedFloat32Array([-1.0, -1.0, -1.0])
var _row_scale := PackedFloat32Array([1.0, 1.0, 1.0])
var _rain: GPUParticles2D
var _cannons: Array[GPUParticles2D] = []


func _init() -> void:
	layer = 3  # above the HUD, below nothing the player has to press


func _ready() -> void:
	_flash_rect = ColorRect.new()
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_mat = ShaderMaterial.new()
	_flash_mat.shader = FxPresets.FLASH_SHADER
	_flash_rect.material = _flash_mat
	_flash_rect.visible = false
	add_child(_flash_rect)
	for i in 3:
		var l := Label.new()
		l.add_theme_font_override(&"font", FxPresets.FONT)
		l.add_theme_constant_override(&"outline_size", 14)
		l.add_theme_color_override(&"font_outline_color", Color(0.05, 0.02, 0.1))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.visible = false
		add_child(l)
		_rows.append(l)
	_rain = FxPresets.emitter2d(RAIN_AMOUNT, 2.4)
	add_child(_rain)
	for i in 2:
		var c := FxPresets.emitter2d(CANNON_AMOUNT, 1.9)
		add_child(c)
		_cannons.append(c)
	set_process(false)


## Additive colour wash of strength `amount` (~0.2 subtle, 1.0 blinding) that falls to zero in `sec`.
func flash(color: Color, amount: float, sec: float) -> void:
	_flash = maxf(_flash, amount)
	_flash_decay = maxf(amount / maxf(sec, 0.05), 0.0)
	_flash_mat.set_shader_parameter(&"flash_color", color)
	_flash_rect.visible = true
	set_process(true)


## Banner text on `row`, popping in, holding, then rising away. `size_mult` scales the row's base size.
func banner(row: int, text: String, color: Color, size_mult := 1.0) -> void:
	var l := _rows[row]
	var h := get_viewport().get_visible_rect().size
	l.text = text
	l.add_theme_font_size_override(&"font_size", roundi(h.y * ROW_SIZE[row] * size_mult))
	l.add_theme_color_override(&"font_color", color)
	l.size = Vector2(h.x, h.y * ROW_SIZE[row] * size_mult * 1.25 * (text.count("\n") + 1))
	l.position = Vector2(0.0, h.y * ROW_Y[row])
	l.pivot_offset = l.size * 0.5
	l.visible = true
	l.modulate.a = 1.0
	_row_t[row] = 0.0
	_row_scale[row] = size_mult
	set_process(true)


## Confetti: rain across the top, and from tier 2 up a cannon out of each bottom corner.
func confetti(tier: int, amount_ratio := 1.0) -> void:
	var h := get_viewport().get_visible_rect().size
	var px := h.y / 720.0
	var pm := _rain.process_material as ParticleProcessMaterial
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(h.x * 0.5, 8.0, 1.0)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 180.0 * px
	pm.initial_velocity_max = 520.0 * px
	pm.gravity = Vector3(0, 650.0 * px, 0)
	pm.scale_min = 0.6 * px
	pm.scale_max = 1.6 * px
	_rain.position = Vector2(h.x * 0.5, -16.0)
	_rain.amount_ratio = clampf(amount_ratio, 0.05, 1.0)
	_rain.restart()
	for i in _cannons.size():
		var c := _cannons[i]
		if tier < 2:
			continue
		var side := -1.0 if i == 0 else 1.0
		var cm := c.process_material as ParticleProcessMaterial
		cm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
		cm.direction = Vector3(-side * 0.5, -1.0, 0.0).normalized()
		cm.spread = 16.0
		cm.initial_velocity_min = 700.0 * px
		cm.initial_velocity_max = 1300.0 * px
		cm.gravity = Vector3(0, 1300.0 * px, 0)
		cm.scale_min = 0.6 * px
		cm.scale_max = 1.6 * px
		c.position = Vector2(h.x * (0.04 if i == 0 else 0.96), h.y)
		c.amount_ratio = clampf(amount_ratio, 0.05, 1.0)
		c.restart()
	set_process(true)


func idle() -> bool:
	return not is_processing()


func _process(delta: float) -> void:
	var busy := false
	if _flash > 0.0:
		_flash = maxf(_flash - _flash_decay * delta, 0.0)
		_flash_mat.set_shader_parameter(&"amount", _flash)
		_flash_rect.visible = _flash > 0.0
		busy = busy or _flash > 0.0
	for row in _rows.size():
		var t := _row_t[row]
		if t < 0.0:
			continue
		t += delta
		_row_t[row] = t
		var l := _rows[row]
		var hold: float = HOLD_SEC[row]
		var total: float = POP_SEC + hold + OUT_SEC
		if t >= total:
			l.visible = false
			_row_t[row] = -1.0
			continue
		busy = true
		var pop := clampf(t / POP_SEC, 0.0, 1.0)
		var s := 1.0 + (1.0 - pop) * 1.4 + (1.0 - pop) * (1.0 - pop) * 0.3  # slams in from big
		var out := clampf((t - POP_SEC - hold) / OUT_SEC, 0.0, 1.0)
		l.scale = Vector2.ONE * s * (1.0 + out * 0.15)
		l.rotation = sin(t * 38.0) * 0.045 * (1.0 - pop) + sin(t * 11.0) * 0.012
		l.modulate.a = 1.0 - out
		l.position.y = get_viewport().get_visible_rect().size.y * ROW_Y[row] - out * 60.0
	busy = busy or _rain.emitting or _cannons[0].emitting or _cannons[1].emitting
	if not busy:
		set_process(false)
