class_name DebugRoot
extends Node3D

## Dev-only debug layer (04 §4, T2.1). Instanced as `Debug` in MainLevel.tscn. F-keys for the desktop, plus debug mode
## (Settings toggle, strip + panel, touch-sized) for the phone.
## `if not OS.is_debug_build(): queue_free()` — a release export template runs with
## is_debug_build() == false and never builds this subtree; there is no release export
## profile in this repo yet (out of scope, intent.md), so the false path is verified by
## this guard + code inspection rather than a built template (contract T2.1 note).
## Gameplay code never references src/debug (grep -r "debug" src/gameplay is empty);
## this script only calls Table.rebuild()/rack.spawn_layout()/Ball.strike() — all
## consumer-facing gameplay API, and toggles built-in Node process flags on the local Player
## subtree (no new fields, no edits to src/gameplay files) so the free camera can take over.

@export var table: Table
@export var rack: Node3D  # DemoRack
@export var spawner: PlayerSpawner  # finds the local walker; slots spawn after Debug is ready

const TIMESCALE_STEPS := [1.0, 0.5, 0.25, 0.1, 2.0]

var session: DebugSession
var panel: DebugPanel
var strip: DebugStrip

var _hud: DebugHud
var _freecam: DebugFreeCamera
var _gizmos: DebugGizmos
var _spec_panel: DebugSpecPanel
var _shot_console: DebugShotConsole
var _net_graph: NetGraph
var _rack_presets := DebugRackPresets.new()
var _timescale_index := 0


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return

	_hud = DebugHud.new()
	_hud.table = table
	_hud.visible = false
	add_child(_hud)

	_freecam = DebugFreeCamera.new()
	add_child(_freecam)

	_gizmos = DebugGizmos.new()
	_gizmos.table = table
	_gizmos.visible = false
	add_child(_gizmos)

	_spec_panel = DebugSpecPanel.new()
	_spec_panel.table = table
	_spec_panel.rack = rack
	_spec_panel.visible = false
	add_child(_spec_panel)

	_net_graph = preload("res://src/debug/NetGraph.tscn").instantiate()
	_net_graph.table = table
	add_child(_net_graph)

	_shot_console = DebugShotConsole.new()
	_shot_console.table = table
	_shot_console.visible = false
	add_child(_shot_console)
	_build_mode()


## Debug mode (Settings "Debug mode", phones included): the strip in the top bar and the drawer panel behind it, both over
## one DebugSession wired to the Round's own nodes (siblings in MainLevel). No session without a RoundDirector.
func _build_mode() -> void:
	var level := get_parent()
	var director := level.get_node_or_null("RoundDirector") as RoundDirector
	if director == null:
		return
	session = DebugSession.new()
	session.table = table
	session.director = director
	session.game_loop = level.get_node_or_null("GameLoop") as GameLoop
	session.economy = level.get_node_or_null("EconomyManager") as EconomyManager
	session.effects = level.get_node_or_null("EffectManager") as EffectManager
	add_child(session)
	session.start()
	var layer := CanvasLayer.new()
	layer.layer = 12
	add_child(layer)
	panel = DebugPanel.new()
	panel.session = session
	panel.debug_root = self
	layer.add_child(panel)
	strip = DebugStrip.new()
	strip.session = session
	strip.panel = panel
	add_child(strip)
	add_to_group(Settings.GROUP)
	_on_settings_changed()


## Settings listener: the strip follows "Debug mode"; the first time it is on, a saved tuning is applied.
func _on_settings_changed() -> void:
	if strip == null:
		return
	var on: bool = Settings.value(&"debug_mode")
	var was := strip.visible
	strip.visible = on
	if on and not was and session.load_tuning():
		session.said.emit("saved physics tuning applied")
	if not on and panel.visible:
		panel.close()


## View switches (panel and keys): "hud", "gizmos", "netgraph", "freecam".
func set_view(view: String, on: bool) -> void:
	match view:
		"hud": _hud.visible = on
		"gizmos": _gizmos.visible = on
		"netgraph": _net_graph.visible = on
		"freecam":
			if _freecam.player == null:
				_freecam.player = spawner.get_local_player()
			if _freecam.player != null and _freecam.active != on:
				_freecam.toggle()
				_refresh_mouse_mode()


func set_timescale(scale: float) -> void:
	Engine.time_scale = scale


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_hud"):
		_hud.visible = not _hud.visible
	elif event.is_action_pressed("debug_freecam"):
		set_view("freecam", not _freecam.active)
	elif event.is_action_pressed("debug_netgraph"):
		_net_graph.visible = not _net_graph.visible
	elif event.is_action_pressed("debug_gizmos"):
		_gizmos.visible = not _gizmos.visible
	elif event.is_action_pressed("debug_spec"):
		_spec_panel.visible = not _spec_panel.visible
		if _spec_panel.visible:
			_spec_panel.refresh()
		_refresh_mouse_mode()
	elif event.is_action_pressed("debug_console"):
		_shot_console.visible = not _shot_console.visible
		_refresh_mouse_mode()
	elif event.is_action_pressed("debug_timescale"):
		_timescale_index = (_timescale_index + 1) % TIMESCALE_STEPS.size()
		Engine.time_scale = TIMESCALE_STEPS[_timescale_index]
	elif event.is_action_pressed("debug_rack_next"):
		rack.spawn_layout(_rack_presets.next(table.spec))


## Any interactive panel wins mouse focus over the player's own capture-on-click (player.gd);
## otherwise mouse mode follows whichever of freecam/player currently owns look control.
func _refresh_mouse_mode() -> void:
	if _spec_panel.visible or _shot_console.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
