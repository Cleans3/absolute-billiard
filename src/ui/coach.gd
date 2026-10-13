class_name Coach
extends CanvasLayer
## The first-time coach (docs/plan/08 §2.8, 06 P44, adhoc-1014a V2): a small card in the top-left corner that walks a new player
## through their first Round, plus a floating hint over the GO LIVE button. Presentation only, local to each peer, never blocks
## input (the card ignores the mouse; only its Skip button takes a tap).
##
##   GO_LIVE  between Rounds, until I am ready:   the pedestal hint + "walk to the red button and press it when you're ready"
##   WAIT     the Round is live, someone else shoots:  "<name> is shooting, wait for your turn" (until it is mine)
##   WALK     my turn, standing:                  "walk up to the cue ball, press Shoot"
##   AIM / SPIN / POWER   my turn, in CUE:        "drag to aim", "optional: spin and cue angle", "pull the power bar back, release"
##
## Every step is derived from state a signal just changed (GameLoop phase / ready / staging, RoundDirector.shooter_changed,
## Player.mode_changed, CueController.fired). The three CUE steps also read the CueController's own state each frame (aim_yaw, spin,
## elevation_deg, power): it has no signal for "the player moved the aim", and nothing here is a timer. The seen flag
## (SaveManager.coach_seen) is set when the first shot is fired or the player skips, never on first show. Only the first Intermission
## and Round 1 of Night 1 qualify, unless Settings > Replay tutorial forced it (`replay`).
## Hosted by the HUD (`HUD.coach`); hidden under any open modal. `enabled` is off in a headless run so no existing probe sees it.

enum Step { OFF, GO_LIVE, WAIT, WALK, AIM, SPIN, POWER }

signal step_changed(step: Step)
signal finished(skipped: bool)

## Off in a headless run (every probe that predates the coach); the coach probes and the windowed shot tools switch it on.
static var enabled := DisplayServer.get_name() != "headless"

const CARD_TOP := 160.0  ## under the toast slot (y 108-152) and the Back button (y 24-120); docs 08 §2.8
const CARD_SIDE := 24.0
const CARD_WIDTH := 316.0  ## x[24, 340]: left of the "host away" banner (x >= 340) and the call-pocket buttons (x >= 400)
const AIM_RAD := 0.1  ## ~6 degrees of drag count as "aimed"
const POWER_EPS := 0.02  ## the power bar pulled this far counts as "charging"
const SKIP_KEY := KEY_H  ## desktop has a captured mouse, so Skip needs a key
const CUE_STEPS: Array[Step] = [Step.AIM, Step.SPIN, Step.POWER]
const TITLES := {
	Step.GO_LIVE: "Getting started",
	Step.WAIT: "Your first shot: waiting",
	Step.WALK: "Your first shot 1/4",
	Step.AIM: "Your first shot 2/4",
	Step.SPIN: "Your first shot 3/4",
	Step.POWER: "Your first shot 4/4",
}

var step := Step.OFF
var done := false  ## finished or skipped: the card stays away for good
## The card sits on the side opposite the power bar: left, or right for the left-handed touch layout (Settings touch_mirror).
var mirror := false:
	set(v):
		mirror = v
		_place()

var _loop: GameLoop
var _rd: RoundDirector
var _player: Player
var _controls: TouchControls
var _seen := false
var _forced := false  ## Replay tutorial: the first-Round limit is lifted
var _modal := false
var _cue_stage := Step.AIM
var _baseline := false  ## the aim, spin and angle the player started this CUE with, to be read on the next frame
var _aim0 := 0.0
var _spin0 := Vector2.ZERO
var _elev0 := 0.0
var _card: PanelContainer
var _title: Label
var _body: Label
var _skip: Button


func _ready() -> void:
	add_to_group(&"coach")
	add_to_group(Settings.GROUP)
	layer = 2  # above TouchControls, whose look pad takes every touch in CUE: the Skip button must be reachable
	_build()
	_on_settings_changed()
	_show()
	set_process(false)


func _on_settings_changed() -> void:
	mirror = bool(Settings.value(&"touch_mirror"))


## Settings > Replay tutorial: forget the flag; a coach already in a level starts again at whatever applies right now.
static func replay(tree: SceneTree) -> void:
	SaveManager.save_coach_seen(false)
	tree.call_group(&"coach", &"restart")


func restart() -> void:
	_seen = false
	done = false
	_forced = true
	_cue_stage = Step.AIM
	_refresh()


## The HUD hands over the GameLoop; every other node is found from the level it sits in.
func bind(loop: GameLoop) -> void:
	_loop = loop
	var level := loop.get_parent()
	_rd = level.get_node_or_null("RoundDirector") as RoundDirector
	_controls = level.get_node_or_null("UILayer/TouchControls") as TouchControls
	_seen = SaveManager.coach_seen()
	loop.phase_changed.connect(func(_p: int) -> void: _refresh())
	loop.state_changed.connect(_refresh)
	loop.ready_changed.connect(_refresh)
	loop.staging_changed.connect(func(_on: bool) -> void: _refresh())
	if _rd != null:
		_rd.shooter_changed.connect(func(_id: int) -> void: _refresh())
	var spawner := level.get_node_or_null("PlayerSpawner")  # untyped: its script names the NetManager autoload, which a `-s` probe cannot compile
	if spawner != null:
		spawner.connect(&"local_player_spawned", func(p: CharacterBody3D) -> void: _on_local_player(p as Player))
		_on_local_player(spawner.call(&"get_local_player") as Player)
	_bind_router.call_deferred()
	_refresh()


func _bind_router() -> void:
	if UIRouter.instance != null:
		UIRouter.instance.modal_changed.connect(func(open: bool) -> void:
			_modal = open
			_show_card())
		_modal = UIRouter.instance.is_modal_open()
		_show_card()


func _on_local_player(player: Player) -> void:
	if player == null or player == _player:
		return
	_player = player
	player.mode_changed.connect(_on_mode)
	player.cue.fired.connect(func(_intent: ShotIntent) -> void: _on_fired())
	_refresh()


func _on_mode(mode: Player.Mode) -> void:
	if mode == Player.Mode.CUE:  # the CUE steps start over each time the player lines up
		_cue_stage = Step.AIM
		_baseline = true  # read in _process: CueController.begin runs just after mode_changed
	_refresh()


## The first shot is away: the guide did its job.
func _on_fired() -> void:
	if step != Step.OFF:
		_finish(false)


func _process(_delta: float) -> void:
	if _player == null or _player.mode != Player.Mode.CUE:
		return
	var c := _player.cue
	if _baseline:
		_baseline = false
		_aim0 = c.aim_yaw
		_spin0 = c.spin
		_elev0 = c.elevation_deg
	var before := _cue_stage
	if c.power > POWER_EPS:
		_cue_stage = Step.POWER
	elif _cue_stage == Step.AIM and absf(angle_difference(_aim0, c.aim_yaw)) > AIM_RAD:
		_cue_stage = Step.SPIN
	elif _cue_stage == Step.SPIN and (c.spin != _spin0 or not is_equal_approx(c.elevation_deg, _elev0)):
		_cue_stage = Step.POWER
	if _cue_stage != before:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if step != Step.OFF and not UIRouter.blocking() and event is InputEventKey and event.pressed and not event.echo and event.keycode == SKIP_KEY:
		_finish(true)


# --- state ----------------------------------------------------------------------------------------------------------------------

## Does the coach apply to this player right now, and at which step.
func _compute() -> Step:
	if not enabled or done or _seen or _loop == null or not is_inside_tree():
		return Step.OFF
	if not _forced and _loop.night_index != 0:
		return Step.OFF
	var me := multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else 1
	if _loop.phase == GameLoop.Phase.INTERMISSION:
		if _loop.is_staging() or (not _forced and _loop.round_index != 0):
			return Step.OFF
		return Step.OFF if _loop.ready_peers.has(me) else Step.GO_LIVE
	if _loop.phase != GameLoop.Phase.ROUND_LIVE or _loop.is_staging() or _rd == null or (not _forced and _loop.round_index != 1):
		return Step.OFF
	if _rd.current_shooter_id != me:
		return Step.WAIT
	if _player == null or _player.mode != Player.Mode.CUE:
		return Step.WALK
	return _cue_stage


func _refresh() -> void:
	if _loop == null:  # unbound (the layout probe, the shot tool): `force_step` owns the card
		return
	var s := _compute()
	set_process(CUE_STEPS.has(s))
	if s != step:
		step = s
		_show()
		step_changed.emit(s)
	_set_hint()


## Shows `s` without the state machine, for the layout probe and the shot tool. Only on an unbound coach.
func force_step(s: Step) -> void:
	if _loop == null:
		step = s
		_show()


func _finish(skipped: bool) -> void:
	done = true
	_seen = true
	SaveManager.save_coach_seen(true)
	finished.emit(skipped)
	_refresh()


# --- the card -------------------------------------------------------------------------------------------------------------------

func _show() -> void:
	if _body == null:
		return
	if step != Step.OFF:
		_title.text = TITLES[step]
		_body.text = _text(step)
		_skip.text = "Skip" if _touch() else "Skip [%s]" % OS.get_keycode_string(SKIP_KEY)
		_card.reset_size.call_deferred()  # the body wraps to a new height
	_show_card()
	_set_hint()


func _show_card() -> void:
	if _card != null:
		_card.visible = step != Step.OFF and not _modal


## The pedestal's floating hint follows the GO_LIVE step; asked on every refresh because the pedestal is built after the HUD.
func _set_hint() -> void:
	if not is_inside_tree():
		return
	for p in get_tree().get_nodes_in_group(&"go_live_pedestal"):
		p.call(&"set_hint", step == Step.GO_LIVE)


func _touch() -> bool:
	return _controls.touch if _controls != null else DisplayServer.is_touchscreen_available()


func _key(action: StringName) -> String:
	return Settings.binding_text(action)


func _text(s: Step) -> String:
	var touch := _touch()
	match s:
		Step.GO_LIVE:
			return "Walk up to the red GO LIVE button by the table and %s when you're ready to play." % ("tap GO LIVE" if touch else "press [%s]" % _key(&"interact"))
		Step.WAIT:
			return "%s. Wait for your turn, then this guide walks you through your shot." % WaitText.turn(_shooter_name(), false)
		Step.WALK:
			return "Your turn! Walk up to the cue ball, then %s." % ("tap Shoot" if touch else "press [%s] to line up the shot" % _key(&"cue_mode"))
		Step.AIM:
			return "Drag anywhere on the screen to aim." if touch else "Move the mouse to aim."
		Step.SPIN:
			if touch:
				return "Optional: tap the round spin pad or the angle pad to curve or lift the shot. Or go straight to the power bar."
			return "Optional: [%s][%s][%s][%s] set the spin, [%s]/[%s] tilt the cue. Or go straight to the power." % [
				_key(&"spin_up"), _key(&"spin_left"), _key(&"spin_down"), _key(&"spin_right"), _key(&"elevate_down"), _key(&"elevate_up")]
		Step.POWER:
			return "Pull the power bar down, then let go to shoot. The further, the harder." if touch else "Hold [%s] to charge the power, release to shoot." % _key(&"shoot")
	return ""


func _shooter_name() -> String:
	return WaitText.roster_name(get_node_or_null(^"/root/NetManager"), _rd.current_shooter_id) if _rd != null else ""


func _place() -> void:
	if _card == null:
		return
	var right := 1.0 if mirror else 0.0
	_card.anchor_left = right
	_card.anchor_right = right
	_card.offset_left = -CARD_SIDE - CARD_WIDTH if mirror else CARD_SIDE
	_card.offset_right = -CARD_SIDE if mirror else CARD_SIDE + CARD_WIDTH
	_card.offset_top = CARD_TOP
	_card.offset_bottom = CARD_TOP
	_card.grow_horizontal = Control.GROW_DIRECTION_BEGIN if mirror else Control.GROW_DIRECTION_END
	_card.reset_size.call_deferred()


func _build() -> void:
	_card = PanelContainer.new()
	_card.theme_type_variation = &"PanelPlate"
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.custom_minimum_size = Vector2(CARD_WIDTH, 0.0)
	add_child(_card)
	_place()
	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(rows)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(head)
	_title = Label.new()
	_title.theme_type_variation = &"Caption"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_title)
	_skip = Button.new()
	_skip.custom_minimum_size = Vector2(96.0, 48.0)
	_skip.add_theme_font_size_override(&"font_size", 20)
	_skip.pressed.connect(func() -> void: _finish(true))
	head.add_child(_skip)
	_body = Label.new()
	_body.add_theme_font_size_override(&"font_size", 22)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(CARD_WIDTH - 40.0, 0.0)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(_body)
	_card.hide()
