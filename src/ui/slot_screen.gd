class_name SlotScreen
extends UIModal
## The bar slot's controls (docs/plan/02 §3.8): a strip at the bottom of the screen, so the machine stays in view while it spins.
## Pick a stake, pull the lever; the host rolls and every peer watches the same reels. Local to each peer; the only network
## traffic is the `slot_spin` interaction. Priority 5: over the Bartender, under the hazard vote and Pause.

const PANEL_SIZE := Vector2(640.0, 250.0)
const FACE_SEC := 0.35  ## how long the camera takes to turn to the machine

@export var economy: EconomyManager
@export var game_loop: GameLoop

var _tier := 1
var _spinning := false
var _machine: SlotMachine
var _world: WorldInteractions
var _bets := PackedInt32Array([0, 0, 0])
var _tier_buttons: Array[Button] = []
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
		b.custom_minimum_size = Vector2(150.0, 56.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_pick_tier.bind(i))
		tiers.add_child(b)
		_tier_buttons.append(b)
	box.add_child(tiers)

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
	_bets = SlotMath.bets(_quota())
	var cash := economy.cash if economy != null else 0
	_cash.text = "-$%d" % -cash if cash < 0 else "Cash $%d" % cash
	for i in _tier_buttons.size():
		_tier_buttons[i].text = "$%d" % _bets[i]
		_tier_buttons[i].button_pressed = i == _tier
	var bet := _bets[_tier]
	var busy := _spinning or (_machine != null and _machine.is_playing())
	_spin.disabled = busy or bet > maxi(cash, 0)
	_spin.text = "Spinning…" if busy else ("PULL THE LEVER  $%d" % bet if bet <= maxi(cash, 0) else "Need $%d" % bet)


func _pick_tier(tier: int) -> void:
	_tier = tier
	_refresh()


func _pull() -> void:
	if _world == null or _spinning:
		return
	_spinning = true
	_status.text = "Good luck…"
	_chaos.text = ""
	_refresh()
	_world.request(SlotHouse.PROP_KIND, 0, {&"tier": _tier})
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
	_status.text = WaitText.interaction(kind, reason, _world.last_wait_sec if _world != null else 0.0)
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
		if mine and UIRouter.instance != null:  # the player stepped away mid-spin: say how it went
			UIRouter.instance.toast(text + ("" if chaos == "" else " · " + chaos), &"good" if payout > int(payload[&"bet"]) else &"info")
		return
	_status.text = text if mine else "%s: %s" % [_name_of(peer_id), text]
	_chaos.text = chaos
	_refresh()


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
	var pitch := clampf(atan2(d.y, flat), -Player.PITCH_LIMIT, Player.PITCH_LIMIT)
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
