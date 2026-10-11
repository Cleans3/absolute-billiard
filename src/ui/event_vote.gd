class_name EventVote
extends UIModal
## The three-card Intermission vote (docs/plan/03 §3.2) as a modal of its own: it opens when the offer arrives, shows
## over the Intermission screen and closes when the vote resolves for this peer (a pick, the 20 s clock, the Event
## applying, the phase leaving Intermission). A single-card offer is a forced scripted_first Event: an announcement.

const CARD_MIN_SIZE := Vector2(280.0, 350.0)  # >= ~9 mm on a phone; room for the hazard's icon, name, story line (3 wrapped rows) and numbers
const ICON_SIZE := 92.0

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
		_cards.add_child(_card(id, e, forced))
	_left = EventScheduler.VOTE_TIMEOUT_SEC
	_clock.visible = not forced
	_ok.visible = forced
	open()
	set_process(not forced)


## A button holding the hazard's icon, name, reward multiplier and time change. Its children ignore the mouse, so the
## whole card is the tap target; an announcement (forced Event) is the same card, not greyed, that cannot be pressed.
func _card(id: StringName, e: Event, forced: bool) -> Button:
	var card := Button.new()
	card.custom_minimum_size = CARD_MIN_SIZE
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE if forced else Control.MOUSE_FILTER_STOP
	card.focus_mode = Control.FOCUS_NONE if forced else Control.FOCUS_ALL
	card.pressed.connect(_vote.bind(id, e.display_name))
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.texture = IconCatalog.hazard(e)
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate := PanelContainer.new()
	plate.theme_type_variation = &"PanelInset"
	plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(icon)
	box.add_child(plate)
	# name, the Rope's flavor line under it (09 §3.4, wrapped to the card), then the numbers
	for line: Array in [[e.display_name, &"CardName"], [e.story_line, &"Caption"], ["×%.2f reward" % e.reward_mult, &""], ["%+d s" % roundi(e.round_time_add_sec), &"Caption"]]:
		if line[0] == "":
			continue
		var l := Label.new()
		l.text = line[0]
		l.theme_type_variation = line[1]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if line[0] == e.story_line:
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size = Vector2(CARD_MIN_SIZE.x - 28.0, 0.0)
		box.add_child(l)
	card.add_child(box)
	return card


func _vote(id: StringName, display_name: String) -> void:
	scheduler.submit_event_vote.rpc_id(1, id)
	close()  # first: the router drops toasts while a modal is open
	if UIRouter.instance != null:
		UIRouter.instance.toast("Voted: %s" % display_name, &"good")
