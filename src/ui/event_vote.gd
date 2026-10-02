class_name EventVote
extends UIModal
## The three-card Intermission vote (docs/plan/03 §3.2) as a modal of its own: it opens when the offer arrives, shows
## over the Intermission screen and closes when the vote resolves for this peer (a pick, the 20 s clock, the Event
## applying, the phase leaving Intermission). A single-card offer is a forced scripted_first Event: an announcement.

const CARD_MIN_SIZE := Vector2(220.0, 120.0)  # >= ~9 mm on a phone

@export var scheduler: EventScheduler
@export var game_loop: GameLoop

var _left := 0.0

@onready var _title: Label = %Title
@onready var _cards: HBoxContainer = %Cards
@onready var _clock: Label = %Clock
@onready var _ok: Button = %Ok


func _ready() -> void:
	super()
	priority = 20
	dismissable = false  # an unvoted offer cannot be closed with Esc: Esc opens Pause over it
	keep_on_phase = true  # the offer can land just before the phase signal; round_started / a phase change close it below
	set_process(false)
	_ok.pressed.connect(close)
	if scheduler != null:
		scheduler.event_offer_ready.connect(_on_offer)
		scheduler.event_applied.connect(close.unbind(3))
	if game_loop != null:
		game_loop.round_started.connect(close.unbind(3))
		game_loop.phase_changed.connect(func(phase: GameLoop.Phase) -> void:
			if phase != GameLoop.Phase.INTERMISSION:
				close())


func _process(delta: float) -> void:
	_left = maxf(_left - delta, 0.0)
	_clock.text = "%d s" % ceili(_left)
	if _left == 0.0:  # the host resolves at the same instant: no vote = the host's pick, else the first card
		close()


func _on_close() -> void:
	set_process(false)


func _on_offer(round_index: int, _tier: int, event_ids: Array[StringName]) -> void:
	for c in _cards.get_children():
		c.queue_free()
	var forced := event_ids.size() == 1
	_title.text = "Round %d: coming up" % round_index if forced else "Round %d: pick the hazard" % round_index
	for id in event_ids:
		var e := FxCatalog.event(id)
		var card := Button.new()
		card.custom_minimum_size = CARD_MIN_SIZE
		card.disabled = forced
		card.text = "%s\n×%.2f reward\n%+d s" % [e.display_name, e.reward_mult, roundi(e.round_time_add_sec)]
		card.pressed.connect(_vote.bind(id, e.display_name))
		_cards.add_child(card)
	_left = EventScheduler.VOTE_TIMEOUT_SEC
	_clock.visible = not forced
	_ok.visible = forced
	open()
	set_process(not forced)


func _vote(id: StringName, display_name: String) -> void:
	scheduler.submit_event_vote.rpc_id(1, id)
	close()  # first: the router drops toasts while a modal is open
	if UIRouter.instance != null:
		UIRouter.instance.toast("Voted: %s" % display_name, &"good")
