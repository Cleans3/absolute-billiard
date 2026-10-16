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
signal swing_pressed  ## the held cue (08 §2.9)
signal throw_pressed

const BTN := Vector2(96, 96)
const MARGIN := 24.0
const PAUSE_BTN := Vector2(64, 64)
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
var spin_pad: SpinPad  ## the small cue-ball control; a tap opens `spin_overlay`
var elevation: ElevationPad  ## the small cue-angle control; a tap opens `elevation_overlay`
var spin_overlay: SpinOverlay
var elevation_overlay: ElevationOverlay
var power: PowerSlider
var pockets: Array[TouchButton] = []

var _mode := MODE_WALK
var _can_shoot := false
var _prompt := ""
var _call_pockets := false
var _btn_interact: TouchButton
var _btn_shoot: TouchButton
var _btn_jump: TouchButton
var _btn_back: TouchButton
var _btn_place: TouchButton
var _btn_drop: TouchButton
var _btn_pause: TouchButton
var _btn_swing: TouchButton
var _btn_throw: TouchButton
var _has_cue := false
var _prompt_label: Label
var _status: Label  ## the shot clock; notices go through UIRouter.toast (one channel)
var _away: Label
var _right: Array[Control] = []  ## laid out on the right-thumb side, flipped by `mirror`
var _left: Array[Control] = []


func _ready() -> void:
	add_to_group(Settings.GROUP)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	look = _add(root, LookPad.new())
	stick = _add(root, VirtualStick.new())
	spin_pad = _add(root, SpinPad.new())
	elevation = _add(root, ElevationPad.new())
	power = _add(root, PowerSlider.new())
	power.caption = "power"
	_btn_jump = _button(root, "", jump_pressed)
	_btn_jump.icon = load("res://assets/ui/icon_jump.svg")  # arrow up
	_btn_interact = _button(root, "Use", interact_pressed)
	_btn_shoot = _button(root, "Shoot", shoot_pressed)
	_btn_back = _button(root, "", back_pressed)
	_btn_back.icon = load("res://assets/ui/icon_back.svg")
	_btn_place = _button(root, "Place", place_pressed)
	_btn_drop = _button(root, "Drop", drop_pressed)
	_btn_swing = _button(root, "Swing", swing_pressed)
	_btn_throw = _button(root, "Throw", throw_pressed)
	for i in 6:
		var b := _button(root, str(i + 1), pocket_tapped, i)
		pockets.append(b)
	_btn_pause = TouchButton.new()
	_btn_pause.icon = load("res://assets/ui/icon_pause.svg")
	_btn_pause.pressed.connect(func() -> void:
		if UIRouter.instance != null:
			UIRouter.instance.open_pause())
	root.add_child(_btn_pause)
	spin_overlay = _add(root, SpinOverlay.new())  # above every widget, below the labels: the shot clock stays readable
	spin_overlay.bind(spin_pad)
	spin_pad.opened.connect(_open_overlay.bind(spin_overlay))
	elevation_overlay = _add(root, ElevationOverlay.new())
	elevation_overlay.bind(elevation)
	elevation.opened.connect(_open_overlay.bind(elevation_overlay))
	_prompt_label = _label(root, 0.5, 1.0, -200, -76, 200, -36)
	_status = _label(root, 0.5, 0.0, -160, 64, 160, 104)
	_away = _label(root, 0.5, 0.0, -300, 232, 300, 272)
	_away.set_script(preload("res://src/ui/host_away_label.gd"))  # text = what we wait on + the seconds
	_away.hide()
	mirror = bool(Settings.value(&"touch_mirror"))  # the setter lays out
	_layout()
	_apply()
	_bind_router.call_deferred()


## Hidden under a modal: the screens own every touch while one is open (docs 08 §2.8).
func _bind_router() -> void:
	if UIRouter.instance != null:
		UIRouter.instance.modal_changed.connect(_on_modal_changed)
		_on_modal_changed(UIRouter.instance.is_modal_open())


func _on_modal_changed(open: bool) -> void:
	visible = not open
	if open:
		look.release()
		stick.release()
		_close_overlays()


func _on_settings_changed() -> void:
	mirror = bool(Settings.value(&"touch_mirror"))


## Mode / context. Every setter redraws only what changed.
func set_mode(mode: int) -> void:
	if mode != _mode:
		_mode = mode
		look.release()
		stick.release()
		_apply()


## The local player holds a cue (CueRack.changed): Swing and Throw show while walking.
func set_has_cue(v: bool) -> void:
	if v != _has_cue:
		_has_cue = v
		_apply()


func set_can_shoot(v: bool) -> void:
	if v != _can_shoot:
		_can_shoot = v
		_apply()


## Presentation only: the host's app is in the background.
func set_host_away(away: bool) -> void:
	_away.visible = away


## The highest cue angle the cue allows right now (`Ball.effective_elevation`): the small control and its overlay show the rest as shut.
func set_elevation_cap(deg: float) -> void:
	elevation.set_cap(deg)


func _open_overlay(overlay: Control) -> void:
	look.release()
	overlay.call(&"open")


func _close_overlays() -> void:
	spin_overlay.close()
	elevation_overlay.close()


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
	_status.text = text


## Kept for callers that hold the controls (CueController); the line itself is UIRouter's.
func toast(text: String) -> void:
	if UIRouter.instance != null:
		UIRouter.instance.toast(text)


func _apply() -> void:
	var walk := _mode == MODE_WALK
	var cue := _mode == MODE_CUE
	var carry := _mode == MODE_CARRY
	look.visible = touch
	_layout_look()
	_btn_pause.visible = touch
	stick.visible = touch and not cue
	_btn_jump.visible = touch and walk
	_btn_interact.visible = touch and walk and _prompt != ""  # CARRY has Place / Drop in that corner
	_btn_shoot.visible = touch and walk and _can_shoot
	_btn_back.visible = touch and cue
	_btn_place.visible = touch and carry
	_btn_drop.visible = touch and carry
	_btn_swing.visible = touch and walk and _has_cue
	_btn_throw.visible = touch and walk and _has_cue
	spin_pad.visible = cue
	power.visible = cue
	elevation.visible = cue
	if not cue:
		_close_overlays()
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
	_layout_look()
	_corner(_btn_pause, not mirror, 16.0, 8.0, PAUSE_BTN, true)  # opposite corner to Back (top, left-thumb side)
	# right-thumb group (flips with `mirror`)
	_corner(_btn_jump, not mirror, MARGIN, MARGIN)
	_corner(_btn_interact, not mirror, MARGIN, MARGIN * 2 + BTN.y)
	_corner(_btn_shoot, not mirror, MARGIN * 2 + BTN.x, MARGIN)
	_corner(_btn_place, not mirror, MARGIN, MARGIN)
	_corner(_btn_drop, not mirror, MARGIN, MARGIN * 2 + BTN.y)
	_corner(_btn_swing, not mirror, MARGIN * 2 + BTN.x, MARGIN * 2 + BTN.y)  # the held cue: above Shoot, and left of it
	_corner(_btn_throw, not mirror, MARGIN * 3 + BTN.x * 2, MARGIN)
	_side_v(power, not mirror, MARGIN, 72.0, 0.15, 0.85)
	# left-thumb group (CUE)
	spin_pad.custom_minimum_size = Vector2(120, 120)
	_corner(spin_pad, mirror, MARGIN, MARGIN, Vector2(120, 120))
	_corner(elevation, mirror, MARGIN, MARGIN * 2 + 120.0, Vector2(120, 72))
	_corner(_btn_back, mirror, MARGIN, MARGIN, BTN, true)
	for i in pockets.size():
		var b := pockets[i]
		b.anchor_left = 0.5
		b.anchor_right = 0.5
		b.anchor_top = 0.0
		b.anchor_bottom = 0.0
		b.offset_left = (i - 3) * 80.0
		b.offset_right = b.offset_left + 72.0
		b.offset_top = 156.0
		b.offset_bottom = 228.0


## Look pad: the half opposite the stick (WALK / CARRY), the whole screen in CUE where any free spot aims. Under every button.
func _layout_look() -> void:
	var half := _mode != MODE_CUE
	look.anchor_left = 0.0 if (not half or mirror) else 0.5
	look.anchor_right = 1.0 if (not half or not mirror) else 0.5
	look.anchor_top = 0.0
	look.anchor_bottom = 1.0
	look.offset_left = 0.0
	look.offset_right = 0.0
	look.offset_top = 0.0
	look.offset_bottom = 0.0


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
	lab.theme_type_variation = &"HudLabel"
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(lab)
	return lab
