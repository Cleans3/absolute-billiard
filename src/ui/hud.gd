extends Control
## HUD (docs/plan/02 §3.1): one stat bar at the top, one payout line at the bottom. Signals only (07 §5): the clock
## label is rewritten once a second, everything else when its own signal fires. Reads the same mirrored state on every
## peer. The phase screens live in PhaseScreen, notices in UIRouter's single toast line; the seed is on the F1 debug panel.
## Fixed regions (docs 08 §2.7): stat bar x[140, W-140] y[8, 64]; payout x[240, W-240] y[576, 636].

const FEED_SECS := 4.0
const ICONS := "res://assets/ui/icon_%s.svg"

@export var game_loop: GameLoop
@export var economy: EconomyManager
@export var stream: StreamManager

var _night_number := 1
var _demand := 0
var _tween: Tween  # the payout line's fade
var _shown_secs := -1

var _night: Label
var _round: Label
var _time: Label
var _shots: Label
var _cash: Label
var _quota: Label
var _viewers: Label
var _hype: Label
var _fps: Label

@onready var _stats: HBoxContainer = %Stats
@onready var _payout: Label = %Payout


func _ready() -> void:
	add_to_group(Settings.GROUP)
	_night = _chip("night", "Night 1")
	_round = _chip("round", "Round 0/3")
	_time = _chip("clock", "0:00")
	_shots = _chip("shots", "Shots 0")
	_cash = _chip("cash", "$0")
	_quota = _chip("quota", "$0")
	_viewers = _chip("viewers", "0")
	_hype = _chip("hype", "0%")
	_fps = Label.new()
	_fps.theme_type_variation = &"HudLabel"
	_stats.add_child(_fps)
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
	if stream != null:
		stream.viewers_changed.connect(_on_viewers_changed)
	_on_settings_changed()
	_refresh_round()
	_refresh_cash()
	_refresh_time()


func _process(_delta: float) -> void:
	_refresh_time()
	if _fps.visible:
		_fps.text = "%d fps" % Engine.get_frames_per_second()


func _on_settings_changed() -> void:
	_fps.visible = bool(Settings.value(&"show_fps"))


## icon + label; returns the label.
func _chip(icon: String, text: String) -> Label:
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.theme_type_variation = &"ChipBox"
	var tex := TextureRect.new()
	tex.texture = load(ICONS % icon)
	tex.custom_minimum_size = Vector2(30, 30)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tex)
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HudLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	_stats.add_child(box)
	return label


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


func _refresh_cash() -> void:
	var cash := economy.cash if economy != null else 0
	_cash.text = "-$%d" % -cash if cash < 0 else "$%d" % cash
	_cash.theme_type_variation = &"HudDanger" if cash < 0 else &"HudLabel"
	_quota.text = "$%d" % _demand


func _on_viewers_changed(viewers: int, hype: float) -> void:
	_viewers.text = str(viewers)
	_hype.text = "%d%%" % roundi(hype * 100.0)


func _on_item_purchased(item_id: StringName, _buyer_peer_id: int) -> void:
	if item_id != &"":
		_toast("Bought %s" % item_id, &"good")


func _on_purchase_rejected(item_id: StringName, reason: StringName) -> void:
	_toast("Can't buy %s (%s)" % [item_id, reason], &"bad")


func _on_fined(_reason: StringName, amount: int) -> void:
	_toast("Scratch! -$%d" % amount, &"bad")


func _on_night_started(night_number: int, quota: int) -> void:
	_night_number = night_number
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
