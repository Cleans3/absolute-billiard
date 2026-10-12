extends SceneTree

## Autoplay playtest (docs/plan/10 §8). Presses Solo, then plays a real Night of the real MainLevel unattended: every shot goes
## through the player's own CueController (enter_cue -> aim -> spin -> release_power -> PhysicsSim.request_shot), every
## Intermission buys drinks at the bar, votes the Event, pulls the slot and walks to GO LIVE through WorldInteractions.
## Needs a window (it screenshots). Measures what the player sees: FX per shot, strike->feedback latency, dead stretches while the
## balls roll, combos/tricks/chaos per Round, slot timings, cash, frame cost, plus thumbnail strips of three shots.
##   godot --path . -s src/tools/playtest.gd -- [--tag=before] [--out=DIR] [--nights=1] [--rounds=N] [--seed=7] [--skill=0.6]
##                                               [--spend=0.5] [--power=1.0] [--wild=0.2] [--slots=3] [--shots=N]
## Writes playtest_<tag>.json, summary_<tag>.md and sheet_<tag>_{typical,best,dull}.png to --out and prints the summary.

const OUT_DEFAULT := "/home/cleanse/work/.herdr/adhoc-1012a/playtest/"
const WINDOW := Vector2i(1280, 576)  # 20:9, the phone's landscape
const THUMB := Vector2i(320, 144)
const SHEET_COLS := 6
const SHEET_MAX_FRAMES := 42
const CAP_FAST_SEC := 0.1  # the first second after the strike is sampled finely: that is where "feedback within 0.3 s" lives
const CAP_SLOW_SEC := 0.25
const DEAD_GAP_SEC := 3.0
const SHOT_TIMEOUT_SEC := 30.0
const REACH_STAND_M := 0.7
const ROLL_MPS := 0.8  # a ball slower than this is creeping to rest, not rolling: it owes the player no feedback
const SPEED_STEPS: Array[float] = [0.3, 0.8, 1.5]  # dead stretches are also reported at these ball speeds

var tag := "run"
var out_dir := OUT_DEFAULT
var nights_wanted := 1
var rounds_cap := 0
var shots_cap := 0
var skill := 0.6
var spend := 0.5
var power_k := 1.0
var wild_share := 0.2
var slot_pulls := 3
var rng := RandomNumberGenerator.new()

var level: Node
var loop: GameLoop
var rd: RoundDirector
var table: Table
var sim: PhysicsSim
var fx: ImpactFx
var eco: EconomyManager
var world: WorldInteractions
var sched: EventScheduler
var effects: EffectManager
var player: Player
var cue: CueController
var machine: SlotMachine
var router: UIRouter

var t0_msec := 0
var shot: Dictionary = {}        # the shot in flight ({} between shots)
var shots: Array[Dictionary] = []
var rounds: Array[Dictionary] = []
var round_rec: Dictionary = {}
var slots: Array[Dictionary] = []
var cash_curve: Array = []
var anomalies: Array[String] = []
var frame_ms: PackedFloat32Array = []
var draw_calls: PackedInt32Array = []
var night_results: Array[Dictionary] = []

var _cap_on := false
var _cap_t0 := 0.0
var _cap_next := 0.0
var _cap_frames: Array[Image] = []
var _cap_motion: PackedFloat32Array = []
var _cap_prev: PackedByteArray = []
var _keep := {}                  # slot name -> {shot, frames}
var _last_usec := 0
var _skip_frame := false
var _toast_last := ""
var _slot_press := -1.0
var _slot_spin_seen := -1.0
var _slot_landed_evt := false
var _vote_seen: Array[String] = []
var _story_cards := 0
var _aim_thumbs: Array[Image] = []
var gpu_ms: PackedFloat32Array = []
var cpu_ms: PackedFloat32Array = []
var _seen_live: Dictionary = {}
var _fx_base: Dictionary = {}  # ImpactFx.stats at the end of the last Round: a Round's FX beats are the difference


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else "1"
		match kv[0]:
			"tag": tag = v
			"out": out_dir = v if v.ends_with("/") else v + "/"
			"nights": nights_wanted = int(v)
			"rounds": rounds_cap = int(v)
			"shots": shots_cap = int(v)
			"seed": rng.seed = int(v); seed(int(v))
			"skill": skill = float(v)
			"spend": spend = float(v)
			"power": power_k = float(v)
			"wild": wild_share = float(v)
			"slots": slot_pulls = int(v)
	DirAccess.make_dir_recursive_absolute(out_dir)
	DisplayServer.window_set_size(WINDOW)
	root.size = WINDOW
	create_timer(60.0 * 40.0).timeout.connect(func() -> void:
		print("PLAYTEST FAIL (40 min wall clock)")
		_finish()
		quit(1))
	_run()


func now() -> float:
	return float(Time.get_ticks_msec() - t0_msec) / 1000.0


# --- boot -----------------------------------------------------------------------------------------

func _run() -> void:
	await process_frame
	SaveManager.root = "user://playtest"  # the real profile stays out of it
	DirAccess.make_dir_recursive_absolute(SaveManager.root + "/checkpoints")
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby  # so the scene change to MainLevel frees it, as in the app
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, true)
	t0_msec = Time.get_ticks_msec()
	_bind()
	process_frame.connect(_sample)
	await _campaign()
	_finish()
	quit(0)


func _bind() -> void:
	level = current_scene
	loop = level.get_node("GameLoop")
	rd = level.get_node("RoundDirector")
	table = level.get_node("Table")
	sim = table.sim
	fx = level.get_node("ImpactFx")
	eco = level.get_node("EconomyManager")
	world = level.get_node("WorldInteractions")
	sched = level.get_node("EventScheduler")
	effects = level.get_node("EffectManager")
	router = UIRouter.instance
	machine = get_first_node_in_group(&"slot_machine") as SlotMachine
	for n in get_nodes_in_group(&"players"):
		if (n as Player).is_local:
			player = n
	cue = player.cue
	if player._controls != null:
		player._controls.touch = true  # the phone's HUD and widgets, and no captured mouse on the dev's desktop
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	fx.fx_fired.connect(_on_fx)
	rd.ball_potted.connect(_on_potted)
	rd.trick_detected.connect(_on_trick)
	rd.shot_ended.connect(_on_shot_ended)
	sim.shot_started.connect(_on_strike)
	eco.cash_changed.connect(func(b: int, d: int, r: StringName) -> void: cash_curve.append([snappedf(now(), 0.1), b, d, String(r)]))
	effects.effect_applied.connect(func(id: StringName, _t: int, _o: int, dur: float) -> void: _chaos(&"effect", String(id), dur))
	sched.event_applied.connect(func(_id: StringName, _tier: int, _mult: float) -> void: _snapshot_live.call_deferred())
	effects.live_changed.connect(_snapshot_live)
	world.interaction_applied.connect(func(_p: int, kind: StringName, _tid: int, _pl: Dictionary) -> void: _chaos(&"world", String(kind)))
	if machine != null:
		machine.landed.connect(_on_slot_landed)
	print("playtest: bound, seed campaign=%d tag=%s out=%s" % [loop.campaign_seed, tag, out_dir])


# --- per-frame sampler ----------------------------------------------------------------------------

func _sample() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var usec := Time.get_ticks_usec()
	if _last_usec != 0 and not _skip_frame and not shot.is_empty():
		frame_ms.append(float(usec - _last_usec) / 1000.0)
		draw_calls.append(int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)))
	if not shot.is_empty() and not bool(shot.ended) and _last_usec != 0:
		var v := 0.0
		for b in rd.get_balls():
			v = maxf(v, b.linear_velocity.length())
		var dt := float(usec - _last_usec) / 1e6
		if v > ROLL_MPS:
			shot.moving_s = float(shot.moving_s) + dt
		for i in SPEED_STEPS.size():  # seconds a ball moved faster than the step since the last visible feedback
			if v > SPEED_STEPS[i]:
				(shot.above as Array)[i] = float((shot.above as Array)[i]) + dt
				(shot.acc as Array)[i] = float((shot.acc as Array)[i]) + dt
				(shot.dead_at as Array)[i] = maxf(float((shot.dead_at as Array)[i]), float((shot.acc as Array)[i]))
		var rid := root.get_viewport_rid()
		gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
	_skip_frame = false
	_last_usec = usec
	if router != null and router._toast_label != null:
		var text: String = router._toast_label.text if router._toast_label.visible else ""
		if text != "" and text != _toast_last:
			_mark(&"toast")
		_toast_last = text
	if machine != null and _slot_press >= 0.0 and _slot_spin_seen < 0.0 and machine.is_spinning():
		_slot_spin_seen = now()
	if _cap_on:
		var t := now() - _cap_t0
		if t >= _cap_next and _cap_frames.size() < SHEET_MAX_FRAMES:
			_capture()
			_cap_next = t + (CAP_FAST_SEC if t < 1.0 else CAP_SLOW_SEC)


func _thumb() -> Image:
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_BILINEAR)
	_skip_frame = true
	return img


func _capture() -> void:
	var img := _thumb()
	var tiny := img.duplicate() as Image
	tiny.resize(32, 18, Image.INTERPOLATE_BILINEAR)
	var data := tiny.get_data()
	if not _cap_prev.is_empty():
		var sum := 0
		for i in data.size():
			sum += absi(int(data[i]) - int(_cap_prev[i]))
		_cap_motion.append(snappedf(float(sum) / float(data.size()) / 255.0, 0.0001))
	_cap_prev = data
	_cap_frames.append(img)
	_skip_frame = true


# --- events into the shot / round records -----------------------------------------------------------

func _mark(kind: StringName) -> void:
	if shot.is_empty():
		return
	(shot.marks as Array).append([now(), String(kind)])
	shot.last_mark = now()
	shot.acc = [0.0, 0.0, 0.0]


func _on_fx(kind: StringName, strength: float) -> void:
	_mark(kind)
	if shot.is_empty():
		return
	var d: Dictionary = shot.fx
	d[String(kind)] = int(d.get(String(kind), 0)) + 1
	(shot.fx_log as Array).append([snappedf(now() - float(shot.t_release), 0.01), String(kind), snappedf(strength, 0.01)])
	if kind == &"combo":
		shot.combo_n = maxi(int(shot.combo_n), int(strength))


func _on_strike(_ball: Ball, _intent: ShotIntent) -> void:
	if not shot.is_empty():
		shot.t_strike = now()


func _on_potted(ball: Ball, _shot_id: String, pocket_id: StringName) -> void:
	if shot.is_empty():
		return
	(shot.pots as Array).append([String(ball.ball_type.id) if ball.ball_type != null else "?", String(pocket_id), ball.is_cue_ball])
	if ball.is_cue_ball:
		shot.scratch = true


func _on_trick(trick: TrickShot, _shot_id: String) -> void:
	if not shot.is_empty():
		(shot.tricks as Array).append(String(trick.id))


func _on_shot_ended(_id: String, _shooter: int, raw_points: int, trick_ids: Array[StringName], foul: bool) -> void:
	if shot.is_empty():
		return
	shot.t_end = now()
	shot.points = raw_points
	shot.foul = foul
	shot.trick_ids = trick_ids.map(func(s: StringName) -> String: return String(s))
	shot.ended = true


## Every Drink and Event running right now is chaos the player can see on the Blackboard, however it got there
## (bought, poured on the house, a slot win, the vote): counted once per Round.
func _snapshot_live() -> void:
	if round_rec.is_empty():
		return
	for r in effects.live_drinks():
		var key := "%d:drink:%s" % [round_rec.index, r.drink.id]
		if not _seen_live.has(key):
			_seen_live[key] = true
			_chaos(&"drink", String(r.drink.id))
	for e in effects.live_events():
		var key := "%d:event:%s" % [round_rec.index, e.id]
		if not _seen_live.has(key):
			_seen_live[key] = true
			_chaos(&"event", String(e.id))


func _chaos(kind: StringName, id: String, a := 0.0, b := 0) -> void:
	if round_rec.is_empty():
		return
	(round_rec.chaos as Array).append({t = snappedf(now(), 0.1), kind = String(kind), id = id, a = a, b = b})


func _on_slot_landed(_peer: int, payload: Dictionary) -> void:
	_slot_landed_evt = true
	var chaos: Array = []
	for c: Dictionary in payload.get(&"chaos", []):
		chaos.append(String(c.kind) + (":" + String(c.id) if c.has(&"id") else ""))
	var rec := {
		t = snappedf(now(), 0.1),
		win = String(payload[&"win"]), bet = int(payload[&"bet"]), payout = int(payload[&"payout"]), tier = int(payload[&"tier"]),
		chaos = chaos, press_t = _slot_press,
		spin_visible_s = snappedf(_slot_spin_seen - _slot_press, 0.01) if _slot_spin_seen >= 0.0 else -1.0,
		result_s = snappedf(now() - _slot_press, 0.01) if _slot_press >= 0.0 else -1.0,
	}
	slots.append(rec)
	if not round_rec.is_empty():
		(round_rec.slot as Array).append(rec)
	for c in chaos:
		_chaos(&"slot", c)


# --- campaign ------------------------------------------------------------------------------------

func _campaign() -> void:
	var nights_done := 0
	while true:
		match loop.phase:
			GameLoop.Phase.INTERMISSION:
				if rounds_cap > 0 and rounds.size() >= rounds_cap:
					return
				await _intermission()
			GameLoop.Phase.ROUND_LIVE:
				await _round()
			GameLoop.Phase.RECKONING, GameLoop.Phase.CAMPAIGN_WON:
				night_results.append({night = loop.current_night().night_number, cash = eco.cash, demand = loop.ask_for(loop.night_index), phase = loop.phase})
				nights_done += 1
				if nights_done >= nights_wanted:
					return
				await _dismiss_modals()
				loop.advance()
				await process_frame
			GameLoop.Phase.GAME_OVER:
				night_results.append({night = loop.current_night().night_number, cash = eco.cash, demand = loop.ask_for(loop.night_index), phase = loop.phase, game_over = true})
				return
			_:
				await process_frame
		await process_frame
		if shots_cap > 0 and shots.size() >= shots_cap:
			return


## Whatever modal is open gets answered like a player would: the vote picks a card, the rest is dismissed.
func _dismiss_modals() -> void:
	for i in 12:
		if not UIRouter.blocking():
			return
		var cur := router.current
		if cur == level.get_node("UILayer/EventVote"):
			await _vote()
		else:
			if cur is StoryCards:
				_story_cards += 1
			if cur.has_method(&"close"):
				cur.call(&"close")
			else:
				cur.visible = false
		await process_frame
		await process_frame


func _vote() -> void:
	var ev: Control = level.get_node("UILayer/EventVote")
	var cards: Array = ev.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.is_visible_in_tree() and not b.disabled)
	if cards.is_empty():
		ev.call(&"close")
		return
	var pick: Button = cards[rng.randi() % cards.size()]
	_vote_seen.append(pick.text if pick.text != "" else pick.name)
	round_rec_note("vote", pick.text if pick.text != "" else pick.name)
	await create_timer(0.4).timeout  # reading time
	_save_full("vote_r%d" % (loop.round_index + 1))
	pick.pressed.emit()


func round_rec_note(key: String, value: Variant) -> void:
	if not round_rec.is_empty():
		(round_rec.notes as Array).append([key, value])


# --- intermission: bar, vote, slot, GO LIVE ------------------------------------------------------

func _intermission() -> void:
	var round_no := loop.round_index + 1
	round_rec = {
		index = round_no, night = loop.current_night().night_number, hazard_tier = loop.current_night().hazard_tiers[mini(round_no, 3) - 1],
		chaos = [], slot = [], notes = [], shots = [], cash_in = eco.cash, t_in = now(),
	}
	await _wait_until(func() -> bool: return player.mode == Player.Mode.WALK, 8.0)
	await create_timer(0.6).timeout
	await _dismiss_modals()
	await _bar()
	await _slot_session()
	await _fidget()
	await _dismiss_modals()
	await _go_live()


func _prop(kind: StringName) -> Interactable:
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == kind:
			return n
	return null


## Teleport = the walk: the stick is a human's way of getting here, the host only checks the distance.
func _walk_to(kind: StringName, stand := Vector3(-REACH_STAND_M, 0.0, 0.0)) -> Interactable:
	var prop := _prop(kind)
	if prop == null:
		anomalies.append("no prop " + String(kind))
		return null
	await _wait_until(func() -> bool: return player.mode == Player.Mode.WALK, 8.0)
	player.global_position = Vector3(prop.global_position.x + stand.x, player.global_position.y, prop.global_position.z + stand.z)
	player.velocity = Vector3.ZERO
	await create_timer(0.25).timeout
	return prop


func _bar() -> void:
	if await _walk_to(&"bar_serve") == null:
		return
	var menu := level.get_node("UILayer/BartenderMenu") as BartenderMenu
	menu.open()
	await create_timer(0.5).timeout
	_save_full("bar_r%d" % (loop.round_index + 1))
	var bought: Array[String] = []
	var budget := int(float(eco.cash) * spend)
	for i in eco.stock_size():
		var id := eco.stock_id(i)
		var btn := menu.drink_button(id)
		if btn == null or btn.disabled or eco.stock_left(i) <= 0:
			continue
		var price := FxCatalog.drink(id).cost_cash if FxCatalog.drink(id) != null else 0
		if price > budget or bought.size() >= 2 or rng.randf() > 0.8:
			continue
		budget -= price
		await create_timer(0.3).timeout
		btn.pressed.emit()
		bought.append(String(id))
		await create_timer(0.35).timeout
	round_rec_note("drinks", bought)
	menu.close()
	await process_frame


func _slot_session() -> void:
	if slot_pulls <= 0 or machine == null:
		return
	var prop := await _walk_to(&"slot_spin", Vector3(REACH_STAND_M, 0.0, 0.0))
	if prop == null:
		return
	var screen := level.get_node("UILayer/SlotScreen") as SlotScreen
	prop.try_use()
	await create_timer(0.5).timeout
	var tiers: Array = screen.get(&"_tier_buttons")
	var pull: Button = screen.get(&"_spin")
	for i in slot_pulls:
		var bets := SlotMath.bets(loop.current_night().quota)
		var tier := -1
		for k in range(bets.size() - 1, -1, -1):
			if bets[k] <= int(float(eco.cash) * 0.8):
				tier = k
				break
		if tier < 0:
			round_rec_note("slot", "broke")
			break
		(tiers[tier] as Button).pressed.emit()
		await create_timer(0.3).timeout
		_slot_landed_evt = false
		_slot_spin_seen = -1.0
		_slot_press = now()
		pull.pressed.emit()
		await _wait_until(func() -> bool: return _slot_landed_evt, 8.0)
		if not _slot_landed_evt:
			anomalies.append("slot never landed (tier %d)" % tier)
		await create_timer(0.6).timeout  # reads the result
		if slots.size() <= 3:
			_save_full("slot_%d" % slots.size())
		await create_timer(0.4).timeout
		_slot_press = -1.0
	screen.close()
	await process_frame


## The solo player's other free toys: the jukebox (once a Round). The pranks are the crew's, a shooter cannot grief themselves.
func _fidget() -> void:
	var prop := await _walk_to(&"jukebox")
	if prop == null:
		return
	var applied := false
	var on_applied := func(_p: int, kind: StringName, _t: int, _pl: Dictionary) -> void: applied = applied or kind == &"jukebox"
	world.interaction_applied.connect(on_applied)
	prop.try_use()
	await create_timer(0.8).timeout
	world.interaction_applied.disconnect(on_applied)
	round_rec_note("jukebox", applied)


func _go_live() -> void:
	for attempt in 4:
		var prop := await _walk_to(&"go_live", Vector3(0.0, 0.0, REACH_STAND_M))
		if prop == null:
			return
		prop.try_use()
		await _wait_until(func() -> bool: return loop.phase != GameLoop.Phase.INTERMISSION, 4.0)
		if loop.phase != GameLoop.Phase.INTERMISSION:
			return
	anomalies.append("GO LIVE never started the Round")


# --- the Round -----------------------------------------------------------------------------------

func _round() -> void:
	round_rec.t_live = now()
	await create_timer(0.45).timeout  # the GO / hazard banners are at full size now
	_save_full("go_r%d" % loop.round_index)
	round_rec.shots_budget = loop.shots_left
	round_rec.time_limit = loop.time_left
	round_rec.cash_live = eco.cash
	round_rec.balls = rd.get_balls().map(func(b: Ball) -> String: return String(b.ball_type.id) if b.ball_type != null else "?")
	for t: String in round_rec.balls:
		if not t in ["cue", "red_basic", "black_penalty"] and not _seen_live.has("%d:ball:%s" % [round_rec.index, t]):
			_seen_live["%d:ball:%s" % [round_rec.index, t]] = true
			_chaos(&"ball", t)
	_snapshot_live()
	var idx := loop.round_index
	while loop.phase == GameLoop.Phase.ROUND_LIVE and loop.round_index == idx:
		if shots_cap > 0 and shots.size() >= shots_cap:
			break
		await _dismiss_modals()
		await _take_shot()
	round_rec.t_out = now()
	var beats := {}
	for k: StringName in [&"hazard", &"drink", &"go", &"cleared", &"time", &"flames", &"combo", &"trick", &"trick_minor"]:
		var n := int(fx.stats.get(k, 0)) - int(_fx_base.get(k, 0))
		if n > 0:
			beats[String(k)] = n
	round_rec.beats = beats
	_fx_base = fx.stats.duplicate()
	round_rec.cash_out = eco.cash
	round_rec.points = loop.round_points
	round_rec.reason = String(loop._end_reason)
	round_rec.shots_taken = (round_rec.shots as Array).size()
	rounds.append(round_rec)
	print("playtest: round %d done, %d shots, %d pts, cash %d -> %d (%s)" % [round_rec.index, round_rec.shots_taken, round_rec.points, round_rec.cash_in, round_rec.cash_out, round_rec.reason])


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball and not b.is_pocketed:
			return b
	return null


func _take_shot() -> void:
	var ok := await _wait_until(func() -> bool:
		return sim.awake == 0 and not rd.shot_in_progress and _cue_ball() != null and player.mode == Player.Mode.WALK, 25.0)
	if not ok or loop.phase != GameLoop.Phase.ROUND_LIVE:
		if loop.phase == GameLoop.Phase.ROUND_LIVE:
			anomalies.append("table never settled before shot %d" % (shots.size() + 1))
			await create_timer(1.0).timeout
		return
	var ball := _cue_ball()
	var plan := _plan(ball)
	var entered := false
	for attempt in 6:
		var back := Vector2(plan.aim.x, plan.aim.y) * -0.9
		player.global_position = Vector3(ball.global_position.x + back.x, player.global_position.y, ball.global_position.z + back.y)
		player.velocity = Vector3.ZERO
		await process_frame
		if player.enter_cue():
			entered = true
			break
		await create_timer(0.3).timeout
	if not entered:
		anomalies.append("enter_cue refused 6 times (shot %d)" % (shots.size() + 1))
		return
	cue.turn(wrapf(atan2(-plan.aim.x, -plan.aim.y) - cue.aim_yaw, -PI, PI))
	cue.set_spin(plan.spin)
	cue.set_elevation(plan.elev)
	if cue.call_required:
		cue.call_pocket(_pocket_index(plan.pocket))
	await create_timer(0.35).timeout  # the player's aiming time; the aim screenshot sees the table as it is then
	var stage := fx.get(&"_stage") as FxStage
	var fx_busy := not stage.idle()
	var aim_a: Variant = stage.get(&"_aim_a")  # null on a build without the aim fade (the before-run's tree)
	var fx_opaque := fx_busy and (aim_a == null or float(aim_a) > 0.5)  # 0.35 s into the aim the show should be ghosted
	if shots.size() < 3 or shots.size() % 6 == 0:
		_save_full("aim_%02d" % (shots.size() + 1))
	_aim_thumbs.append(_thumb())
	shot = {
		n = shots.size() + 1, round = loop.round_index, kind = plan.kind, power = snappedf(plan.power, 0.01), spin = [snappedf(plan.spin.x, 0.01), snappedf(plan.spin.y, 0.01)],
		elev = snappedf(plan.elev, 0.1), target = plan.target, pocket = String(plan.pocket), aim_err_deg = snappedf(plan.err_deg, 0.01),
		fx = {}, fx_log = [], marks = [], pots = [], tricks = [], trick_ids = [], combo_n = 0, scratch = false, ended = false,
		t_release = now(), t_strike = -1.0, t_end = -1.0, cash_before = eco.cash, awake_before = sim.awake,
		last_mark = now(), moving_s = 0.0, acc = [0.0, 0.0, 0.0], above = [0.0, 0.0, 0.0], dead_at = [0.0, 0.0, 0.0], dc_aim = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)), fx_busy_at_aim = fx_busy, fx_opaque_at_aim = fx_opaque, ball_count = rd.get_balls().size(),
	}
	(shot.marks as Array).append([now(), "release"])
	frame_ms.clear()
	draw_calls.clear()
	gpu_ms.clear()
	cpu_ms.clear()
	_cap_frames = []
	_cap_motion = PackedFloat32Array()
	_cap_prev = PackedByteArray()
	_cap_t0 = now()
	_cap_next = 0.0
	_cap_on = true
	cue.release_power(plan.power)
	var done := await _wait_until(func() -> bool: return bool(shot.ended), SHOT_TIMEOUT_SEC)
	if not done:
		anomalies.append("shot %d never resolved" % shot.n)
		shot.t_end = now()
	await create_timer(0.9).timeout  # the tail: banners, confetti and the settle line are still on screen
	_cap_on = false
	_finish_shot()


func _finish_shot() -> void:
	var t_rel: float = shot.t_release
	var times: Array[float] = []
	for m: Array in shot.marks:
		times.append(float(m[0]))
	times.append(float(shot.t_end))
	times.sort()
	var gap_max := 0.0
	var dead_total := 0.0
	for i in range(1, times.size()):
		var g := times[i] - times[i - 1]
		gap_max = maxf(gap_max, g)
		dead_total += maxf(0.0, g - 1.0)
	shot.duration = snappedf(float(shot.t_end) - t_rel, 0.01)
	shot.quiet_gap_max = snappedf(gap_max, 0.01)  # longest stretch with no FX at all, creeping balls included
	shot.dead_max = snappedf(float((shot.dead_at as Array)[1]), 0.01)  # seconds a ball rolled faster than ROLL_MPS with no FX since the last one
	shot.dead_total = snappedf(dead_total, 0.01)
	shot.tail_s = snappedf(float(shot.t_end) - float(shot.last_mark), 0.01)  # last FX -> shot resolved
	shot.rolling_s = snappedf(float(shot.moving_s), 0.01)
	var first_fx := -1.0
	var first_hit := -1.0
	for e: Array in shot.fx_log:
		if first_fx < 0.0:
			first_fx = float(e[0])
		if first_hit < 0.0 and e[1] != "kick":
			first_hit = float(e[0])
	shot.first_fx_s = first_fx
	shot.first_hit_fx_s = first_hit
	var count := 0
	var non_kick := 0
	for k: String in shot.fx:
		count += int(shot.fx[k])
		if k != "kick":
			non_kick += int(shot.fx[k])
	shot.fx_count = count
	shot.fx_non_kick = non_kick
	shot.cash_delta = eco.cash - int(shot.cash_before)
	shot.frame_ms_p95 = _p95(frame_ms)
	shot.gpu_ms_p95 = _p95(gpu_ms)
	shot.cpu_ms_p95 = _p95(cpu_ms)
	shot.draw_calls_max = _max_i(draw_calls)
	shot.motion = _cap_motion
	shot.live_drinks = effects.live_drinks().size()
	shot.live_events = effects.live_events().size()
	shot.thumbs = _cap_frames.size()
	shot.erase("last_mark")
	shot.erase("acc")
	shot.above = (shot.above as Array).map(func(v: float) -> float: return snappedf(v, 0.01))
	shot.marks = (shot.marks as Array).map(func(m: Array) -> Array: return [snappedf(float(m[0]) - t_rel, 0.01), m[1]])
	_snapshot_live()
	_keep_if_representative()
	shots.append(shot)
	(round_rec.shots as Array).append(shot.n)
	print("playtest: shot %02d %s p=%.2f fx=%d(%d non-kick) pots=%d combo=%d tricks=%s dur=%.1fs rolling=%.1fs dead=%.1fs tail=%.1fs first_fx=%.2fs aimfx=%s" % [shot.n, shot.kind, shot.power, count, non_kick, (shot.pots as Array).size(), shot.combo_n, str(shot.trick_ids), shot.duration, shot.rolling_s, shot.dead_max, shot.tail_s, first_fx, str(shot.fx_busy_at_aim)])
	shot = {}
	_cap_frames = []


func _p95(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return snappedf(s[mini(s.size() - 1, int(float(s.size()) * 0.95))], 0.01)


# --- shot planning -------------------------------------------------------------------------------

func _pocket_index(id: StringName) -> int:
	for i in table.layout.pockets.size():
		if table.layout.pockets[i].id == id:
			return i
	return 0


## Ghost-ball line to the best ball-pocket pair (small cut, short, clear), noisy by skill; or a wild hard shot into the pack.
func _plan(cue_ball: Ball) -> Dictionary:
	var r := table.spec.ball_radius_m
	var cp := Vector2(cue_ball.global_position.x, cue_ball.global_position.z)
	var objects: Array[Ball] = []
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.is_pocketed:
			objects.append(b)
	var best: Dictionary = {}
	var best_score := -1e9
	for b in objects:
		var value := rd.value_of(b.ball_type) if b.ball_type != null else 1
		if value <= 0:
			continue
		var bp := Vector2(b.global_position.x, b.global_position.z)
		for id: StringName in table.pockets:
			var pk: PocketSpec = table.pockets[id]
			var pc := Vector2(pk.position.x, pk.position.z)
			var to_p := pc - bp
			var d_bp := to_p.length()
			var dir := to_p / d_bp
			var ghost := bp - dir * 2.0 * r
			var aim := ghost - cp
			var d_cg := aim.length()
			if d_cg < 2.0 * r:
				continue
			var cut := acos(clampf(aim.normalized().dot(dir), -1.0, 1.0))
			if cut > deg_to_rad(62.0):
				continue
			var score := float(value) * 0.02 - rad_to_deg(cut) * 0.06 - (d_cg + d_bp) * 0.5
			if _blocked(cp, ghost, objects, b, 1.9 * r) or _blocked(bp, pc, objects, b, 1.9 * r):
				score -= 6.0
			if score > best_score:
				best_score = score
				best = {aim = aim.normalized(), target = String(b.ball_type.id) if b.ball_type != null else "?", pocket = id, dist = d_cg + d_bp}
	var wild := best.is_empty() or rng.randf() < wild_share
	var plan := {kind = "pot", elev = 0.0, spin = Vector2.ZERO}
	if wild:
		var centre := Vector2.ZERO
		for b in objects:
			centre += Vector2(b.global_position.x, b.global_position.z)
		centre /= maxf(objects.size(), 1.0)
		var a := (centre - cp).normalized().rotated(rng.randfn(0.0, 0.12))
		plan = {kind = "wild", aim = a, target = "pack", pocket = &"", power = rng.randf_range(0.7, 1.0), elev = 0.0,
			spin = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 0.7), dist = 3.0}
		if rng.randf() < 0.25:
			plan.elev = rng.randf_range(8.0, 22.0)
	else:
		plan = {kind = "pot", aim = best.aim, target = best.target, pocket = best.pocket, dist = best.dist, elev = 0.0,
			power = clampf((0.28 + 0.085 * float(best.dist)) * power_k * rng.randf_range(0.9, 1.15), 0.2, 1.0),
			spin = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 0.45)}
	var err := rng.randfn(0.0, (1.0 - skill) * 2.4 + 0.3)
	plan.err_deg = err
	plan.aim = (plan.aim as Vector2).rotated(deg_to_rad(err))
	return plan


func _blocked(from: Vector2, to: Vector2, objects: Array[Ball], skip: Ball, clearance: float) -> bool:
	var seg := to - from
	var len2 := seg.length_squared()
	if len2 < 0.0001:
		return false
	for o in objects:
		if o == skip:
			continue
		var p := Vector2(o.global_position.x, o.global_position.z)
		var t := clampf((p - from).dot(seg) / len2, 0.0, 1.0)
		if (from + seg * t).distance_to(p) < clearance:
			return true
	return false


# --- helpers ---------------------------------------------------------------------------------

func _wait_until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return bool(cond.call())


func _save_full(name: String) -> void:
	var img := root.get_texture().get_image()
	img.save_png(out_dir + "%s_%s.png" % [tag, name])
	_skip_frame = true


# --- representative shots + contact sheets -------------------------------------------------------

## typical = the first shot with a hit, best = most FX, dull = fewest FX among shots that reached a ball.
func _keep_if_representative() -> void:
	if _cap_frames.size() < 4:
		return
	var score := int(shot.fx_count) + int(shot.combo_n) * 3 + (shot.trick_ids as Array).size() * 5
	var summary := _shot_line(shot)
	if not _keep.has("typical") and int(shot.fx_non_kick) > 0:
		_keep["typical"] = {shot = summary, frames = _cap_frames.duplicate(), score = score}
	if not _keep.has("best") or score > int(_keep.best.score):
		_keep["best"] = {shot = summary, frames = _cap_frames.duplicate(), score = score}
	if not bool(shot.scratch) and (not _keep.has("dull") or score < int(_keep.dull.score)):
		_keep["dull"] = {shot = summary, frames = _cap_frames.duplicate(), score = score}


func _shot_line(s: Dictionary) -> String:
	return "shot %d (round %d, %s, p=%.2f): fx %s, pots %d, tricks %s, %.1fs" % [s.n, s.round, s.kind, s.power, JSON.stringify(s.fx), (s.pots as Array).size(), str(s.trick_ids), float(s.duration)]


func _write_sheets() -> void:
	if not _aim_thumbs.is_empty():
		var cols := 8
		var rows := ceili(float(_aim_thumbs.size()) / cols)
		var aims := Image.create(THUMB.x * cols, THUMB.y * rows, false, Image.FORMAT_RGB8)
		for i in _aim_thumbs.size():
			aims.blit_rect(_aim_thumbs[i], Rect2i(Vector2i.ZERO, THUMB), Vector2i((i % cols) * THUMB.x, (i / cols) * THUMB.y))
		aims.save_png(out_dir + "aims_%s.png" % tag)
	for k: String in _keep:
		var frames: Array = _keep[k].frames
		var rows := ceili(float(frames.size()) / SHEET_COLS)
		var sheet := Image.create(THUMB.x * SHEET_COLS, THUMB.y * rows, false, Image.FORMAT_RGB8)
		sheet.fill(Color.BLACK)
		for i in frames.size():
			sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, THUMB), Vector2i((i % SHEET_COLS) * THUMB.x, (i / SHEET_COLS) * THUMB.y))
		sheet.save_png(out_dir + "sheet_%s_%s.png" % [tag, k])


# --- report --------------------------------------------------------------------------------------

func _finish() -> void:
	if shots.is_empty() and rounds.is_empty():
		print("PLAYTEST: nothing played")
	_write_sheets()
	var rep := _report()
	var f := FileAccess.open(out_dir + "playtest_%s.json" % tag, FileAccess.WRITE)
	f.store_string(JSON.stringify({report = rep, rounds = rounds, shots = shots, slots = slots, cash = cash_curve, nights = night_results, anomalies = anomalies}, "\t"))
	f.close()
	var md := _summary_md(rep)
	var m := FileAccess.open(out_dir + "summary_%s.md" % tag, FileAccess.WRITE)
	m.store_string(md)
	m.close()
	print(md)
	print("PLAYTEST DONE ", tag)


func _report() -> Dictionary:
	var n := shots.size()
	var any_fx := 0
	var hit_fx := 0
	var late := 0
	var dead_over := 0
	var dead_worst := 0.0
	var dead_total := 0.0
	var durations := PackedFloat32Array()
	var first_fx := PackedFloat32Array()
	var pots := 0
	var scratches := 0
	var kinds := {}
	var aim_busy := 0
	var aim_opaque := 0
	var tails := PackedFloat32Array()
	var rolls := PackedFloat32Array()
	var tricks_shots := 0
	var combo_shots := 0
	for s in shots:
		if int(s.fx_count) > 0:
			any_fx += 1
		if int(s.fx_non_kick) > 0:
			hit_fx += 1
		if float(s.first_fx_s) < 0.0 or float(s.first_fx_s) > 0.3:
			late += 1
		else:
			first_fx.append(float(s.first_fx_s))
		if float(s.dead_max) > DEAD_GAP_SEC:
			dead_over += 1
		dead_worst = maxf(dead_worst, float(s.dead_max))
		dead_total += float(s.dead_total)
		durations.append(float(s.duration))
		tails.append(float(s.tail_s))
		rolls.append(float(s.rolling_s))
		aim_busy += 1 if s.fx_busy_at_aim else 0
		aim_opaque += 1 if s.fx_opaque_at_aim else 0
		pots += (s.pots as Array).size()
		scratches += 1 if s.scratch else 0
		if not (s.trick_ids as Array).is_empty():
			tricks_shots += 1
		if int(s.combo_n) >= 2:
			combo_shots += 1
		for k: String in s.fx:
			kinds[k] = int(kinds.get(k, 0)) + int(s.fx[k])
	var nr := maxi(rounds.size(), 1)
	var combo_trick_rounds := 0
	var chaos_rounds := 0
	var chaos_total := 0
	var per_round: Array = []
	for r in rounds:
		var shots_r := shots.filter(func(s: Dictionary) -> bool: return (r.shots as Array).has(s.n))
		var ct := shots_r.filter(func(s: Dictionary) -> bool: return int(s.combo_n) >= 2 or not (s.trick_ids as Array).is_empty()).size()
		var chaos_kinds := {}
		for c: Dictionary in r.chaos:
			if c.kind == "world" or c.kind == "effect":
				continue  # a world press and an Effect are the body of a Drink/Event/slot win already counted by its source
			chaos_kinds[c.kind + ":" + c.id] = true
		var chaos_n := chaos_kinds.size()
		combo_trick_rounds += 1 if ct > 0 else 0
		chaos_rounds += 1 if chaos_n > 0 else 0
		chaos_total += chaos_n
		per_round.append({round = r.index, night = r.night, combos_tricks = ct, chaos = chaos_n, beats = r.beats, hazard_tier = r.hazard_tier, points = r.points, shots = r.shots_taken, reason = r.reason})
	var slot_times := PackedFloat32Array()
	var slot_vis := PackedFloat32Array()
	var slot_net := 0
	var slot_chaos := 0
	for s in slots:
		slot_times.append(float(s.result_s))
		slot_vis.append(float(s.spin_visible_s))
		slot_net += int(s.payout) - int(s.bet)
		slot_chaos += (s.chaos as Array).size()
	var above: Array = [[], [], []]  # plain Arrays: a PackedFloat32Array behind `as` is a copy and the append is lost
	for s in shots:
		for i in 3:
			(above[i] as Array).append(float((s.above as Array)[i]))
	var all_frames := PackedFloat32Array()
	var gpu := PackedFloat32Array()
	var cpu := PackedFloat32Array()
	var dc_max := 0
	var dc_aim := 0
	var dead_steps := [0.0, 0.0, 0.0]
	for s in shots:
		all_frames.append(float(s.frame_ms_p95))
		gpu.append(float(s.gpu_ms_p95))
		cpu.append(float(s.cpu_ms_p95))
		dc_max = maxi(dc_max, int(s.draw_calls_max))
		dc_aim = maxi(dc_aim, int(s.dc_aim))
		for i in 3:
			dead_steps[i] = maxf(dead_steps[i], float((s.dead_at as Array)[i]))
	return {
		tag = tag, shots = n, rounds = rounds.size(), pots = pots, scratches = scratches, kinds = kinds,
		shots_any_fx_pct = _pct(any_fx, n), shots_hit_fx_pct = _pct(hit_fx, n), late_feedback_shots = late,
		first_fx_median_s = _median(first_fx), shot_duration_median_s = _median(durations), shot_duration_max_s = _max(durations),
		aim_fx_busy_pct = _pct(aim_busy, n), aim_fx_opaque_pct = _pct(aim_opaque, n), tail_median_s = _median(tails), rolling_median_s = _median(rolls), dead_max_s = dead_worst, shots_with_dead_over_3s = dead_over, dead_total_s = snappedf(dead_total, 0.1),
		combo_shots = combo_shots, trick_shots = tricks_shots, rounds_with_combo_or_trick = combo_trick_rounds, rounds_with_chaos = chaos_rounds,
		chaos_per_round = snappedf(float(chaos_total) / float(nr), 0.01), per_round = per_round,
		slot_pulls = slots.size(), slot_result_median_s = _median(slot_times), slot_result_max_s = _max(slot_times), slot_spin_visible_median_s = _median(slot_vis),
		slot_net = slot_net, slot_chaos = slot_chaos,
		above_median_s = [_median(PackedFloat32Array(above[0])), _median(PackedFloat32Array(above[1])), _median(PackedFloat32Array(above[2]))], frame_ms_p95_worst = _max(all_frames), gpu_ms_p95_worst = _max(gpu), cpu_ms_p95_worst = _max(cpu), draw_calls_max = dc_max, draw_calls_aim_max = dc_aim, dead_at_speed = dead_steps, story_cards_closed = _story_cards, anomalies = anomalies.size(),
		cash_end = eco.cash, nights = night_results,
	}


func _pct(a: int, b: int) -> float:
	return snappedf(100.0 * float(a) / float(maxi(b, 1)), 0.1)


func _median(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return -1.0
	var s := a.duplicate()
	s.sort()
	return snappedf(s[s.size() / 2], 0.01)


func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return snappedf(m, 0.01)


func _max_i(a: PackedInt32Array) -> int:
	var m := 0
	for v in a:
		m = maxi(m, v)
	return m


func _summary_md(r: Dictionary) -> String:
	var rounds_n := maxi(int(r.rounds), 1)
	var lines := PackedStringArray()
	lines.append("# Playtest %s" % r.tag)
	lines.append("")
	lines.append("%d shots over %d Rounds, %d pots, %d scratches, cash end %d, %d anomalies." % [r.shots, r.rounds, r.pots, r.scratches, r.cash_end, r.anomalies])
	lines.append("")
	lines.append("| target | measured | |")
	lines.append("|---|---|---|")
	lines.append("| every shot >= 1 visible FX | any %.1f %% / hit-or-pot FX %.1f %% | %s |" % [r.shots_any_fx_pct, r.shots_hit_fx_pct, _ok(r.shots_any_fx_pct >= 100.0 and r.shots_hit_fx_pct >= 90.0)])
	lines.append("| feedback <= 0.3 s from strike | median %.2f s, %d late shots | %s |" % [r.first_fx_median_s, r.late_feedback_shots, _ok(r.late_feedback_shots == 0)])
	lines.append("| no dead stretch > 3 s while balls roll (> %.1f m/s) | worst %.1f s, %d shots over; worst at > 0.3 / 0.8 / 1.5 m/s: %.1f / %.1f / %.1f s | %s |" % [ROLL_MPS, r.dead_max_s, r.shots_with_dead_over_3s, r.dead_at_speed[0], r.dead_at_speed[1], r.dead_at_speed[2], _ok(r.shots_with_dead_over_3s == 0)])
	lines.append("| >= 1 combo or trick per Round | %d / %d Rounds (%d combo shots, %d trick shots) | %s |" % [r.rounds_with_combo_or_trick, r.rounds, r.combo_shots, r.trick_shots, _ok(r.rounds_with_combo_or_trick >= rounds_n)])
	lines.append("| >= 1 chaos event per Round | %d / %d Rounds, %.2f per Round | %s |" % [r.rounds_with_chaos, r.rounds, r.chaos_per_round, _ok(r.rounds_with_chaos >= rounds_n)])
	lines.append("| slot result <= 3 s | median %.2f s, max %.2f s over %d pulls (reels visibly turning after %.2f s) | %s |" % [r.slot_result_median_s, r.slot_result_max_s, r.slot_pulls, r.slot_spin_visible_median_s, _ok(r.slot_pulls > 0 and r.slot_result_max_s <= 3.0)])
	lines.append("| frame budget (dev PC, 07 §1) | render GPU p95 %.2f ms / CPU p95 %.2f ms (wall frame p95 %.1f ms, shared with other panes); draw calls max %d in shots, %d at aim (<= 120) | %s |" % [r.gpu_ms_p95_worst, r.cpu_ms_p95_worst, r.frame_ms_p95_worst, r.draw_calls_max, r.draw_calls_aim_max, _ok(r.draw_calls_max <= 120)])
	lines.append("| FX never hide the aim | FX still alive when aiming starts: %.1f %% of shots, still opaque 0.35 s into the aim: %.1f %%; look at aims_%s.png | %s |" % [r.aim_fx_busy_pct, r.aim_fx_opaque_pct, r.tag, _ok(r.aim_fx_opaque_pct == 0.0)])
	lines.append("")
	lines.append("FX fired: %s" % JSON.stringify(r.kinds))
	lines.append("Shot duration median %.1f s (max %.1f s), of which a ball moves faster than 0.3 / 0.8 / 1.5 m/s for a median %.1f / %.1f / %.1f s (the rest is creep to rest); slot net %+d, slot chaos %d." % [r.shot_duration_median_s, r.shot_duration_max_s, r.above_median_s[0], r.above_median_s[1], r.above_median_s[2], r.slot_net, r.slot_chaos])
	lines.append("")
	lines.append("| Round | hazard tier | shots | points | combos+tricks | chaos | ended | FX beats |")
	lines.append("|---|---|---|---|---|---|---|---|")
	for p: Dictionary in r.per_round:
		lines.append("| N%d R%d | %d | %d | %d | %d | %d | %s | %s |" % [p.night, p.round, p.hazard_tier, p.shots, p.points, p.combos_tricks, p.chaos, p.reason, JSON.stringify(p.beats)])
	for k: String in _keep:
		lines.append("")
		lines.append("sheet_%s_%s.png: %s" % [r.tag, k, _keep[k].shot])
	if not anomalies.is_empty():
		lines.append("")
		lines.append("Anomalies: " + "; ".join(anomalies))
	return "\n".join(lines) + "\n"


func _ok(v: bool) -> String:
	return "PASS" if v else "FAIL"
