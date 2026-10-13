class_name CutsceneShell
extends UIModal
## The UI layer of one cutscene (docs/plan/09 §4.4): a modal above every other screen (priority 100), so while it is open
## `UIRouter.blocking()` holds the game's input; a black fade, one caption line, the Skip button, and a bottom dock for a card.
## Esc / Back skips. Lives under a CanvasLayer the Cutscene owns, so it draws over the HUD too.

signal skip_requested

const CAPTION_FONT := 30
const DOCK_HEIGHT := 460.0

var fade: ColorRect
var caption: Label
var skip_button: Button
var dock: Control  ## the bottom strip a card (the run's stats) is added to; it passes the mouse through where it is empty


func _init() -> void:
	dim = false
	priority = 100
	keep_on_phase = true  # a phase change under a cutscene must not close it


func _ready() -> void:
	super()
	fade = ColorRect.new()
	fade.color = Color.BLACK
	fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.visible = false
	add_child(fade)
	caption = Label.new()
	caption.anchor_left = 0.0
	caption.anchor_right = 1.0
	caption.anchor_top = 1.0
	caption.anchor_bottom = 1.0
	caption.offset_left = 80.0
	caption.offset_right = -80.0
	caption.offset_top = -210.0
	caption.offset_bottom = -40.0
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.add_theme_font_size_override(&"font_size", CAPTION_FONT)
	caption.add_theme_constant_override(&"outline_size", 10)
	caption.add_theme_color_override(&"font_outline_color", Color.BLACK)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.visible = false
	add_child(caption)
	dock = Control.new()
	dock.anchor_left = 0.0
	dock.anchor_right = 1.0
	dock.anchor_top = 1.0
	dock.anchor_bottom = 1.0
	dock.offset_top = -DOCK_HEIGHT
	dock.offset_bottom = 0.0
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dock)
	skip_button = Button.new()
	skip_button.text = "Skip"
	skip_button.custom_minimum_size = Vector2(160.0, 64.0)
	skip_button.anchor_left = 1.0
	skip_button.anchor_right = 1.0
	skip_button.offset_left = -184.0
	skip_button.offset_right = -24.0
	skip_button.offset_top = 24.0
	skip_button.offset_bottom = 88.0
	skip_button.focus_mode = Control.FOCUS_NONE
	skip_button.pressed.connect(func() -> void: skip_requested.emit())
	add_child(skip_button)


## 0 = clear, 1 = black.
func set_fade(alpha: float) -> void:
	fade.color.a = clampf(alpha, 0.0, 1.0)
	fade.visible = alpha > 0.001


func show_caption(text: String) -> void:
	caption.text = text.replace("*", "")
	caption.visible = text != ""


func hide_caption() -> void:
	caption.visible = false


## Esc / Back (UIRouter.escape): the same as the Skip button.
func go_back() -> void:
	skip_requested.emit()
