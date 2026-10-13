class_name StoryDirector
extends Node
## The story's one director (docs/plan/09 §4.1): presentation only, it changes no rule. It runs on every peer from the same
## GameLoop signals and owns four things: the Night's intro cards (local, once per Night per campaign per player), the
## ringing phone and Moe's call, Gus's story pool, and velvet's one stream-chat line per Night. The only state two peers must
## agree on is "this Night's call was answered": it rides the host-validated `answer_phone` interaction
## (`world_interaction_applied`), and the host replays it to a peer that comes back from the background (E7, 06 P29).

const CHAT_DELAY_SEC := 15.0  ## [tune] velvet's line, after Round 1 of a Night goes live
const CALL_GAP_SEC := 0.7  ## between two lines of the call
const MOE_SLOW := 1.4  ## Moe's subtitles stay up as much longer as his syllables are (09 §3.2)

@export var game_loop: GameLoop
@export var world: WorldInteractions
@export var cards: StoryCards

var ringing := false  ## the phone rings now (the first Intermission of a Night, until someone answers or the Round goes live)
var answered := false  ## this Night's call was picked up, by anyone
var calling := false  ## Moe is on speaker
var velvet_shown := 0  ## stream-chat lines shown since the level loaded, for probes

var _call: Array[String] = []
var _call_i := -1
var _call_left := 0.0
var _chat_text := ""
var _chat_in := -1.0
var _chat_pending := false  ## the line is due but a modal is open (a toast would sit under its dim)
var _away := {}  ## host: peer id -> was in the background at the last check


func _ready() -> void:
	add_to_group(&"story_director")
	set_process(false)
	if game_loop != null:
		game_loop.night_started.connect(_on_night_started)
		game_loop.intermission_started.connect(_on_intermission)
		game_loop.phase_changed.connect(_on_phase_changed)
		game_loop.round_started.connect(_on_round_started)
	if world != null:
		world.interaction_applied.connect(_on_interaction)
	var net := get_node_or_null(^"/root/NetManager")  # by path: `-s` probes compile before autoload names exist
	if net != null:
		net.connect(&"peers_away_changed", _on_peers_away_changed)
	_bind_router.call_deferred()


func _bind_router() -> void:
	if UIRouter.instance != null:
		UIRouter.instance.modal_changed.connect(_on_modal_changed)


# --- host validation (WorldInteractions asks) -----------------------------------------------------------------------------------

## Why `answer_phone` is refused right now, or &"" when it may go through.
func answer_block() -> StringName:
	if answered:
		return &"already_answered"
	if not ringing:
		return &"not_ringing"
	return &""


## Host: a client's app came back from the background (RoundDirector.send_full_state, or `peers_away_changed` below, which
## also fires before the first Round when send_full_state has nothing to send): it gets the answered flag, silently.
func resync_peer(peer_id: int) -> void:
	if game_loop == null or not game_loop.is_host() or not answered or world == null:
		return
	world.world_interaction_applied.rpc_id(peer_id, 1, &"answer_phone", 0, {&"replay": true})


func _on_peers_away_changed() -> void:
	var net := get_node_or_null(^"/root/NetManager")
	if net == null or game_loop == null or not game_loop.is_host():
		return
	for id in multiplayer.get_peers():
		var away := bool(net.call(&"is_peer_away", id))
		if bool(_away.get(id, false)) and not away:
			resync_peer(id)
		_away[id] = away


# --- the Night ------------------------------------------------------------------------------------------------------------------

func _on_night_started(night_number: int, _quota: int) -> void:
	answered = SaveManager.story_called(game_loop.campaign_seed).has(night_number)  # a resumed Night-start stays quiet
	_end_call()
	_ring(false)
	_feed_gus()
	var story := _story()
	if story == null or cards == null or story.intro_cards.is_empty():
		return
	if game_loop.round_index != 0:  # a resume always lands on a Round boundary: the intro is never replayed mid-Night
		return
	var seen := SaveManager.story_seen(game_loop.campaign_seed)
	if seen.has(night_number):
		return
	seen.append(night_number)
	SaveManager.save_story_seen(game_loop.campaign_seed, seen)
	cards.show_cards(story.intro_cards)


func _on_intermission() -> void:
	_feed_gus()  # a peer that joined after night_started never saw it
	var story := _story()
	if game_loop.round_index != 0 or answered or story == null or story.call.is_empty():
		return
	_ring(true)


func _on_phase_changed(phase: GameLoop.Phase) -> void:
	if ringing and phase != GameLoop.Phase.INTERMISSION:  # the Round went live and nobody picked up
		_ring(false)
		var gus := _bartender()
		if gus != null:
			gus.chat.say_from(&"phone_ignored", game_loop.current_night().night_number)
	if phase == GameLoop.Phase.CAMPAIGN_WON:
		var story := _story()
		if story != null and cards != null and not story.ending_cards.is_empty():
			cards.show_cards(story.ending_cards)  # the Campaign won screen waits underneath and returns when they close


func _on_round_started(round_index: int, _time_limit: float, _hazard_tier: int) -> void:
	var story := _story()
	if round_index != 1 or story == null or story.chat_line == "":
		return
	_chat_text = story.chat_line
	_chat_in = CHAT_DELAY_SEC
	set_process(true)


# --- the phone ------------------------------------------------------------------------------------------------------------------

func _ring(on: bool) -> void:
	ringing = on
	var phone := _phone()
	if phone != null:
		phone.set_ringing(on)


func _on_interaction(_peer_id: int, kind: StringName, _target_id: int, payload: Dictionary) -> void:
	if kind != &"answer_phone":
		return
	answered = true
	_ring(false)
	var night := game_loop.current_night().night_number
	var called := SaveManager.story_called(game_loop.campaign_seed)
	if not called.has(night):
		called.append(night)
		SaveManager.save_story_called(game_loop.campaign_seed, called)
	if bool(payload.get(&"replay", false)):  # a peer that came back late: it only learns the phone is quiet
		return
	_start_call()


func _start_call() -> void:
	var story := _story()
	if story == null or story.call.is_empty():
		return
	_call = story.call.duplicate()
	_call_i = -1
	calling = true
	var total := 0.0
	for line in _call:
		total += _line_sec(line) + CALL_GAP_SEC
	var gus := _bartender()
	if gus != null:
		gus.chat.hold(total)  # Gus stays quiet while the call plays
	_next_line()


func _next_line() -> void:
	_call_i += 1
	if _call_i >= _call.size():
		_end_call()
		return
	_call_left = _line_sec(_call[_call_i]) + CALL_GAP_SEC
	var phone := _phone()
	if phone != null:
		phone.say(_call[_call_i], _line_sec(_call[_call_i]))
	set_process(true)


func _end_call() -> void:
	if not calling:
		return
	calling = false
	_call_i = -1
	var gus := _bartender()
	if gus != null:
		gus.chat.release_hold()


func _line_sec(line: String) -> float:
	return BartenderChat.line_seconds(line) * MOE_SLOW


func _process(delta: float) -> void:
	if calling:
		_call_left -= delta
		if _call_left <= 0.0:
			_next_line()
	if _chat_in > 0.0:
		_chat_in -= delta
		if _chat_in <= 0.0:
			_chat_in = -1.0
			_chat_pending = true
			_show_chat()
	set_process(calling or _chat_in > 0.0)


# --- velvet ---------------------------------------------------------------------------------------------------------------------

func _on_modal_changed(open: bool) -> void:
	if not open and _chat_pending:
		_show_chat()


## One stream-chat line, a toast: held back while a modal is open and shown when the last one closes.
func _show_chat() -> void:
	var router := UIRouter.instance
	if router == null or router.is_modal_open():
		return
	_chat_pending = false
	router.toast("velvet: " + _chat_text)
	velvet_shown += 1


# --- Gus ------------------------------------------------------------------------------------------------------------------------

## The story lines unlocked so far, in telling order: Night 1's up to this Night's (Endless keeps all three).
func _feed_gus() -> void:
	var gus := _bartender()
	if gus == null or game_loop == null or game_loop.nights.is_empty():
		return
	var lines: Array[String] = []
	for i in mini(game_loop.night_index, game_loop.nights.size() - 1) + 1:
		var s := game_loop.nights[i].story
		if s != null:
			lines.append_array(s.gus_lines)
	gus.chat.set_story_pool(lines)


func _story() -> StoryNight:
	if game_loop == null or game_loop.nights.is_empty():
		return null
	return game_loop.current_night().story


func _bartender() -> Bartender:
	return get_tree().get_first_node_in_group(&"bartender") as Bartender


func _phone() -> Phone:
	return get_tree().get_first_node_in_group(&"story_phone") as Phone
