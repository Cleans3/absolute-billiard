extends Control
## HUD (docs/plan/02 §3.1, 08 §2.8): two groups at the top, one payout line at the bottom. Cash vs Quota with a fill bar on the
## left, the Round clock and shots left on the right; Night, Round, viewers, hype and the effects live on the Blackboard.
## Signals only (07 §5): the clock label is rewritten once a second, everything else when its own signal fires. Reads the
## same mirrored state on every peer. The phase screens live in PhaseScreen, notices in UIRouter's single toast line; the
## seed is on the F1 debug panel. The whole HUD hides while a modal is open.
## Fixed regions (docs 08 §2.8): money x[140, W-140] y[8, 64] from the left; clock x[140, W-140] y[8, 64] from the right;
## fps x[140, 300] y[68, 96]; payout x[240, W-240] y[576, 636].

const FEED_SECS := 4.0
const LOW_SECS := 10  ## the clock turns red at this many seconds left
const LOW_SHOTS := 1  ## and the shot count at this many

@export var game_loop: GameLoop
@export var economy: EconomyManager

var _demand := 0
var _tween: Tween  # the payout line's fade
var _shown_secs := -1

@onready var _cash: Label = %Cash
@onready var _quota: Label = %Quota
@onready var _quota_bar: FillBar = %QuotaBar
@onready var _time: Label = %Time
@onready var _shots: Label = %Shots
@onready var _fps: Label = %Fps
@onready var _payout: Label = %Payout


func _ready() -> void:
	add_to_group(Settings.GROUP)
	if game_loop != null:
		game_loop.night_started.connect(_on_night_started)
		game_loop.round_started.connect(_on_round_started)
		game_loop.state_changed.connect(_refresh_round)
		game_loop.shot_settled.connect(_on_shot_settled)
		game_loop.cue_respawned.connect(func(reason: StringName) -> void: _toast("Cue ball reset (%s)" % reason))
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
	var secs := ceili(game_loop.time_left)
	if secs != _shown_secs:
		_shown_secs = secs
		_time.text = "%d:%02d" % [floori(secs / 60.0), secs % 60]
		_warn(_time, secs <= LOW_SECS)


func _refresh_round() -> void:
	if game_loop != null:
		_shots.text = "Shots %d" % game_loop.shots_left
		_warn(_shots, game_loop.shots_left <= LOW_SHOTS)
		_warn(_time, ceili(game_loop.time_left) <= LOW_SECS)  # the phase may have changed under an unchanged number


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


func _on_fined(_reason: StringName, amount: int) -> void:
	_toast("Scratch! -$%d" % amount, &"bad")


func _on_night_started(_night_number: int, quota: int) -> void:
	_demand = quota
	_refresh_round()
	_refresh_cash()


func _on_round_started(_round_index: int, _time_limit: float, _hazard_tier: int) -> void:
	_flash("")


func _on_shot_settled(_shot_id: String, cash: int, trick_id: StringName, foul: bool) -> void:
	if foul:
		_flash("FOUL")
		return
	var line := "%s$%d" % ["+" if cash >= 0 else "-", absi(cash)]
	if trick_id != &"":
		line = "%s x%.2f  %s" % [trick_id, TrickShot.multiplier_for(trick_id), line]
	_flash(line)


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
