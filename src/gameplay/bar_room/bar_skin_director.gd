class_name BarSkinDirector
extends Node
## The bar's look for the current Round (06 P18). Whenever the (Night, Round) changes the host picks one crew
## member's equipped bar skin and broadcasts it; every peer recolours the room and the felt. The pick is seeded
## from the campaign, so a resumed checkpoint reproduces it, and a peer back from the background gets it re-sent.

signal skin_applied(skin: BarSkin, owner_peer: int)

const SALT := 0x5b1d  ## keeps this seed apart from the stock key's hash of the same numbers

@export var game_loop: GameLoop
@export var bar_room: BarRoom
@export var table: Table

var current: BarSkin  ## what this peer shows now; null until the host's first pick arrives
var current_owner := 0  ## peer id of the crew member whose skin it is

var _key := 0  ## host: hash of the (Night, Round) last picked for
var _picked := false


func _ready() -> void:
	game_loop.phase_changed.connect(func(_p: GameLoop.Phase) -> void: _on_phase())


## The roster entry whose bar skin a (Night, Round) shows: uniform over the crew, one pick per player.
static func pick_entry(roster: Array, key: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = key
	return roster[rng.randi() % roster.size()]


static func round_key(campaign_seed: int, night: int, round_index: int) -> int:
	return hash([campaign_seed, night, round_index, SALT])


func _on_phase() -> void:
	if not game_loop.is_host():
		return
	var key := round_key(game_loop.campaign_seed, game_loop.current_night().night_number, game_loop.round_index)
	if _picked and key == _key:
		return
	_picked = true
	_key = key
	var roster: Array = get_node(^"/root/NetManager").call(&"get_roster")
	if roster.is_empty():
		return
	var e := pick_entry(roster, key)
	apply_bar_skin.rpc(e.bar_skin, e.peer_id, true)


## Host: a client came back from the background (RoundDirector.send_full_state); the room it missed is re-sent, silently.
func resync_peer(peer_id: int) -> void:
	if current != null:
		apply_bar_skin.rpc_id(peer_id, current.id, current_owner, false)


@rpc("authority", "call_local", "reliable", 3)
func apply_bar_skin(skin_id: StringName, owner_peer: int, announce: bool) -> void:
	current = SkinCatalog.resolve_bar(skin_id)
	current_owner = owner_peer
	bar_room.apply_skin(current)
	table.set_felt_color(current.felt_color)
	skin_applied.emit(current, owner_peer)
	if announce:
		_toast("Tonight's bar: %s (%s's)" % [current.display_name, _name_of(owner_peer)])


func _name_of(peer_id: int) -> String:
	for e: Dictionary in get_node(^"/root/NetManager").call(&"get_roster"):
		if e.peer_id == peer_id:
			return e.name
	return "?"


## UIRouter.toast when the router exists (ui slice), else the log.
func _toast(text: String) -> void:
	var router := get_tree().get_first_node_in_group(&"ui_router")
	if router != null and router.has_method(&"toast"):
		router.call(&"toast", text, &"info")
	else:
		print(text)
