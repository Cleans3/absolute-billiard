class_name TouchControls
extends CanvasLayer
## All player UI (08 §2.3): the touch widgets, plus the prompt / status labels desktop uses too.
## The widgets expose values and signals only; the Player and CueController read them, nothing here calls gameplay.
## Touch widgets show when the device has a touchscreen; on desktop only the display-only cue readouts do.

signal interact_pressed
signal shoot_pressed  ## enter CUE
signal jump_pressed
signal back_pressed
signal place_pressed
signal drop_pressed
signal pocket_tapped(index: int)

const BTN := Vector2(96, 96)
const MARGIN := 24.0
const TOAST_SEC := 2.5
const MODE_WALK := 0  ## Player.Mode values, kept as ints so this file needs no Player dependency
const MODE_CUE := 1
const MODE_CARRY := 2

@export var touch := DisplayServer.is_touchscreen_available():
	set(v):
		touch = v
		if is_node_ready():
			_apply()
@export var mirror := false:
	set(v):
		mirror = v
		if is_node_ready():
			_layout()

var stick: VirtualStick
var look: LookPad
var spin_pad: SpinPad
var elevation: PowerSlider
var power: PowerSlider
var pockets: Array[TouchButton] = []

var _mode := MODE_WALK
var _can_shoot := false
var _prompt := ""
var _call_pockets := false
var _clock_text := ""
var _toast_text := ""
var _btn_interact: TouchButton
var _btn_shoot: TouchButton
var _btn_jump: TouchButton
var _btn_back: TouchButton
var _btn_place: TouchButton
var _btn_drop: TouchButton
var _prompt_label: Label
var _status: Label
var _toast_timer: Timer
var _right: Array[Control] = []  ## laid out on the right-thumb side, flipped by `mirror`
var _left: Array[Control] = []


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	look = _add(root, LookPad.new())
	stick = _add(root, VirtualStick.new())
	spin_pad = _add(root, SpinPad.new())
	elevation = _add(root, PowerSlider.new())
	elevation.from_top = false
	elevation.max_value = 80.0
	elevation.caption = "elev"
	power = _add(root, PowerSlider.new())
	power.caption = "power"
	_btn_jump = _button(root, "Jump", jump_pressed)
	_btn_interact = _button(root, "Use", interact_pressed)
	_btn_shoot = _button(root, "Shoot", shoot_pressed)
	_btn_back = _button(root, "Back", back_pressed)
	_btn_place = _button(root, "Place", place_pressed)
	_btn_drop = _button(root, "Drop", drop_pressed)
	for i in 6:
		var b := _button(root, str(i + 1), pocket_tapped, i)
		pockets.append(b)
	_prompt_label = _label(root, 0.5, 1.0, -200, -150, 200, -110)
	_status = _label(root, 0.5, 0.0, -300, 16, 300, 56)
	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(_on_toast_end)
	add_child(_toast_timer)
	_layout()
	_apply()


## Mode / context. Every setter redraws only what changed.
func set_mode(mode: int) -> void:
	if mode != _mode:
		_mode = mode
		look.release()
		stick.release()
		_apply()


func set_can_shoot(v: bool) -> void:
	if v != _can_shoot:
		_can_shoot = v
		_apply()


func set_prompt(text: String) -> void:
	if text != _prompt:
		_prompt = text
		_prompt_label.text = text
		_btn_interact.text = text if text != "" else "Use"
		_apply()


func set_call_pockets(v: bool) -> void:
	if v != _call_pockets:
		_call_pockets = v
		_apply()


func set_called_pocket(index: int) -> void:
	for i in pockets.size():
		pockets[i].selected = i == index
	power.locked = _call_pockets and index < 0


func set_clock(text: String) -> void:
	if text != _clock_text:
		_clock_text = text
		_show_status()


func toast(text: String) -> void:
	_toast_text = text
	_toast_timer.start(TOAST_SEC)
	_show_status()


func _on_toast_end() -> void:
	_toast_text = ""
	_show_status()


func _show_status() -> void:
	_status.text = _toast_text if _toast_text != "" else _clock_text


func _apply() -> void:
	var walk := _mode == MODE_WALK
	var cue := _mode == MODE_CUE
	var carry := _mode == MODE_CARRY
	look.visible = touch
	stick.visible = touch and not cue
	_btn_jump.visible = touch and walk
	_btn_interact.visible = touch and (walk or carry) and _prompt != ""
	_btn_shoot.visible = touch and walk and _can_shoot
	_btn_back.visible = touch and cue
	_btn_place.visible = touch and carry
	_btn_drop.visible = touch and carry
	spin_pad.visible = cue
	power.visible = cue
	elevation.visible = cue
	for b in pockets:
		b.visible = touch and cue and _call_pockets
	_prompt_label.visible = not touch and _prompt != ""
	var interactive := Control.MOUSE_FILTER_STOP if touch else Control.MOUSE_FILTER_IGNORE
	for c: Control in [look, stick, spin_pad, elevation, power]:
		c.mouse_filter = interactive


func _layout() -> void:
	stick.anchor_left = 0.5 if mirror else 0.0
	stick.anchor_right = 1.0 if mirror else 0.5
	stick.anchor_top = 0.25
	stick.anchor_bottom = 1.0
	# right-thumb group (flips with `mirror`)
	_corner(_btn_jump, not mirror, MARGIN, MARGIN)
	_corner(_btn_interact, not mirror, MARGIN, MARGIN * 2 + BTN.y)
	_corner(_btn_shoot, not mirror, MARGIN * 2 + BTN.x, MARGIN)
	_corner(_btn_place, not mirror, MARGIN, MARGIN)
	_corner(_btn_drop, not mirror, MARGIN, MARGIN * 2 + BTN.y)
	_side_v(power, not mirror, MARGIN, 72.0, 0.15, 0.85)
	# left-thumb group (CUE)
	spin_pad.custom_minimum_size = Vector2(120, 120)
	_corner(spin_pad, mirror, MARGIN, MARGIN, Vector2(120, 120))
	_corner(elevation, mirror, MARGIN, MARGIN * 2 + 120.0, Vector2(56, 200))
	_corner(_btn_back, mirror, MARGIN, MARGIN, BTN, true)
	for i in pockets.size():
		var b := pockets[i]
		b.anchor_left = 0.5
		b.anchor_right = 0.5
		b.anchor_top = 0.0
		b.anchor_bottom = 0.0
		b.offset_left = (i - 3) * 80.0
		b.offset_right = b.offset_left + 72.0
		b.offset_top = 72.0
		b.offset_bottom = 144.0


## Pin `c` to a screen corner: `side_right` picks left/right, `x`/`y` are the inset, `top` picks the top edge.
func _corner(c: Control, side_right: bool, x: float, y: float, sz := BTN, top := false) -> void:
	c.anchor_left = 1.0 if side_right else 0.0
	c.anchor_right = c.anchor_left
	c.offset_left = -x - sz.x if side_right else x
	c.offset_right = -x if side_right else x + sz.x
	c.anchor_top = 0.0 if top else 1.0
	c.anchor_bottom = c.anchor_top
	c.offset_top = y if top else -y - sz.y
	c.offset_bottom = y + sz.y if top else -y


## A tall slider on one screen edge: `x` inset from the edge, `w` wide, spanning `top`..`bottom` of the height.
func _side_v(c: Control, side_right: bool, x: float, w: float, top: float, bottom: float) -> void:
	c.anchor_left = 1.0 if side_right else 0.0
	c.anchor_right = c.anchor_left
	c.offset_left = -x - w if side_right else x
	c.offset_right = -x if side_right else x + w
	c.anchor_top = top
	c.anchor_bottom = bottom
	c.offset_top = 0.0
	c.offset_bottom = 0.0


func _add(parent: Control, c: Control) -> Control:
	parent.add_child(c)
	return c


func _button(parent: Control, text: String, sig: Signal, arg := -1) -> TouchButton:
	var b := TouchButton.new()
	b.text = text
	if arg >= 0:
		b.pressed.connect(func() -> void: sig.emit(arg))
	else:
		b.pressed.connect(func() -> void: sig.emit())
	parent.add_child(b)
	return b


func _label(parent: Control, ax: float, ay: float, l: float, t: float, r: float, b: float) -> Label:
	var lab := Label.new()
	lab.anchor_left = ax
	lab.anchor_right = ax
	lab.anchor_top = ay
	lab.anchor_bottom = ay
	lab.offset_left = l
	lab.offset_top = t
	lab.offset_right = r
	lab.offset_bottom = b
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(lab)
	return lab
