class_name GoLivePedestal
extends StaticBody3D
## The GO LIVE button between Rounds (docs/plan/02 §3.1): a pedestal by the table whose label says who has pressed
## and who the start still waits on. The press itself is the `go_live` Interactable Bar puts at the same spot.

const READY_COLOR := Color(0.25, 0.95, 0.35)
const IDLE_COLOR := Color(1.0, 0.15, 0.12)
const OFF_COLOR := Color(0.28, 0.1, 0.1)

@export var game_loop: GameLoop

var prop: Interactable  ## the press target; its prompt follows the ready state

const HINT_TEXT := "Press when you're\nready to play"

@onready var _button: MeshInstance3D = $Button
@onready var _title: Label3D = $Title
@onready var _status: Label3D = $Status
var _glow: StandardMaterial3D
var _hint: Label3D  ## the first-time coach's floating hint (set_hint); built on first use


func _ready() -> void:
	add_to_group(&"go_live_pedestal")
	_glow = (_button.material_override as StandardMaterial3D).duplicate()  # one glow per pedestal; the scene's stays
	_button.material_override = _glow
	if game_loop != null:
		game_loop.ready_changed.connect(_refresh)
		game_loop.phase_changed.connect(func(_p: int) -> void: _refresh())
		game_loop.staging_changed.connect(func(_on: bool) -> void: _refresh())
	_refresh()


func _refresh() -> void:
	var clearing := game_loop != null and game_loop.phase == GameLoop.Phase.INTERMISSION and game_loop.is_staging()  # the last Round's clean-up
	var live := game_loop != null and game_loop.phase == GameLoop.Phase.INTERMISSION and not clearing
	var me := multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else 1
	var mine := live and game_loop.ready_peers.has(me)
	var total := 0 if not live else game_loop.ready_peers.size() + game_loop.waiting_peers.size()
	_set_glow(READY_COLOR if mine else (IDLE_COLOR if live else OFF_COLOR))
	if clearing:
		_status.text = "Table clearing"
	elif not live:
		_status.text = "Opens between Rounds"
	else:
		var lines := PackedStringArray(["Ready %d/%d" % [game_loop.ready_peers.size(), total]])
		if not game_loop.ready_peers.is_empty():
			lines.append("In: " + ", ".join(_names(game_loop.ready_peers)))
		if not game_loop.waiting_peers.is_empty():
			lines.append("Waiting on: " + ", ".join(_names(game_loop.waiting_peers)))
		_status.text = "\n".join(lines)
	if prop == null:
		return
	if clearing:
		prop.prompt = "GO LIVE (the table is clearing)"
	elif not live:
		prop.prompt = "GO LIVE (opens between Rounds)"
	elif mine:
		prop.prompt = "Ready %d/%d · press to cancel" % [game_loop.ready_peers.size(), total]
	else:
		prop.prompt = "GO LIVE"


## The first-time coach (src/ui/coach.gd) floats "Press when you're ready to play" over the button until this player is ready.
## Always on while it applies, not on proximity: a phone has no hover and the button can be off screen.
func set_hint(on: bool) -> void:
	if on and _hint == null:
		_hint = Label3D.new()
		_hint.text = HINT_TEXT
		_hint.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		_hint.pixel_size = 0.004
		_hint.font_size = 64
		_hint.outline_size = 16
		_hint.modulate = Color(1.0, 0.9, 0.35)
		_hint.no_depth_test = true  # readable through the rail and the crowd
		_hint.position = Vector3(0.0, 2.05, 0.0)
		add_child(_hint)
	if _hint != null:
		_hint.visible = on


func _set_glow(c: Color) -> void:
	_glow.albedo_color = c
	_glow.emission = c


func _names(ids: PackedInt32Array) -> PackedStringArray:
	var out := PackedStringArray()
	var net := get_node_or_null(^"/root/NetManager")
	var roster: Array = net.call(&"get_roster") if net != null else []
	for id in ids:
		var label := "Player"
		for e: Dictionary in roster:
			if e.peer_id == id:
				label = e.name
		out.append(label)
	return out
