class_name DebugRoot
extends Node3D

## Dev-only debug layer (04 §4, T2.1). Instanced as `Debug` in MainLevel.tscn.
## `if not OS.is_debug_build(): queue_free()` — a release export template runs with
## is_debug_build() == false and never builds this subtree; there is no release export
## profile in this repo yet (out of scope, intent.md), so the false path is verified by
## this guard + code inspection rather than a built template (contract T2.1 note).
## Gameplay code never references src/debug (grep -r "debug" src/gameplay is empty);
## this script only calls Table.rebuild()/rack.spawn_layout()/Ball.strike() — all
## consumer-facing gameplay API, and toggles built-in Node process flags on the Player
## subtree (no new fields, no edits to src/gameplay files) so the free camera can take over.

@export var table: Table
@export var rack: Node3D  # DemoRack
@export var player: CharacterBody3D

const TIMESCALE_STEPS := [1.0, 0.5, 0.25, 0.1, 2.0]

var _hud: DebugHud
var _freecam: DebugFreeCamera
var _gizmos: DebugGizmos
var _spec_panel: DebugSpecPanel
var _shot_console: DebugShotConsole
var _rack_presets := DebugRackPresets.new()
var _timescale_index := 0


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return

	_hud = DebugHud.new()
	_hud.table = table
	_hud.rack = rack
	_hud.visible = false
	add_child(_hud)

	_freecam = DebugFreeCamera.new()
	_freecam.player = player
	add_child(_freecam)

	_gizmos = DebugGizmos.new()
	_gizmos.table = table
	_gizmos.rack = rack
	_gizmos.visible = false
	add_child(_gizmos)

	_spec_panel = DebugSpecPanel.new()
	_spec_panel.table = table
	_spec_panel.rack = rack
	_spec_panel.visible = false
	add_child(_spec_panel)

	_shot_console = DebugShotConsole.new()
	_shot_console.table = table
	_shot_console.rack = rack
	_shot_console.visible = false
	add_child(_shot_console)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_hud"):
		_hud.visible = not _hud.visible
	elif event.is_action_pressed("debug_freecam"):
		_freecam.toggle()
		_refresh_mouse_mode()
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
		var entries := _rack_presets.next(table.spec)
		if rack.has_method("spawn_layout"):
			rack.spawn_layout(entries)
		elif rack.has_method("spawn"):
			rack.spawn()


## Any interactive panel wins mouse focus over the player's own capture-on-click (player.gd);
## otherwise mouse mode follows whichever of freecam/player currently owns look control.
func _refresh_mouse_mode() -> void:
	if _spec_panel.visible or _shot_console.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
