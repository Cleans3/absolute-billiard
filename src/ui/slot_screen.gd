class_name SlotScreen
extends UIModal
## The bar slot's controls (docs/plan/02 §3.9): a strip at the bottom of the screen, so the machine stays in view while it spins.
## Pick a stake, pull the lever; the host rolls and every peer watches the same reels. Local to each peer; the only network
## traffic is the `slot_spin` interaction. Priority 5: over the Bartender, under the hazard vote and Pause.

const PANEL_SIZE := Vector2(640.0, 322.0)
const FACE_SEC := 0.35  ## how long the camera takes to turn to the machine
const VIEW_LIFT_DEG := 13.0  ## the camera looks this far BELOW the reels, so they sit in the free part of the screen over the (taller) strip
const TOAST_CHARS := 46  ## longest win + chaos line that still fits the toast slot
## The two refusals only a custom stake can earn (WaitText has no sentence for them).
const BET_REASONS := {&"bad_bet": "That stake is outside tonight's limits", &"stale_cash": "Your cash just changed: check the stake"}
const SHAKE_PX := 14.0     ## panel shake at full power
const SHAKE_VIEW := 0.05   ## camera frustum shake at full power (m)

@export var economy: EconomyManager
@export var game_loop: GameLoop

var _bet := 0   ## the stake the player picked; 0 = none yet, the middle preset (it follows the Night)
var _spinning := false
var _shown_busy := false
var _machine: SlotMachine
var _world: WorldInteractions
var _bets := PackedInt32Array([0, 0, 0])
var _tier_buttons: Array[Button] = []   ## the three presets
var _max_button: Button
var _minus: Button
var _plus: Button
var _slider: HSlider
var _panel: PanelContainer
var _panel_home := Vector2.ZERO
var _shake_tween: Tween
var _cash: Label
var _status: Label
var _chaos: Label
var _spin: Button
var _pays_panel: PanelContainer
var _face_tween: Tween
var _watchdog: SceneTreeTimer


func _init() -> void:
	super()
	add_to_group(&"slot_screen")
	priority = 5
	dim = false  # the machine is the show


func _ready() -> void:
	super()
	set_process(false)  # only while open
	_build()
	if economy != null:
		economy.cash_changed.connect(func(_b: int, _d: int, _r: StringName) -> void: _refresh())


func _on_open() -> void:
	_machine = get_tree().get_first_node_in_group(&"slot_machine") as SlotMachine
	_world = get_tree().get_first_node_in_group(&"world_interactions") as WorldInteractions
	if _machine != null and not _machine.landed.is_connected(_on_landed):
		_machine.landed.connect(_on_landed)
	if _world != null:
		if not _world.interaction_rejected.is_connected(_on_rejected):
			_world.interaction_rejected.connect(_on_rejected)
		if not _world.interaction_applied.is_connected(_on_applied):
			_world.interaction_applied.connect(_on_applied)
	_pays_panel.hide()
	_status.text = "Pick a stake and pull the lever"
	_chaos.text = ""
	_spinning = false
	_refresh()
	_face_machine()
	set_process(true)
	_spin.call_deferred(&"grab_focus")


func _on_close() -> void:
	set_process(false)
	if _face_tween != null:
		_face_tween.kill()


## Closes by itself when the player goes limp (the machine's ZAP, a thrown drink): the strip would sit over a ragdoll's view.
func _process(_delta: float) -> void:
	var p := _local_player()
	if p != null and p.mode == Player.Mode.RAGDOLL:
		close()
	if _is_busy() != _shown_busy:  # the machine freed itself (its last drum settled): the button comes back
		_refresh()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelPlate"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -PANEL_SIZE.x * 0.5
	panel.offset_right = PANEL_SIZE.x * 0.5
	panel.offset_top = -PANEL_SIZE.y - 20.0
	panel.offset_bottom = -20.0
	panel.name = "Panel"
	_panel = panel
	add_child(panel)
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightBox"
	panel.add_child(box)

	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "8-BALL SLOTS"
	title.theme_type_variation = &"Heading"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_cash = Label.new()
	_cash.theme_type_variation = &"HudLabel"
	head.add_child(_cash)
	box.add_child(head)

	var tiers := HBoxContainer.new()
	tiers.alignment = BoxContainer.ALIGNMENT_CENTER
	var group := ButtonGroup.new()
	for i in SlotMath.BET_RATES.size():
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(110.0, 56.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_pick_tier.bind(i))
		tiers.add_child(b)
		_tier_buttons.append(b)
	_max_button = Button.new()
	_max_button.custom_minimum_size = Vector2(130.0, 56.0)
	_max_button.pressed.connect(_pick_max)
	tiers.add_child(_max_button)
	box.add_child(tiers)

	var stepper := HBoxContainer.new()  # any stake from $10 up to the Night's cap, in $5 steps
	_minus = _step_button("-")
	_minus.pressed.connect(_nudge.bind(-SlotMath.BET_STEP))
	stepper.add_child(_minus)
	_slider = HSlider.new()
	_slider.step = SlotMath.BET_STEP
	_slider.custom_minimum_size = Vector2(0.0, 52.0)
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.value_changed.connect(func(v: float) -> void: _set_bet(roundi(v)))
	stepper.add_child(_slider)
	_plus = _step_button("+")
	_plus.pressed.connect(_nudge.bind(SlotMath.BET_STEP))
	stepper.add_child(_plus)
	box.add_child(stepper)

	_status = Label.new()
	_status.theme_type_variation = &"CardName"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.clip_text = true
	_status.custom_minimum_size = Vector2(0.0, 34.0)
	box.add_child(_status)
	_chaos = Label.new()
	_chaos.theme_type_variation = &"Caption"
	_chaos.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chaos.clip_text = true
	_chaos.custom_minimum_size = Vector2(0.0, 26.0)
	box.add_child(_chaos)

	var row := HBoxContainer.new()
	_spin = Button.new()
	_spin.theme_type_variation = &"PrimaryButton"
	_spin.custom_minimum_size = Vector2(0.0, 64.0)
	_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spin.pressed.connect(_pull)
	row.add_child(_spin)
	var pays := Button.new()
	pays.text = "Pays"
	pays.toggle_mode = true
	pays.custom_minimum_size = Vector2(96.0, 64.0)
	pays.toggled.connect(func(on: bool) -> void: _pays_panel.visible = on)
	row.add_child(pays)
	var leave := Button.new()
	leave.text = "Leave"
	leave.custom_minimum_size = Vector2(110.0, 64.0)
	leave.pressed.connect(close)
	row.add_child(leave)
	box.add_child(row)

	_pays_panel = PanelContainer.new()
	_pays_panel.theme_type_variation = &"PanelInset"
	_pays_panel.anchor_left = 0.5
	_pays_panel.anchor_right = 0.5
	_pays_panel.anchor_top = 1.0
	_pays_panel.anchor_bottom = 1.0
	_pays_panel.offset_left = -PANEL_SIZE.x * 0.5
	_pays_panel.offset_right = PANEL_SIZE.x * 0.5
	_pays_panel.offset_bottom = -PANEL_SIZE.y - 28.0
	_pays_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_pays_panel.name = "Pays"
	var pay_text := Label.new()
	pay_text.theme_type_variation = &"Caption"
	pay_text.text = pays_text()
	_pays_panel.add_child(pay_text)
	add_child(_pays_panel)
	_pays_panel.hide()


func _step_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(72.0, 52.0)
	return b


## One line per win, best first: what it pays and what else the machine does.
static func pays_text() -> String:
	var lines := PackedStringArray()
	var ids: Array = SlotMath.WINS.keys().filter(func(id: StringName) -> bool: return id != &"miss")
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return int(SlotMath.WINS[a].mult) > int(SlotMath.WINS[b].mult))
	for id: StringName in ids:
		var w: Dictionary = SlotMath.WINS[id]
		var extra := PackedStringArray()
		for c: StringName in w.chaos:
			extra.append(String(CHAOS_NAMES.get(c, c)))
		lines.append("%s   x%d%s" % [w.title, w.mult, ("   + " + ", ".join(extra)) if not extra.is_empty() else ""])
	return "\n".join(lines)


const CHAOS_NAMES := {
	&"drink": "free drink", &"mystery": "mystery drink", &"crew_round": "round for the crew", &"hype": "chat goes wild",
	&"event": "random hazard", &"zap": "ZAP",
}


# --- state ----------------------------------------------------------------------------------------------------------

func _quota() -> int:
	return game_loop.current_night().quota if game_loop != null and not game_loop.nights.is_empty() else 600


## Stakes, cash and the button's state from the mirrored Night and Cash.
func _refresh() -> void:
	var quota := _quota()
	var cap := SlotMath.bet_cap(quota)
	_bets = SlotMath.bets(quota)
	var cash := economy.cash if economy != null else 0
	var bet := _stake()
	_cash.text = "-$%d" % -cash if cash < 0 else "Cash $%d" % cash
	for i in _tier_buttons.size():
		_tier_buttons[i].text = "$%d" % _bets[i]
		_tier_buttons[i].button_pressed = _bets[i] == bet
	_max_button.text = "MAX $%d" % _max_bet(cap, cash)
	_slider.set_block_signals(true)  # a Range clamps and emits when its bounds move: that is not the player dragging
	_slider.min_value = SlotMath.BET_MIN
	_slider.max_value = cap
	_slider.value = bet
	_slider.set_block_signals(false)
	_minus.disabled = bet <= SlotMath.BET_MIN
	_plus.disabled = bet >= cap
	var busy := _is_busy()
	_shown_busy = busy
	_spin.disabled = busy or bet > maxi(cash, 0)
	_spin.text = "Spinning…" if busy else ("PULL THE LEVER  $%d" % bet if bet <= maxi(cash, 0) else "Need $%d" % bet)


## The stake the strip would send now: the player's pick, else the middle preset, always inside tonight's limits (a new Night moves them).
func _stake() -> int:
	var quota := _quota()
	return clampi(_bet if _bet > 0 else SlotMath.bets(quota)[1], SlotMath.BET_MIN, SlotMath.bet_cap(quota))


## The biggest stake this purse may risk tonight: all of it up to the cap, in $5 steps (the floor when broke: the button then says what it needs).
static func _max_bet(cap: int, cash: int) -> int:
	return clampi(maxi(cash, 0) - posmod(maxi(cash, 0), SlotMath.BET_STEP), SlotMath.BET_MIN, cap)


func _is_busy() -> bool:
	return _spinning or (_machine != null and _machine.is_spinning())


func _pick_tier(tier: int) -> void:
	_set_bet(_bets[tier])


func _pick_max() -> void:
	_set_bet(_max_bet(SlotMath.bet_cap(_quota()), economy.cash if economy != null else 0))


func _nudge(by: int) -> void:
	_set_bet(_stake() + by)


func _set_bet(bet: int) -> void:
	_bet = bet
	_refresh()


func _pull() -> void:
	if _world == null or _spinning:
		return
	_spinning = true
	_status.text = "Good luck…"
	_chaos.text = ""
	_refresh()
	_world.request(SlotHouse.PROP_KIND, 0, {&"bet": _stake(), &"cash": economy.cash if economy != null else 0})  # the host checks both
	_watchdog = get_tree().create_timer(SlotMath.MAX_SPIN_SEC + 2.0)  # a lost answer frees the button
	_watchdog.timeout.connect(func() -> void:
		if _spinning:
			_spinning = false
			_refresh())


func _on_applied(peer_id: int, kind: StringName, _target: int, payload: Dictionary) -> void:
	if kind != SlotHouse.PROP_KIND or not payload.has(&"stops"):
		return
	if peer_id != multiplayer.get_unique_id():
		_status.text = "%s is on the machine" % _name_of(peer_id)
		_chaos.text = ""
	_refresh()


func _on_rejected(kind: StringName, reason: StringName) -> void:
	if kind != SlotHouse.PROP_KIND:
		return
	_spinning = false
	_status.text = BET_REASONS[reason] if BET_REASONS.has(reason) else WaitText.interaction(kind, reason, _world.last_wait_sec if _world != null else 0.0)
	_chaos.text = ""
	_refresh()


func _on_landed(peer_id: int, payload: Dictionary) -> void:
	var mine := peer_id == multiplayer.get_unique_id()
	if mine:
		_spinning = false
	var win: StringName = payload[&"win"]
	var w: Dictionary = SlotMath.WINS[win]
	var payout := int(payload[&"payout"])
	var text := String(w.title) + ("  +$%d" % payout if payout > 0 else "")
	var chaos := chaos_text(payload[&"chaos"])
	if not is_open():
		if mine and UIRouter.instance != null:  # the player stepped away mid-spin: say how it went (the toast is one 600 px line)
			var line := text if chaos == "" or text.length() + chaos.length() > TOAST_CHARS else text + " · " + chaos
			UIRouter.instance.toast(line, &"good" if payout > int(payload[&"bet"]) else &"info")
		return
	_status.text = text if mine else "%s: %s" % [_name_of(peer_id), text]
	_chaos.text = chaos
	_refresh()
	var mult := int(w.mult)
	if mine and (mult >= SlotMachine.BIG_MULT or win == &"zap"):  # a big win shakes the strip and the view
		_shake_view(clampf(float(mult) / 40.0, 0.35, 1.0))


## A big win rattles the strip and the camera's frustum (the cabinet's own shake is the machine's): `power` 0..1, decaying over ~0.6-1 s.
func _shake_view(power: float) -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
		_panel.position = _panel_home
	_panel_home = _panel.position
	var p := _local_player()
	var cam: Camera3D = p.cam if p != null else null
	_shake_tween = create_tween()
	_shake_tween.tween_method(_shake_step.bind(power, cam), 0.0, 1.0, 0.35 + 0.6 * power)
	_shake_tween.tween_callback(_shake_step.bind(1.0, power, cam))


func _shake_step(u: float, power: float, cam: Camera3D) -> void:
	var k := power * (1.0 - u)
	_panel.position = _panel_home + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * SHAKE_PX * k
	if is_instance_valid(cam):
		cam.h_offset = randf_range(-1.0, 1.0) * SHAKE_VIEW * k
		cam.v_offset = randf_range(-1.0, 1.0) * SHAKE_VIEW * k


## What the chaos of a payload did, one line ("On the house: Beer · The chat goes wild").
static func chaos_text(chaos: Array) -> String:
	var parts := PackedStringArray()
	for c: Dictionary in chaos:
		match c.kind:
			&"drink":
				parts.append("On the house: %s" % FxCatalog.drink(c.id).display_name)
			&"mystery":
				parts.append("Mystery drink: %s" % FxCatalog.drink(c.id).display_name)
			&"crew_round":
				parts.append("A round for the crew: %s" % FxCatalog.drink(c.id).display_name)
			&"hype":
				parts.append("The chat goes wild")
			&"event":
				parts.append("Hazard: %s" % FxCatalog.event(c.id).display_name)
			&"zap":
				parts.append("ZAP! The machine bites back")
	return " · ".join(parts)


func _name_of(peer_id: int) -> String:
	var net := get_node_or_null(^"/root/NetManager")
	if net != null:
		for e: Dictionary in net.call(&"get_roster"):
			if e.peer_id == peer_id:
				return e.name
	return "Someone"


# --- camera ---------------------------------------------------------------------------------------------------------

func _local_player() -> Player:
	for n in get_tree().get_nodes_in_group(&"players"):
		if (n as Player).is_local:
			return n
	return null


## Turn the local player to the reels (a short ease, yaw and pitch only): the screen blocks look input, so without this the
## show could be anywhere.
func _face_machine() -> void:
	var p := _local_player()
	if p == null or _machine == null:
		return
	var eye := p.global_position + Vector3(0.0, Player.EYE_M, 0.0)
	var at := _machine.global_position + Vector3(0.0, SlotCabinet.DRUM_Y, 0.0)
	var d := at - eye
	var flat := Vector2(d.x, d.z).length()
	if flat < 0.05:
		return
	var yaw := atan2(-d.x, -d.z)
	var pitch := clampf(atan2(d.y, flat) - deg_to_rad(VIEW_LIFT_DEG), -Player.PITCH_LIMIT, Player.PITCH_LIMIT)
	var yaw0 := p.rotation.y
	var pitch0 := p.head.rotation.x
	var dyaw := angle_difference(yaw0, yaw)
	if _face_tween != null:
		_face_tween.kill()
	_face_tween = create_tween()
	_face_tween.tween_method(func(k: float) -> void:
		if is_instance_valid(p):
			p.rotation.y = yaw0 + dyaw * k
			p.head.rotation.x = lerpf(pitch0, pitch, k), 0.0, 1.0, FACE_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
