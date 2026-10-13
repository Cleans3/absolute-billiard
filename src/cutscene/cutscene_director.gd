class_name CutsceneDirector
extends Node
## MainLevel/CutsceneDirector (docs/plan/09 §3.8, §4.4, 04 §5, adhoc-1013c F3b): plays the story's cutscenes in the real level, on every peer, and
## keeps the crew together. A cutscene is LOCAL presentation; what the peers share is when it starts and when the host may act:
##   * the intro starts a FRESH run (never a Resume): the host picks the campaign seed, `cutscene_cue` (reliable, host -> all, call_local) starts
##     `CutscenePlayer` `intro` everywhere, every peer acks with `cutscene_ack` (reliable, peer -> host) when its copy ends or is skipped, and the
##     host starts Night 1 when every connected peer that is not in the background has acked, or after `CutscenePlayer.max_wait_sec(&"intro")`.
##   * the endings start from the PHASE each peer already sees: GAME_OVER plays `fail` (red alert, black screens, bloody mirror, the Trapdoor, the
##     fall) and then the run's stats card on black; CAMPAIGN_WON plays `win` (green light, Gus cheers, the vent's gas) and then the truck with the
##     stats card. Each peer's Continue acks to the host; the host then leaves the session to the main menu after every ack or END_GRACE_SEC; a
##     client leaves right after its own Continue. No rpc for these: nothing but the phase is shared.
## A peer that was in the background (or is just back from it) does not replay: the intro acks at once, an ending goes straight to its last screen.
## `skip_cutscenes` (static; true in a headless run, set by SoloSupport.until_playable, the playtest bot, the debug panel) turns all of it off, and
## the old end screens (PhaseScreen) and ending cards (StoryDirector) come back, so every probe that predates the cutscenes is unchanged.
## Never name `NetManager` as an identifier here: a `-s` probe compiles this script before the autoload exists.

const END_GRACE_SEC := 20.0  ## [tune] the host waits this long after its own Continue for the others' before it leaves
const LATE_MSEC := 10000  ## a phase that arrives this soon after the app came back from the background is not played
const MOUTH_SCENE := "res://src/cutscene/MonsterMouth.tscn"
const HIDE_PATHS: Array[NodePath] = [^"UILayer/HUD", ^"UILayer/TouchControls"]  ## tagged `cutscene_hides`
const DROP_HEIGHT := Trapdoor.SHAFT_DEPTH + Player.EYE_M  ## FallCam starts at head height above the floor, this far above the lip

static var skip_cutscenes := DisplayServer.get_name() == "headless"
static var manual_clock := false  ## probes / the preview tool: the cutscenes only move when stepped by hand

@export var game_loop: GameLoop

var level: Node  ## the MainLevel root (the parent unless set)
var cutscenes: CutscenePlayer
var leave_handler := Callable()  ## probes: called instead of NetManager.leave()
var card: CutsceneShell  ## the stats card on black, once the failure's fall is over

var _net: Node
var _acks := {}  ## StringName id -> {peer_id: true}
var _waiting := false
var _wait_id := &""
var _wait_left := 0.0
var _wait_then := Callable()
var _ending := &""
var _over := false
var _mouth: MonsterMouth
var _crew: Array = []
var _card_layer: CanvasLayer
var _resumed_msec := -1000000


## True when the endings are cutscenes: PhaseScreen then shows no Game over / Campaign won screen, StoryDirector no ending cards.
static func plays_endings() -> bool:
	return not skip_cutscenes


func _ready() -> void:
	add_to_group(&"cutscene_director")
	if level == null:
		level = get_parent()
	cutscenes = CutscenePlayer.new()
	cutscenes.name = "Cutscenes"
	add_child(cutscenes)
	cutscenes.played.connect(_on_played)
	for path in HIDE_PATHS:
		var n: Node = level.get_node_or_null(path) if level != null else null
		if n != null:
			n.add_to_group(Cutscene.HIDE_GROUP)
	if game_loop != null:
		game_loop.phase_changed.connect(_on_phase)
	_net = get_node_or_null(^"/root/NetManager")
	if _net != null:
		_net.connect(&"app_resumed", func() -> void: _resumed_msec = Time.get_ticks_msec())
	set_process(false)


func is_busy() -> bool:
	return cutscenes.is_playing() or card != null or _waiting


# --- the intro: a fresh run ---------------------------------------------------------------------------------------------------------

## Host. Plays the intro on every peer, then calls `begin(seed)` (MainLevel's start_campaign) once they have all acked or the wait ran out.
## With cutscenes skipped it calls `begin(0)` at once (0 = a fresh seed).
func start_run(begin: Callable) -> void:
	if skip_cutscenes:
		begin.call(0)
		return
	var seed_value := randi() | 1
	_open_wait(&"intro", CutscenePlayer.max_wait_sec(&"intro"), func() -> void: begin.call(seed_value))
	cutscene_cue.rpc(&"intro", seed_value)


## Host -> everyone (04 §5): start `id` (the intro) now, dressed by `seed_value`.
@rpc("authority", "call_local", "reliable", 3)
func cutscene_cue(id: StringName, seed_value: int) -> void:
	var opts := _opts(seed_value)
	if _is_late():
		opts["instant"] = true
	if not cutscenes.play(id, opts):
		_send_ack(id)  # busy or unknown: the host must not wait on us


## Peer -> host (04 §5): my copy of `id` is over (it ended, or I skipped it); for an ending, I pressed Continue.
@rpc("any_peer", "call_remote", "reliable", 3)
func cutscene_ack(id: StringName) -> void:
	if _is_host():
		_record_ack(id, multiplayer.get_remote_sender_id())


func _send_ack(id: StringName) -> void:
	if _is_host():
		_record_ack(id, 1)
		if _waiting and UIRouter.instance != null:
			UIRouter.instance.toast("Waiting for the crew...")
	else:
		cutscene_ack.rpc_id(1, id)


# --- the host's wait ----------------------------------------------------------------------------------------------------------------

func _open_wait(id: StringName, seconds: float, then: Callable) -> void:
	if not _acks.has(id):
		_acks[id] = {}  # acks that came in before the host got here (a faster client's Continue) are kept
	_waiting = true
	_wait_id = id
	_wait_left = seconds
	_wait_then = then
	set_process(true)


func _record_ack(id: StringName, peer_id: int) -> void:
	if not _acks.has(id):
		_acks[id] = {}
	(_acks[id] as Dictionary)[peer_id] = true
	_check_wait()


func _process(delta: float) -> void:
	if not _waiting:
		set_process(false)
		return
	_wait_left -= delta * Cutscene.time_scale
	_check_wait()


## Done when every connected peer that is not in the background has acked (the host included), or the time is up.
func _check_wait() -> void:
	if not _waiting:
		return
	var got: Dictionary = _acks.get(_wait_id, {})
	var all := true
	for peer_id in _expected():
		if not got.has(peer_id):
			all = false
	if all or _wait_left <= 0.0:
		_waiting = false
		set_process(false)
		var then := _wait_then
		_wait_then = Callable()
		if then.is_valid():
			then.call()


func _expected() -> PackedInt32Array:
	var out := PackedInt32Array([1])
	for peer_id in multiplayer.get_peers():
		if _net == null or not bool(_net.call(&"is_peer_away", peer_id)):
			out.append(peer_id)
	return out


# --- what each scene is given -------------------------------------------------------------------------------------------------------

func _opts(seed_value: int) -> Dictionary:
	var roster: Array = []
	if _net != null:
		roster = (_net.call(&"get_roster") as Array).duplicate()
	roster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seat) < int(b.seat))
	var skins: Array[CharacterSkin] = []
	for e: Dictionary in roster:
		skins.append(SkinCatalog.resolve_character(StringName(str(e.get("char_skin", ""))), int(e.seat)))
	var opts := {"seed": seed_value, "crew_size": maxi(roster.size(), 1), "skins": skins, "level": level}
	if manual_clock:
		opts["manual"] = true
	return opts


func _is_host() -> bool:
	return _net != null and bool(_net.call(&"is_host"))


## This app was in the background, or only just came back: the phase it is looking at is old news.
func _is_late() -> bool:
	if _net != null and bool(_net.get(&"backgrounded")):
		return true
	return Time.get_ticks_msec() - _resumed_msec < LATE_MSEC


# --- the endings: from the phase every peer already sees --------------------------------------------------------------------------

func _on_phase(phase: GameLoop.Phase) -> void:
	if skip_cutscenes or game_loop == null:
		return
	if phase == GameLoop.Phase.GAME_OVER:
		_begin_ending.call_deferred(&"fail")
	elif phase == GameLoop.Phase.CAMPAIGN_WON and game_loop.mode == GameLoop.MODE_CAMPAIGN:
		_begin_ending.call_deferred(&"win")


func _begin_ending(id: StringName) -> void:
	if not is_inside_tree() or (_ending != &"" and not _over) or cutscenes.is_playing():
		return  # an ending is already on its way (a Continue pressed frees the way for the next)
	_ending = id
	_over = false
	var late := _is_late()
	var opts := _opts(game_loop.campaign_seed)
	opts["stats"] = game_loop.run_stats.to_dict()
	var story: StoryNight = game_loop.current_night().story
	if id == &"fail":
		_make_mouth()
		_crew = RoomCutscene.crew_of(level)
		opts["mouth"] = _mouth
		opts["drop_height"] = DROP_HEIGHT
		opts["caption"] = "" if story == null else story.short_line
		opts["on_update"] = _fall_bodies
		if late:
			_show_card()
		else:
			cutscenes.play(&"fail", opts)
	else:
		opts["captions"] = [] if story == null else story.ending_cards
		opts["title"] = "Paid in full"
		cutscenes.play(&"truck_outro" if late else &"win", opts)


## The monster waits in the Trapdoor's Pit, hidden until the leaves swing open (FailRoom reveals it).
func _make_mouth() -> void:
	var trap: Trapdoor = null
	if level != null:
		trap = level.get_node_or_null(^"Trapdoor") as Trapdoor
	if _mouth != null or trap == null or trap.pit() == null:
		return
	_mouth = (load(MOUTH_SCENE) as PackedScene).instantiate() as MonsterMouth
	_mouth.visible = false
	trap.pit().add_child(_mouth)


## FallCam's clock drives the real bodies down the shaft (RoomCutscene.drop_member): every peer places every player itself.
func _fall_bodies(time: float) -> void:
	for i in _crew.size():
		RoomCutscene.drop_member(_crew[i], i, _crew.size(), time)


func _on_played(id: StringName, _skipped: bool) -> void:
	match id:
		&"intro":
			_send_ack(&"intro")
		&"fail":
			_show_card()  # in the same frame as FallCam's last (black) one: nothing flashes between
		&"win", &"truck_outro":
			_ending_over(&"win")


## The run's stats on black, full card (A11): FallCam ends on black and this goes up in the same call.
func _show_card() -> void:
	_close_card()
	_card_layer = CanvasLayer.new()
	_card_layer.layer = 100
	add_child(_card_layer)
	card = CutsceneShell.new()
	_card_layer.add_child(card)
	card.skip_button.visible = false
	card.set_fade(1.0)
	card.open()
	var stats := RunStatsCard.make()
	card.add_child(stats)
	stats.show_stats(game_loop.run_stats.to_dict(), "Run over", true, "Continue", false)
	stats.closed.connect(_ending_over.bind(&"fail"))


func _close_card() -> void:
	if card != null and is_instance_valid(card):
		card.close()
	if _card_layer != null and is_instance_valid(_card_layer):
		_card_layer.queue_free()
	card = null
	_card_layer = null


## This peer pressed Continue on its last screen. A client tells the host and leaves; the host waits for the others' Continue (or END_GRACE_SEC)
## and then leaves, so nobody is dropped off a card they are still reading. Solo: leaves at once.
func _ending_over(id: StringName) -> void:
	if _over:
		return
	_over = true
	if _is_host():
		_open_wait(id, END_GRACE_SEC, _leave)
		_record_ack(id, 1)
	else:
		cutscene_ack.rpc_id(1, id)
		_leave_later()


func _leave_later() -> void:
	await get_tree().process_frame  # let the ack out before the connection goes
	await get_tree().process_frame
	_leave()


func _leave() -> void:
	if leave_handler.is_valid():
		leave_handler.call()
	elif _net != null:
		_net.call(&"leave")
