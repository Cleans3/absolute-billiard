class_name PhaseScreen
extends UIModal
## The Night/Round phase screens as one modal (docs/plan/06 P12): Intermission, Reckoning, Game over, Campaign won.
## It opens and closes itself from GameLoop.phase_changed (keep_on_phase, so the router leaves it alone) and has the
## lowest priority: the Bartender menu, Pause, Settings, Controls and the vote all displace it and it comes back when
## they close, while the phase still holds, so the host can always still press Start Round. Only the Intermission
## screen can be set aside ("Visit the bar" to walk to the bar); the next screen that opens and closes brings it back.

@export var game_loop: GameLoop
@export var economy: EconomyManager

var _night_number := 1
var _body := ""  # Intermission text: the Night's ask, then the last Round's result
var _reckoning := ""
var _wanted := false  # the phase holds a screen (open, displaced, or set aside)
var _aside := false  # set aside by "Visit the bar": the player is walking, nothing else is open

@onready var _title: Label = %Title
@onready var _text: Label = %Body
@onready var _next: Button = %Next
@onready var _bar: Button = %Bar
@onready var _menu: Button = %Menu
@onready var _again: Button = %NewCampaign


func _ready() -> void:
	super()
	keep_on_phase = true
	dismissable = false
	priority = -10
	_next.pressed.connect(func() -> void: game_loop.advance())
	_bar.pressed.connect(_set_aside)
	_menu.pressed.connect(func() -> void: _net().call(&"leave"))
	_again.pressed.connect(func() -> void: _net().call(&"start_game"))  # every peer reloads MainLevel with a new seed
	_menu.visible = false
	_again.visible = false
	if game_loop != null:
		game_loop.night_started.connect(_on_night_started)
		game_loop.round_ended.connect(_on_round_ended)
		game_loop.phase_changed.connect(_on_phase_changed)
	if economy != null:
		economy.quota_evaluated.connect(_on_quota_evaluated)
	_bind_router.call_deferred()


func _bind_router() -> void:
	if UIRouter.instance != null:
		UIRouter.instance.modal_changed.connect(_on_modal_changed)


## Another screen opened: the walk is over. Nothing is open any more: the phase screen returns unless the player is walking.
func _on_modal_changed(open: bool) -> void:
	if open:
		_aside = false
	elif _wanted and not _aside and not visible:
		open()


func _set_aside() -> void:
	_aside = true
	close()
	if UIRouter.instance != null:
		UIRouter.instance.toast("Menu, then Resume, returns to the Intermission")


func _on_night_started(night_number: int, quota: int) -> void:
	_night_number = night_number
	_body = "Owe $%d by the end of the Night." % quota


func _on_round_ended(reason: StringName, round_points: int) -> void:
	_body = "Round over (%s): %d points." % [reason, round_points]


func _on_quota_evaluated(paid: int, demand: int, is_game_over: bool) -> void:
	if is_game_over:
		_reckoning = "Short of the $%d demand with $%d in Cash. The run ends." % [demand, economy.cash]
	else:
		_reckoning = "Paid $%d. Banked: $%d." % [paid, economy.cash]


func _on_phase_changed(phase: GameLoop.Phase) -> void:
	var host := game_loop.is_host()
	_aside = false
	_wanted = true
	match phase:
		GameLoop.Phase.INTERMISSION:
			var next_round := game_loop.round_index + 1
			var cash := "" if economy == null else " Cash $%d." % economy.cash  # the HUD hides behind this screen
			_present("Intermission", "%s%s\nNext: Round %d/%d." % [_body, cash, next_round, game_loop.current_night().rounds_count], "Start Round", host, true, false)
		GameLoop.Phase.RECKONING:
			_present("Night %d reckoning" % _night_number, _reckoning, "Next Night", host, false, false)
		GameLoop.Phase.GAME_OVER:
			_present("Game over", _reckoning, "", host, false, true)
		GameLoop.Phase.CAMPAIGN_WON:
			_present("Campaign won", _reckoning, "Endless", host, false, true)
		_:
			_wanted = false
			close()


func _present(title: String, body: String, button: String, host: bool, bar: bool, end: bool) -> void:
	_title.text = title
	_text.text = body if button.is_empty() or host else body + "\nWaiting for the host."
	_next.text = button
	_next.visible = not button.is_empty() and host
	_bar.visible = bar
	_menu.visible = end  # leaving mid-Night is Pause's job; only the end screens carry their own way out
	_again.visible = end and host
	open()
	if is_visible_in_tree():
		(_next if _next.visible else _menu).grab_focus()


func _net() -> Node:
	return get_node_or_null(^"/root/NetManager")  # by path: `-s` probes preload this scene before autoload names exist
