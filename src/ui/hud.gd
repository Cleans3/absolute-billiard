extends Control
## HUD (docs/plan/02 §3.1): a stat row, a payout/notice feed, one overlay for Intermission,
## Reckoning and the two end states. Signals only (07 §5): the clock label is rewritten once a second,
## everything else when its own signal fires. Reads the same mirrored state on every peer.

const FEED_SECS := 4.0

@export var game_loop: GameLoop
@export var economy: EconomyManager
@export var stream: StreamManager

var _night_number := 1
var _demand := 0
var _body := ""  # Intermission text: the Night's ask, then the last Round's result
var _reckoning := ""
var _tweens := {}  # Label -> Tween, so a new line restarts its own fade
var _shown_secs := -1

@onready var _night: Label = %Night
@onready var _round: Label = %Round
@onready var _time: Label = %Time
@onready var _shots: Label = %Shots
@onready var _cash: Label = %Cash
@onready var _viewers: Label = %Viewers
@onready var _seed: Label = %Seed
@onready var _payout: Label = %Payout
@onready var _notice: Label = %Notice
@onready var _overlay: Control = %Overlay
@onready var _title: Label = %Title
@onready var _overlay_body: Label = %Body
@onready var _next: Button = %Next


func _ready() -> void:
	_next.pressed.connect(_on_next_pressed)
	if game_loop != null:
		game_loop.night_started.connect(_on_night_started)
		game_loop.round_started.connect(_on_round_started)
		game_loop.round_ended.connect(_on_round_ended)
		game_loop.phase_changed.connect(_on_phase_changed)
		game_loop.shot_settled.connect(_on_shot_settled)
		game_loop.state_changed.connect(_refresh_round)
		game_loop.cue_respawned.connect(func(reason: StringName) -> void:
			_flash(_notice, "Cue ball reset (%s)" % reason))
	if economy != null:
		economy.cash_changed.connect(_on_cash_changed)
		economy.quota_evaluated.connect(_on_quota_evaluated)
		economy.item_purchased.connect(_on_item_purchased)
		economy.purchase_rejected.connect(_on_purchase_rejected)
	if stream != null:
		stream.viewers_changed.connect(_on_viewers_changed)
	_refresh_round()
	_refresh_cash()
	_refresh_time()


func _process(_delta: float) -> void:
	_refresh_time()


func _refresh_time() -> void:
	if game_loop == null:
		return
	var secs := ceili(game_loop.time_left)
	if secs != _shown_secs:
		_shown_secs = secs
		_time.text = "%d:%02d" % [floori(secs / 60.0), secs % 60]


func _refresh_round() -> void:
	_night.text = "Night %d" % _night_number
	if game_loop != null:
		_shots.text = "Shots %d" % game_loop.shots_left
		_round.text = "Round %d/%d" % [game_loop.round_index, game_loop.current_night().rounds_count if not game_loop.nights.is_empty() else 0]
		_seed.text = "Seed %d" % game_loop.round_seed


func _refresh_cash() -> void:
	_cash.text = "$%d / $%d" % [economy.cash if economy != null else 0, _demand]


func _on_viewers_changed(viewers: int, hype: float) -> void:
	_viewers.text = "Viewers %d  Hype %d%%" % [viewers, roundi(hype * 100.0)]


func _on_item_purchased(item_id: StringName, _buyer_peer_id: int) -> void:
	if item_id != &"":
		_flash(_notice, "Bought %s" % item_id)


func _on_purchase_rejected(item_id: StringName, reason: StringName) -> void:
	_flash(_notice, "Can't buy %s (%s)" % [item_id, reason])


func _on_night_started(night_number: int, quota: int) -> void:
	_night_number = night_number
	_demand = quota
	_body = "Owe $%d by the end of the Night." % quota
	_refresh_round()
	_refresh_cash()


func _on_round_started(_round_index: int, _time_limit: float, _hazard_tier: int) -> void:
	_flash(_payout, "")


func _on_round_ended(reason: StringName, round_points: int) -> void:
	_body = "Round over (%s): %d points." % [reason, round_points]


func _on_phase_changed(phase: GameLoop.Phase) -> void:
	var host := game_loop.is_host()
	match phase:
		GameLoop.Phase.INTERMISSION:
			var next_round := game_loop.round_index + 1
			_show("Intermission", "%s\nNext: Round %d/%d." % [_body, next_round, game_loop.current_night().rounds_count], "Start Round", host)
		GameLoop.Phase.RECKONING:
			_show("Night %d reckoning" % _night_number, _reckoning, "Next Night", host)
		GameLoop.Phase.GAME_OVER:
			_show("Game over", _reckoning, "", false)
		GameLoop.Phase.CAMPAIGN_WON:
			_show("Campaign won", _reckoning, "Endless", host)
		_:
			_overlay.hide()


func _on_shot_settled(_shot_id: String, cash: int, trick_id: StringName, foul: bool) -> void:
	if foul:
		_flash(_payout, "FOUL")
		return
	var line := "%s$%d" % ["+" if cash >= 0 else "-", absi(cash)]
	if trick_id != &"":
		line = "%s x%.2f  %s" % [trick_id, TrickShot.multiplier_for(trick_id), line]
	_flash(_payout, line)


func _on_cash_changed(_balance: int, delta: int, reason: StringName) -> void:
	_refresh_cash()
	if reason == &"tip":
		_flash(_notice, "Tip +$%d" % delta)


func _on_quota_evaluated(paid: int, demand: int, is_game_over: bool) -> void:
	if is_game_over:
		_reckoning = "Short of the $%d demand with $%d in Cash. The run ends." % [demand, economy.cash]
	else:
		_reckoning = "Paid $%d. Banked: $%d." % [paid, economy.cash]


func _show(title: String, body: String, button: String, host: bool) -> void:
	_title.text = title
	_overlay_body.text = body if button.is_empty() or host else body + "\nWaiting for the host."
	_next.text = button
	_next.visible = not button.is_empty() and host
	_overlay.show()


func _on_next_pressed() -> void:
	game_loop.advance()


func _flash(label: Label, text: String) -> void:
	label.text = text
	label.modulate.a = 1.0
	if _tweens.has(label):
		_tweens[label].kill()
	var tween := create_tween()
	tween.tween_interval(FEED_SECS)
	tween.tween_property(label, "modulate:a", 0.0, 0.5)
	_tweens[label] = tween
