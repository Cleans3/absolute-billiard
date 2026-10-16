extends Control
## HUD (docs/plan/02 §3.1, 08 §2.8): two groups at the top, one payout line at the bottom. Cash vs Quota with a fill bar on the
## left, the Round clock and shots left on the right; Night, Round, viewers, hype and the effects live on the Blackboard.
## Signals only (07 §5): the clock label is rewritten once a second, everything else when its own signal fires. Reads the
## same mirrored state on every peer. The phase screens live in PhaseScreen, notices in UIRouter's single toast line; the
## seed is on the F1 debug panel. The whole HUD hides while a modal is open.
## Fixed regions (docs 08 §2.8): money x[140, W-140] y[8, 64] from the left; clock x[140, W-140] y[8, 64] from the right;
## fps x[140, 300] y[68, 96]; turn line x[W-440, W-140] y[68, 96]; payout x[240, W-240] y[576, 636]; the first-time coach's card
## x[24, 340] y[160, ...], on the right edge when left-handed (src/ui/coach.gd, its own CanvasLayer).

const FEED_SECS := 4.0
const LOW_SECS := 10  ## the clock turns red at this many seconds left
const LOW_SHOTS := 1  ## and the shot count at this many

@export var game_loop: GameLoop
@export var economy: EconomyManager

var coach: Coach  ## the first-time coach (adhoc-1014a V2), built when the HUD sits in a level

var _demand := 0
var _tween: Tween  # the payout line's fade
var _shown_secs := -1
var _rd: RoundDirector

@onready var _cash: Label = %Cash
@onready var _quota: Label = %Quota
@onready var _quota_bar: FillBar = %QuotaBar
@onready var _time: Label = %Time
@onready var _shots: Label = %Shots
@onready var _fps: Label = %Fps
@onready var _payout: Label = %Payout
@onready var _turn: Label = %Turn


func _ready() -> void:
	add_to_group(Settings.GROUP)
	if game_loop != null:
		game_loop.night_started.connect(_on_night_started)
		game_loop.round_started.connect(_on_round_started)
		game_loop.state_changed.connect(_refresh_round)
		game_loop.shot_settled.connect(_on_shot_settled)
		game_loop.cue_respawned.connect(func(reason: StringName) -> void: _toast("Cue ball reset (%s)" % reason))
		game_loop.phase_changed.connect(func(_p: int) -> void:
			_refresh_round()  # a client's state_changed comes before its phase moves
			_refresh_turn())
		game_loop.staging_changed.connect(func(_on: bool) -> void: _refresh_turn())
		_rd = game_loop.get_parent().get_node_or_null("RoundDirector") as RoundDirector  # the level's; a bare probe loop has none
		if _rd != null:
			_rd.shooter_changed.connect(func(_id: int) -> void: _refresh_turn())
		coach = Coach.new()
		coach.name = "Coach"
		add_child(coach)
		coach.bind(game_loop)
	if economy != null:
		economy.cash_changed.connect(_on_cash_changed)
		economy.item_purchased.connect(_on_item_purchased)
		economy.purchase_rejected.connect(_on_purchase_rejected)
		if economy.has_signal(&"fined"):  # contract §2: EconomyManager.fined(reason, amount), every peer
			economy.connect(&"fined", _on_fined)
	_on_settings_changed()
	_bind_router.call_deferred()
	_refresh_round()
	_refresh_cash()
	_refresh_time()
	_refresh_turn()


## Hidden under a modal: a screen shows only itself, nothing of the HUD peeks out round its edges.
func _bind_router() -> void:
	if UIRouter.instance != null:
		UIRouter.instance.modal_changed.connect(func(open: bool) -> void: visible = not open)
		visible = not UIRouter.instance.is_modal_open()


func _process(_delta: float) -> void:
	_refresh_time()
	if _fps.visible:
		_fps.text = "%d fps" % Engine.get_frames_per_second()


func _on_settings_changed() -> void:
	_fps.visible = bool(Settings.value(&"show_fps"))


func _refresh_time() -> void:
	if game_loop == null:
		return
	var secs := ceili(_time_now())
	if secs != _shown_secs:
		_shown_secs = secs
		_time.text = "%d:%02d" % [floori(secs / 60.0), secs % 60]
		_warn(_time, secs <= LOW_SECS)


func _refresh_round() -> void:
	if game_loop != null:
		var left := _shots_now()
		_shots.text = "Shots %d/%d" % [left, _shots_total(left)]
		_warn(_shots, left <= LOW_SHOTS)
		_warn(_time, ceili(_time_now()) <= LOW_SECS)  # the phase may have changed under an unchanged number


## Before a Round starts (the Night's start and every Intermission) the clock and the shots show the next Round's full values from
## the Night's config, not the last Round's leftovers (or 0 before the first): host and clients read the same config.
func _before_round() -> bool:
	return (game_loop.phase == GameLoop.Phase.NIGHT_START or game_loop.phase == GameLoop.Phase.INTERMISSION) and not game_loop.nights.is_empty()


func _shots_now() -> int:
	return game_loop.current_night().shots_per_round if _before_round() else game_loop.shots_left


func _time_now() -> float:
	return game_loop.current_night().round_time_limit_sec if _before_round() else game_loop.time_left


## N of "Shots n/N": the Night's allowance (a debug top-up can pass it, and n/N must not read as an error).
func _shots_total(left: int) -> int:
	var total := game_loop.current_night().shots_per_round if not game_loop.nights.is_empty() else left
	return maxi(total, left)


## The persistent turn line under the clock: whose shot it is, while a Round is live (and the table is not being set up).
func _refresh_turn() -> void:
	if not is_inside_tree():  # a signal from a level that is being freed
		return
	var live := game_loop != null and _rd != null and game_loop.phase == GameLoop.Phase.ROUND_LIVE and not game_loop.is_staging()
	_turn.visible = live
	if live:
		var me := multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else 1
		var mine := _rd.current_shooter_id == me
		_turn.text = WaitText.turn(WaitText.roster_name(get_node_or_null(^"/root/NetManager"), _rd.current_shooter_id), mine)
		_turn.theme_type_variation = &"Good" if mine else &"HudLabel"


## Red only while a Round is live: between Rounds the numbers are stale, not urgent.
func _warn(label: Label, low: bool) -> void:
	label.theme_type_variation = &"HudDanger" if low and game_loop.phase == GameLoop.Phase.ROUND_LIVE else &"HudLabel"


func _refresh_cash() -> void:
	var cash := economy.cash if economy != null else 0
	_cash.text = "-$%d" % -cash if cash < 0 else "$%d" % cash
	_cash.theme_type_variation = &"HudDanger" if cash < 0 else &"HudLabel"
	_quota.text = "/ $%d" % _demand
	_quota_bar.value = float(cash) / float(_demand) if _demand > 0 else 0.0


func _on_item_purchased(item_id: StringName, _buyer_peer_id: int) -> void:
	if item_id != &"":
		_toast("Bought %s" % item_id, &"good")


func _on_purchase_rejected(item_id: StringName, reason: StringName) -> void:
	_toast("Can't buy %s (%s)" % [item_id, reason], &"bad")


func _on_fined(reason: StringName, amount: int) -> void:
	var text := {&"cue_broken": "Cue broken! -$%d", &"ball_grab": "Ball grab! -$%d"}.get(reason, "Scratch! -$%d") as String
	_toast(text % amount, &"bad")


func _on_night_started(_night_number: int, quota: int) -> void:
	_demand = quota
	_refresh_round()
	_refresh_cash()


func _on_round_started(_round_index: int, _time_limit: float, _hazard_tier: int) -> void:
	_flash("")


func _on_shot_settled(_shot_id: String, cash: int, trick_id: StringName, foul: bool) -> void:
	_refresh_round()  # the host takes the shot off `shots_left` without a state_changed (clients get round_state): n/N must tick on every peer
	if foul:
		_flash("FOUL")
		return
	var line := "%s$%d" % ["+" if cash >= 0 else "-", absi(cash)]
	if trick_id != &"":
		line = "%s x%.2f  %s" % [trick_id, TrickShot.multiplier_for(trick_id), line]
	_flash(line)


## The payout line belongs to the shot that just settled: it ends when the next aim starts, so a FOUL never rides into the view.
func on_player_mode(mode: int) -> void:
	if mode == Player.Mode.CUE:
		_flash("")


func _on_cash_changed(_balance: int, delta: int, reason: StringName) -> void:
	_refresh_cash()
	if reason == &"tip":
		_toast("Tip +$%d" % delta, &"good")


func _toast(text: String, kind: StringName = &"info") -> void:
	if UIRouter.instance != null:
		UIRouter.instance.toast(text, kind)


func _flash(text: String) -> void:
	_payout.text = text
	_payout.modulate.a = 1.0
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(FEED_SECS)
	_tween.tween_property(_payout, "modulate:a", 0.0, 0.5)
