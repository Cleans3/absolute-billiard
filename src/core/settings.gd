class_name Settings
extends RefCounted
## Player settings and key bindings (docs/plan/06 P11), one static store persisted to `user://settings.cfg`.
## `load_all()` runs once at boot (NetManager._ready); `set_value` applies at once and tells every node in the
## `settings_listener` group (`_on_settings_changed()`); callers `save()` when a change is final (slider released, toggle).
## Bindings keep ONE physical key or mouse button per action; a clash swaps the two actions' bindings.

const GROUP := &"settings_listener"
const QUALITY: Array[StringName] = [&"auto", &"high", &"medium", &"low"]  ## high/medium/low = QualityManager tier 0/1/2

const DEFAULTS := {
	&"master_volume": 1.0,
	&"quality": &"auto",
	&"fov": 75.0,
	&"mouse_sens": 1.0,        ## multipliers on today's tuned rates (Player / CueController exports)
	&"touch_look_sens": 1.0,
	&"cue_aim_sens": 1.0,
	&"invert_y": false,
	&"touch_mirror": false,
	&"show_fps": false,
}
const RANGES := {  ## [min, max, step] for the sliders; `set_value` clamps to it
	&"master_volume": [0.0, 1.0, 0.05],
	&"fov": [60.0, 110.0, 1.0],
	&"mouse_sens": [0.25, 3.0, 0.05],
	&"touch_look_sens": [0.25, 3.0, 0.05],
	&"cue_aim_sens": [0.25, 3.0, 0.05],
}
## Every keyboard / mouse gameplay action (project.godot minus debug_*). `reset` is dormant (DemoRack, disabled) so it is not listed.
const ACTIONS: Array[Dictionary] = [
	{group = "Walk", action = &"move_forward", label = "Move forward"},
	{group = "Walk", action = &"move_back", label = "Move back"},
	{group = "Walk", action = &"move_left", label = "Move left"},
	{group = "Walk", action = &"move_right", label = "Move right"},
	{group = "Walk", action = &"jump", label = "Jump"},
	{group = "Walk", action = &"interact", label = "Use / interact"},
	{group = "Cue", action = &"cue_mode", label = "Take cue / back"},
	{group = "Cue", action = &"shoot", label = "Charge and shoot"},
	{group = "Cue", action = &"spin_up", label = "Spin up"},
	{group = "Cue", action = &"spin_down", label = "Spin down"},
	{group = "Cue", action = &"spin_left", label = "Spin left"},
	{group = "Cue", action = &"spin_right", label = "Spin right"},
	{group = "Cue", action = &"elevate_up", label = "Raise cue"},
	{group = "Cue", action = &"elevate_down", label = "Lower cue"},
	{group = "Cue", action = &"spin_reset", label = "Reset spin"},
	{group = "Call pocket", action = &"call_pocket_1", label = "Pocket 1"},
	{group = "Call pocket", action = &"call_pocket_2", label = "Pocket 2"},
	{group = "Call pocket", action = &"call_pocket_3", label = "Pocket 3"},
	{group = "Call pocket", action = &"call_pocket_4", label = "Pocket 4"},
	{group = "Call pocket", action = &"call_pocket_5", label = "Pocket 5"},
	{group = "Call pocket", action = &"call_pocket_6", label = "Pocket 6"},
]
const MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "Mouse left", MOUSE_BUTTON_RIGHT: "Mouse right", MOUSE_BUTTON_MIDDLE: "Mouse middle",
	MOUSE_BUTTON_WHEEL_UP: "Wheel up", MOUSE_BUTTON_WHEEL_DOWN: "Wheel down",
	MOUSE_BUTTON_XBUTTON1: "Mouse 4", MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}

static var path := "user://settings.cfg"  ## probes point this at a scratch file
static var _data: Dictionary = DEFAULTS.duplicate()
static var _default_events: Dictionary = {}  ## action -> Array[InputEvent] as project.godot ships them
static var _loaded := false


static func value(key: StringName) -> Variant:
	_ensure()
	return _data[key]


## Clamps, applies, notifies. Does not write the file: call `save()` once the change is final.
static func set_value(key: StringName, v: Variant) -> void:
	_ensure()
	if RANGES.has(key):
		var r: Array = RANGES[key]
		v = clampf(float(v), r[0], r[1])
	if key == &"quality" and not QUALITY.has(v):
		v = DEFAULTS[key]
	_data[key] = v
	_apply()
	_notify()


## -1 = Auto (the QualityLadder runs), else the fixed QualityManager tier.
static func quality_tier() -> int:
	return QUALITY.find(value(&"quality")) - 1


static func load_all() -> void:
	_loaded = false
	_ensure()
	_apply()
	_notify()


static func save() -> void:
	_ensure()
	var cfg := ConfigFile.new()
	for k: StringName in DEFAULTS:
		cfg.set_value("settings", k, _data[k])
	for a in action_names():
		var sigs := _signatures(InputMap.action_get_events(a))
		if sigs != _signatures(_default_events[a]):
			cfg.set_value("bindings", a, sigs)
	cfg.save(path)


static func reset_values() -> void:
	_ensure()
	_data = DEFAULTS.duplicate()
	_apply()
	_notify()


# --- bindings -----------------------------------------------------------------------------------------

static func action_names() -> Array[StringName]:
	var out: Array[StringName] = []
	for a in ACTIONS:
		out.append(a.action)
	return out


## Binds `event` to `action` alone. Returns the action that held the same key/button (it now has the old
## binding of `action`: a swap), or &"" when nothing clashed or the event is not a key / mouse button.
static func rebind(action: StringName, event: InputEvent) -> StringName:
	_ensure()
	var sig := signature(event)
	if sig == "" or not action_names().has(action):
		return &""
	var clash := &""
	for a in action_names():
		if a != action and _signatures(InputMap.action_get_events(a)).has(sig):
			clash = a
	var old := InputMap.action_get_events(action)
	_set_events(action, [event_from(sig)])
	if clash != &"":
		_set_events(clash, old)
	_notify()
	return clash


static func reset_bindings() -> void:
	_ensure()
	for a in action_names():
		_set_events(a, _default_events[a])
	_notify()


static func binding_text(action: StringName) -> String:
	var events := InputMap.action_get_events(action)
	return event_text(events[0]) if not events.is_empty() else "Unbound"


static func event_text(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code := k.keycode
		if k.physical_keycode != KEY_NONE:  # the keycap name on this layout (AZERTY shows Z for the physical W); no-op headless / on phones
			var layout_aware := DisplayServer.get_name() != "headless" and not OS.has_feature("mobile")
			code = DisplayServer.keyboard_get_keycode_from_physical(k.physical_keycode) if layout_aware else k.physical_keycode
		return OS.get_keycode_string(code if code != KEY_NONE else k.physical_keycode)
	if e is InputEventMouseButton:
		return MOUSE_NAMES.get((e as InputEventMouseButton).button_index, "Mouse %d" % (e as InputEventMouseButton).button_index)
	return "?"


## "key:<physical keycode>" / "mouse:<button>", "" for anything else. Also the on-disk format.
static func signature(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		return "key:%d" % code if code != KEY_NONE else ""
	if e is InputEventMouseButton:
		return "mouse:%d" % (e as InputEventMouseButton).button_index
	return ""


static func event_from(sig: String) -> InputEvent:
	var parts := sig.split(":")
	if parts.size() != 2 or not parts[1].is_valid_int():
		return null
	if parts[0] == "key":
		var k := InputEventKey.new()
		k.physical_keycode = int(parts[1]) as Key
		return k
	if parts[0] == "mouse":
		var m := InputEventMouseButton.new()
		m.button_index = int(parts[1]) as MouseButton
		return m
	return null


# --- internals ----------------------------------------------------------------------------------------

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	if _default_events.is_empty():  # the InputMap is still project.godot's here, the first time only
		for a in action_names():
			_default_events[a] = InputMap.action_get_events(a)
	_data = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		reset_bindings_quiet()
		return
	for k: StringName in DEFAULTS:
		var v: Variant = cfg.get_value("settings", k, DEFAULTS[k])
		if typeof(v) == typeof(DEFAULTS[k]) or (typeof(v) == TYPE_STRING and typeof(DEFAULTS[k]) == TYPE_STRING_NAME):
			_data[k] = v if typeof(v) != TYPE_STRING else StringName(v)
	if not QUALITY.has(_data[&"quality"]):
		_data[&"quality"] = DEFAULTS[&"quality"]
	for k: StringName in RANGES:
		var r: Array = RANGES[k]
		_data[k] = clampf(float(_data[k]), r[0], r[1])
	reset_bindings_quiet()
	if cfg.has_section("bindings"):
		for a in action_names():
			if cfg.has_section_key("bindings", a):
				var events: Array[InputEvent] = []
				for s: String in cfg.get_value("bindings", a, []):
					var e := event_from(s)
					if e != null:
						events.append(e)
				_set_events(a, events)


static func reset_bindings_quiet() -> void:
	for a in action_names():
		_set_events(a, _default_events[a])


static func _set_events(action: StringName, events: Array) -> void:
	InputMap.action_erase_events(action)
	for e: InputEvent in events:
		InputMap.action_add_event(action, e.duplicate())


static func _signatures(events: Array) -> Array:
	var out := []
	for e: InputEvent in events:
		out.append(signature(e))
	return out


static func _apply() -> void:
	var v: float = _data[&"master_volume"]
	AudioServer.set_bus_volume_db(0, linear_to_db(v))
	AudioServer.set_bus_mute(0, v <= 0.001)


static func _notify() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group(GROUP, &"_on_settings_changed")
