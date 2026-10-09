class_name PhaseScreen
extends UIModal
## The end-of-Night phase screens as one modal (docs/plan/06 P12): Reckoning, Game over, Campaign won. The Intermission
## has no screen: players stay in the bar and press GO LIVE at the table (02 §3.1); its news (last Round, Cash, the
## next ask) arrives as two toasts. It opens and closes itself from GameLoop.phase_changed (keep_on_phase, so the router
## leaves it alone) and has the lowest priority: the Bartender menu, Pause, Settings, Controls and the vote all displace
## it and it comes back when they close, while the phase still holds, so the host can always still press Next.

const NEWS_GAP_SEC := 2.8  ## a little over UIRouter.TOAST_SEC: the second line replaces the first once it has been read

@export var game_loop: GameLoop
@export var economy: EconomyManager

var _night_number := 1
var _ask := ""  # the Night's ask, then the last Round's result: the Intermission news
var _result := ""
var _reckoning := ""
var _wanted := false  # the phase holds a screen (open, or displaced by another)
var _news: Array[String] = []  # Intermission toasts not shown yet; held while a modal is open (a toast would sit under its dim)
var _wait_body := ""  # a client waits on the host to press Next: the line counts the seconds
var _waiting := false
var _wait_since_msec := 0
var _wait_shown := -1

@onready var _title: Label = %Title
@onready var _text: Label = %Body
@onready var _next: Button = %Next
@onready var _menu: Button = %Menu
@onready var _again: Button = %NewCampaign
@onready var _gap: Timer = Timer.new()


func _ready() -> void:
	super()
	keep_on_phase = true
	dismissable = false
	priority = -10
	_gap.one_shot = true
	_gap.timeout.connect(_flush_news)
	add_child(_gap)
	_next.pressed.connect(func() -> void: game_loop.advance())
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


func _process(_delta: float) -> void:
	if not _waiting:
		return
	var secs := (Time.get_ticks_msec() - _wait_since_msec) / 1000
	if secs != _wait_shown:
		_wait_shown = secs
		_text.text = "%s\nWaiting for the host · %d s" % [_wait_body, secs]


func _bind_router() -> void:
	if UIRouter.instance != null:
		UIRouter.instance.modal_changed.connect(_on_modal_changed)


## Nothing is open any more: the phase screen returns, or the Intermission news the modal held back is shown.
func _on_modal_changed(open: bool) -> void:
	if open:
		return
	if _wanted and not visible:
		open()
	else:
		_flush_news()


func _on_night_started(night_number: int, quota: int) -> void:
	_night_number = night_number
	_ask = "Night %d: owe $%d by the end of the Night" % [night_number, quota]
	_result = ""


func _on_round_ended(reason: StringName, round_points: int) -> void:
	_result = "Round over (%s): %d points" % [reason, round_points]


func _on_quota_evaluated(paid: int, demand: int, is_game_over: bool) -> void:
	if is_game_over:
		_reckoning = "Short of the $%d demand with $%d in Cash. The run ends." % [demand, economy.cash]
	else:
		_reckoning = "Paid $%d. Banked: $%d." % [paid, economy.cash]


func _on_phase_changed(phase: GameLoop.Phase) -> void:
	var host := game_loop.is_host()
	_wanted = true
	_news.clear()
	_gap.stop()
	_waiting = false
	match phase:
		GameLoop.Phase.INTERMISSION:
			_wanted = false
			close()
			_announce()
		GameLoop.Phase.RECKONING:
			_present("Night %d reckoning" % _night_number, _reckoning, "Next Night", host, false)
		GameLoop.Phase.GAME_OVER:
			_present("Game over", _reckoning, "", host, true)
		GameLoop.Phase.CAMPAIGN_WON:
			_present("Campaign won", _reckoning, "Endless", host, true)
		_:
			_wanted = false
			close()


## Two short lines (one toast is 600 px wide): how the last Round went and what Cash is, then what is next.
func _announce() -> void:
	var cash := "" if economy == null else " · Cash $%d" % economy.cash
	_news = [(_result if _result != "" else _ask) + cash,
			"Round %d/%d next: press GO LIVE at the table" % [game_loop.round_index + 1, game_loop.current_night().rounds_count]]
	_flush_news()


func _flush_news() -> void:
	if _news.is_empty() or UIRouter.instance == null or UIRouter.instance.is_modal_open():
		return
	UIRouter.instance.toast(_news.pop_front())
	if not _news.is_empty():
		_gap.start(NEWS_GAP_SEC)


func _present(title: String, body: String, button: String, host: bool, end: bool) -> void:
	_title.text = title
	var waiting := not button.is_empty() and not host
	_wait_body = body
	_waiting = waiting
	_wait_since_msec = Time.get_ticks_msec()
	_wait_shown = -1
	_text.text = body + "\nWaiting for the host · 0 s" if waiting else body
	_next.text = button
	_next.visible = not button.is_empty() and host
	_menu.visible = end  # leaving mid-Night is Pause's job; only the end screens carry their own way out
	_again.visible = end and host
	open()
	if is_visible_in_tree():
		(_next if _next.visible else _menu).grab_focus()


func _net() -> Node:
	return get_node_or_null(^"/root/NetManager")  # by path: `-s` probes preload this scene before autoload names exist
