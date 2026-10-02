extends SceneTree
## One-shot: builds the project-wide Theme (docs/plan/06 P12) from assets/ui/*.svg + the OFL font and saves it.
##   python3 src/tools/ui_art.py && godot --path . --headless --import
##   godot --path . --headless -s src/tools/build_ui_theme.gd
## Styling lives here and nowhere else: scenes carry no font-size / colour overrides, they pick a type variation
## (HudLabel, Title, Heading, Caption, ToastInfo|Good|Bad, PrimaryButton, FlatButton, PanelInset, PanelPlate).

const OUT := "res://src/ui/theme/game_theme.tres"
const UI := "res://assets/ui/"
const FONT := "res://assets/fonts/BarlowCondensed-SemiBold.ttf"

const CREAM := Color("F4EAD3")
const MUTED := Color("B9A98A")
const BRASS := Color("C9A24B")
const BRASS_L := Color("F2D98B")
const BRASS_D := Color("86672A")
const PINK := Color("FF3D9A")
const CYAN := Color("3DE0FF")
const RED := Color("FF5A5A")
const GREEN := Color("5BE08A")
const ORANGE := Color("FFA23D")
const WALNUT := Color("3B2316")
const FELT := Color("0F3D2E")
const INK := Color(0.04, 0.02, 0.01, 0.92)

var theme := Theme.new()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var font: Font = load(FONT)
	theme.default_font = font
	theme.default_font_size = 26
	_palette()
	_labels()
	_buttons()
	_panels()
	_inputs()
	_scroll_tabs()
	DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
	var err := ResourceSaver.save(theme, OUT)
	print("theme -> %s (%s)" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)


## Colours for custom-drawn widgets (touch controls, spin disc): `get_theme_color(&"brass", &"Game")`.
func _palette() -> void:
	for pair: Array in [[&"cream", CREAM], [&"muted", MUTED], [&"brass", BRASS], [&"brass_light", BRASS_L], [&"brass_dark", BRASS_D],
			[&"pink", PINK], [&"cyan", CYAN], [&"red", RED], [&"green", GREEN], [&"orange", ORANGE], [&"walnut", WALNUT], [&"felt", FELT], [&"ink", INK]]:
		theme.set_color(pair[0], &"Game", pair[1])


func _labels() -> void:
	theme.set_color(&"font_color", &"Label", CREAM)
	theme.set_color(&"font_outline_color", &"Label", INK)
	theme.set_constant(&"outline_size", &"Label", 0)
	theme.set_constant(&"line_spacing", &"Label", 2)
	_variation(&"HudLabel", &"Label", {font_size = 26, outline_size = 6, color = CREAM})
	_variation(&"HudDanger", &"Label", {font_size = 26, outline_size = 6, color = RED})
	_variation(&"Title", &"Label", {font_size = 64, outline_size = 8, color = BRASS_L, outline = Color(0.45, 0.05, 0.25, 0.95)})
	_variation(&"Heading", &"Label", {font_size = 38, outline_size = 0, color = BRASS_L})
	_variation(&"Payout", &"Label", {font_size = 46, outline_size = 8, color = BRASS_L})
	_variation(&"Caption", &"Label", {font_size = 20, outline_size = 0, color = MUTED})
	_variation(&"Danger", &"Label", {font_size = 26, outline_size = 0, color = RED})
	_variation(&"Good", &"Label", {font_size = 26, outline_size = 0, color = GREEN})
	for pair: Array in [[&"ToastInfo", CREAM], [&"ToastGood", GREEN], [&"ToastBad", RED]]:
		_variation(pair[0], &"Label", {font_size = 26, outline_size = 0, color = pair[1]})
		theme.set_stylebox(&"normal", pair[0], _box("hud_plate", 16, [16, 4, 16, 4]))
	for box in [&"VBoxContainer", &"HBoxContainer"]:
		theme.set_constant(&"separation", box, 14)
	theme.set_type_variation(&"ChipBox", &"HBoxContainer")  # icon + value, tighter than a row
	theme.set_constant(&"separation", &"ChipBox", 6)
	theme.set_constant(&"h_separation", &"GridContainer", 18)
	theme.set_constant(&"v_separation", &"GridContainer", 10)
	theme.set_constant(&"separation", &"HSeparator", 18)
	theme.set_constant(&"separation", &"VSeparator", 18)
	var line := StyleBoxLine.new()
	line.color = Color(BRASS_D, 0.7)
	line.thickness = 2
	theme.set_stylebox(&"separator", &"HSeparator", line)


func _buttons() -> void:
	_button_styles(&"Button", "btn_normal", "btn_hover", "btn_pressed", "btn_disabled")
	_button_styles(&"PrimaryButton", "btn_primary", "btn_primary_hover", "btn_primary_pressed", "btn_disabled", &"Button")
	theme.set_color(&"font_color", &"PrimaryButton", Color.WHITE)
	theme.set_color(&"font_hover_color", &"PrimaryButton", Color.WHITE)
	theme.set_color(&"font_pressed_color", &"PrimaryButton", Color("FFE3F1"))
	theme.set_color(&"font_outline_color", &"PrimaryButton", Color(0.45, 0.05, 0.25, 0.9))
	theme.set_constant(&"outline_size", &"PrimaryButton", 4)
	# FlatButton: text link look (Advanced toggle, small actions)
	theme.set_type_variation(&"FlatButton", &"Button")
	var none := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		theme.set_stylebox(s, &"FlatButton", none)
	theme.set_stylebox(&"focus", &"FlatButton", _box("btn_focus", 20, [8, 4, 8, 4], false))
	theme.set_color(&"font_color", &"FlatButton", MUTED)
	theme.set_color(&"font_hover_color", &"FlatButton", BRASS_L)
	theme.set_color(&"font_pressed_color", &"FlatButton", CYAN)
	theme.set_color(&"font_hover_pressed_color", &"FlatButton", CYAN)
	# CheckBox: a drawn box, label to its right
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		theme.set_stylebox(s, &"CheckBox", none)
	theme.set_stylebox(&"focus", &"CheckBox", _box("btn_focus", 20, [8, 4, 8, 4], false))
	theme.set_icon(&"unchecked", &"CheckBox", load(UI + "check_off.svg"))
	theme.set_icon(&"checked", &"CheckBox", load(UI + "check_on.svg"))
	theme.set_icon(&"unchecked_disabled", &"CheckBox", load(UI + "check_off.svg"))
	theme.set_icon(&"checked_disabled", &"CheckBox", load(UI + "check_on.svg"))
	theme.set_constant(&"h_separation", &"CheckBox", 16)
	theme.set_font_size(&"font_size", &"CheckBox", 28)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		theme.set_color(c, &"CheckBox", CREAM)
	theme.set_color(&"font_disabled_color", &"CheckBox", Color(MUTED, 0.6))


func _button_styles(type: StringName, normal: String, hover: String, pressed: String, disabled: String, base := &"") -> void:
	if base != &"":
		theme.set_type_variation(type, base)
	var pad := [24, 10, 24, 10]
	theme.set_stylebox(&"normal", type, _box(normal, 20, pad))
	theme.set_stylebox(&"hover", type, _box(hover, 20, pad))
	theme.set_stylebox(&"pressed", type, _box(pressed, 20, pad))
	theme.set_stylebox(&"hover_pressed", type, _box(pressed, 20, pad))
	theme.set_stylebox(&"disabled", type, _box(disabled, 20, pad))
	theme.set_stylebox(&"focus", type, _box("btn_focus", 20, pad, false))
	if base != &"":
		return
	theme.set_font_size(&"font_size", type, 28)
	theme.set_color(&"font_color", type, CREAM)
	theme.set_color(&"font_hover_color", type, Color.WHITE)
	theme.set_color(&"font_pressed_color", type, BRASS_L)
	theme.set_color(&"font_hover_pressed_color", type, BRASS_L)
	theme.set_color(&"font_focus_color", type, CREAM)
	theme.set_color(&"font_disabled_color", type, Color(MUTED, 0.55))
	theme.set_color(&"icon_normal_color", type, Color.WHITE)
	theme.set_color(&"icon_disabled_color", type, Color(1, 1, 1, 0.45))
	theme.set_constant(&"h_separation", type, 12)
	theme.set_constant(&"icon_max_width", type, 40)


func _panels() -> void:
	var frame := _box("panel_frame", 30, [30, 24, 30, 24])
	theme.set_stylebox(&"panel", &"Panel", frame)
	theme.set_stylebox(&"panel", &"PanelContainer", frame)
	theme.set_type_variation(&"PanelInset", &"PanelContainer")
	theme.set_stylebox(&"panel", &"PanelInset", _box("panel_inset", 18, [14, 10, 14, 10]))
	theme.set_type_variation(&"PanelPlate", &"PanelContainer")
	theme.set_stylebox(&"panel", &"PanelPlate", _box("hud_plate", 16, [14, 5, 14, 5]))
	theme.set_stylebox(&"panel", &"PopupMenu", _box("panel_inset", 18, [10, 10, 10, 10]))
	theme.set_stylebox(&"hover", &"PopupMenu", _box("btn_hover", 20, [10, 4, 10, 4]))
	theme.set_color(&"font_color", &"PopupMenu", CREAM)
	theme.set_color(&"font_hover_color", &"PopupMenu", Color.WHITE)
	theme.set_font_size(&"font_size", &"PopupMenu", 26)


func _inputs() -> void:
	var track := _box("slider_track", 6, [-1, -1, -1, -1])  # -1 = the texture margin is the padding: that is the track thickness
	var fill := _box("slider_fill", 6, [-1, -1, -1, -1])
	for type in [&"HSlider", &"VSlider"]:
		theme.set_stylebox(&"slider", type, track)
		theme.set_stylebox(&"grabber_area", type, fill)
		theme.set_stylebox(&"grabber_area_highlight", type, fill)
		theme.set_icon(&"grabber", type, load(UI + "slider_knob.svg"))
		theme.set_icon(&"grabber_highlight", type, load(UI + "slider_knob_hl.svg"))
		theme.set_icon(&"grabber_disabled", type, load(UI + "slider_knob.svg"))
	theme.set_stylebox(&"normal", &"LineEdit", _box("line_edit", 14, [18, 10, 18, 10]))
	theme.set_stylebox(&"focus", &"LineEdit", _box("line_edit_focus", 14, [18, 10, 18, 10]))
	theme.set_stylebox(&"read_only", &"LineEdit", _box("line_edit", 14, [18, 10, 18, 10]))
	theme.set_color(&"font_color", &"LineEdit", CREAM)
	theme.set_color(&"font_placeholder_color", &"LineEdit", Color(MUTED, 0.6))
	theme.set_color(&"caret_color", &"LineEdit", CYAN)
	theme.set_color(&"selection_color", &"LineEdit", Color(CYAN, 0.35))
	theme.set_font_size(&"font_size", &"LineEdit", 30)


func _scroll_tabs() -> void:
	var empty := StyleBoxEmpty.new()
	for type in [&"VScrollBar", &"HScrollBar"]:
		var bar := [12, 0, 12, 0] if type == &"VScrollBar" else [0, 12, 0, 12]  # sets the bar thickness: 24 px, a thumb-sized lane
		theme.set_stylebox(&"scroll", type, _box("scroll_track", 8, bar))
		theme.set_stylebox(&"scroll_focus", type, empty)
		theme.set_stylebox(&"grabber", type, _box("scroll_grabber", 8, [0, 0, 0, 0]))
		theme.set_stylebox(&"grabber_highlight", type, _box("scroll_grabber_hl", 8, [0, 0, 0, 0]))
		theme.set_stylebox(&"grabber_pressed", type, _box("scroll_grabber_hl", 8, [0, 0, 0, 0]))
	for type in [&"TabContainer", &"TabBar"]:
		var pad := [22, 8, 22, 8]
		theme.set_stylebox(&"tab_selected", type, _tab("tab_selected", pad))
		theme.set_stylebox(&"tab_unselected", type, _tab("tab_unselected", pad))
		theme.set_stylebox(&"tab_hovered", type, _tab("tab_hover", pad))
		theme.set_stylebox(&"tab_disabled", type, _tab("tab_unselected", pad))
		theme.set_stylebox(&"tab_focus", type, _box("btn_focus", 20, pad, false))
		theme.set_color(&"font_selected_color", type, BRASS_L)
		theme.set_color(&"font_unselected_color", type, MUTED)
		theme.set_color(&"font_hovered_color", type, CREAM)
		theme.set_font_size(&"font_size", type, 28)
		theme.set_constant(&"h_separation", type, 8)
	theme.set_stylebox(&"panel", &"TabContainer", _box("panel_inset", 18, [18, 14, 18, 14]))
	theme.set_stylebox(&"tabbar_background", &"TabContainer", empty)


## One StyleBoxTexture: `margin` is the 9-slice edge in texture pixels, `content` = [l, t, r, b] padding.
func _box(sprite: String, margin: int, content: Array, centre := true) -> StyleBoxTexture:
	var s := StyleBoxTexture.new()
	s.texture = load(UI + sprite + ".svg")
	s.set_texture_margin_all(margin)
	s.content_margin_left = content[0]
	s.content_margin_top = content[1]
	s.content_margin_right = content[2]
	s.content_margin_bottom = content[3]
	s.draw_center = centre
	return s


func _tab(sprite: String, content: Array) -> StyleBoxTexture:
	var s := _box(sprite, 18, content)
	s.texture_margin_bottom = 4
	return s


func _variation(type: StringName, base: StringName, o: Dictionary) -> void:
	theme.set_type_variation(type, base)
	theme.set_font_size(&"font_size", type, o.font_size)
	theme.set_color(&"font_color", type, o.color)
	theme.set_constant(&"outline_size", type, o.outline_size)
	if o.has("outline"):
		theme.set_color(&"font_outline_color", type, o.outline)
