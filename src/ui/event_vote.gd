class_name EventVote
extends Control
## The three-card Intermission vote (docs/plan/03 §3.2). Cards are touch-sized; a single-card offer is a
## forced scripted_first Event: shown as an announcement, nothing to press.

const CARD_MIN_SIZE := Vector2(220.0, 120.0)  # >= ~9 mm on a phone

@export var scheduler: EventScheduler
@export var game_loop: GameLoop

var _left := 0.0

@onready var _title: Label = %Title
@onready var _cards: HBoxContainer = %Cards
@onready var _clock: Label = %Clock


func _ready() -> void:
	visible = false
	set_process(false)
	if scheduler != null:
		scheduler.event_offer_ready.connect(_on_offer)
		scheduler.event_applied.connect(_close.unbind(3))
	if game_loop != null:
		game_loop.round_started.connect(_close.unbind(3))


func _process(delta: float) -> void:
	_left = maxf(_left - delta, 0.0)
	_clock.text = "%d s" % ceili(_left)


func _on_offer(round_index: int, _tier: int, event_ids: Array[StringName]) -> void:
	for c in _cards.get_children():
		c.queue_free()
	var forced := event_ids.size() == 1
	_title.text = "Round %d — coming up" % round_index if forced else "Round %d — pick the hazard" % round_index
	for id in event_ids:
		var e := FxCatalog.event(id)
		var card := Button.new()
		card.custom_minimum_size = CARD_MIN_SIZE
		card.disabled = forced
		card.text = "%s\n×%.2f reward\n%+d s" % [e.display_name, e.reward_mult, roundi(e.round_time_add_sec)]
		card.pressed.connect(_vote.bind(id))
		_cards.add_child(card)
	_left = EventScheduler.VOTE_TIMEOUT_SEC
	_clock.visible = not forced
	visible = true
	set_process(not forced)


func _vote(id: StringName) -> void:
	scheduler.submit_event_vote.rpc_id(1, id)
	for card in _cards.get_children():
		(card as Button).disabled = true
	_title.text = "Voted — waiting for the crew"


func _close() -> void:
	visible = false
	set_process(false)
