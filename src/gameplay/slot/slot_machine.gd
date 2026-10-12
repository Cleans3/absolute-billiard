class_name SlotMachine
extends Node3D
## The bar slot machine (docs/plan/02 §3.9): cabinet, three drums, lever, bulbs and a readout, built in code. Every peer plays the
## same spin from the `slot_spin` interaction's payload (the host chose the stops); nothing here decides anything.

signal landed(peer_id: int, payload: Dictionary)  ## the last drum stopped: the host pays now

const ATLAS := preload("res://assets/slot/symbols.svg")
const SHADER := preload("res://src/shaders/slot_machine.gdshader")
const SPIN_RADPS := 16.0   ## drum speed before it brakes (a face passes every ~16 ms at 60 fps: the shader smears it)
const EASE_SEC := 0.55     ## the braking run
const BIG_MULT := 7        ## a win from this multiple of the bet strobes the bulbs
const IDLE_TEXT := "PLAY ME"

var _mat: ShaderMaterial
var _drums: Array[MeshInstance3D] = []
var _angle := PackedFloat32Array([0.0, 0.0, 0.0])  ## where each drum rests / last was (absolute radians about X)
var _plans: Array[Run] = []
var _lever: Node3D
var _led: Label3D
var _title: Label3D
var _pop: Label3D
var _coins: CPUParticles3D
var _tween_lever: Tween
var _tween_pop: Tween
var _t := 0.0
var _total := 0.0          ## seconds until the spin and its celebration are over
var _landed := true
var _peer := 0
var _result := {}
var _shake := 0.0
var _home := Vector3.ZERO


## One drum's closed-form run (see _plan_reel).
class Run:
	extends RefCounted
	var from := 0.0
	var v := 0.0
	var t_brake := 0.0
	var run := 0.0
	var t_stop := 0.0
	var final := 0.0


func _ready() -> void:
	add_to_group(&"slot_machine")
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	var atlas := ATLAS.get_image()  # the importer leaves a lossless texture without mipmaps: add them, the drums are seen from across the room
	atlas.generate_mipmaps()
	_mat.set_shader_parameter(&"atlas", ImageTexture.create_from_image(atlas))
	_add_mesh(SlotCabinet.body_mesh(), Vector3.ZERO)
	var drum := SlotCabinet.drum_mesh()
	for i in SlotMath.REELS:
		var d := _add_mesh(drum, Vector3(SlotCabinet.DRUM_X[i], SlotCabinet.DRUM_Y, 0.0))
		_angle[i] = float(randi() % SlotCabinet.FACES) * TAU / SlotCabinet.FACES
		d.rotation.x = _angle[i]
		_drums.append(d)
	_lever = Node3D.new()
	_lever.position = SlotCabinet.LEVER_AT
	add_child(_lever)
	var arm := MeshInstance3D.new()
	arm.mesh = SlotCabinet.lever_mesh()
	arm.material_override = _mat
	arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lever.add_child(arm)
	var body := StaticBody3D.new()  # the cabinet is a wall to walk into (07 §1 layer 4 "world")
	body.collision_layer = 8
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SlotCabinet.WIDTH, 1.86, SlotCabinet.DEPTH)
	shape.shape = box
	shape.position.y = box.size.y * 0.5
	body.add_child(shape)
	add_child(body)
	_title = _label("8-BALL SLOTS", 56, SlotCabinet.GOLD, SlotCabinet.TITLE_AT, 0.0017, 6)
	_led = _label(IDLE_TEXT, 44, Color("FFB020"), SlotCabinet.LED_AT, 0.0015, 4)
	_pop = _label("", 96, Color.WHITE, SlotCabinet.POP_AT, 0.004, 14)
	_pop.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_pop.no_depth_test = true
	_pop.visible = false
	_coins = CPUParticles3D.new()  # a win spits coins from the tray; one draw call while they fly, no extra material
	_coins.mesh = SlotCabinet.coin_mesh()
	_coins.material_override = _mat
	_coins.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_coins.emitting = false
	_coins.one_shot = true
	_coins.explosiveness = 0.9
	_coins.lifetime = 0.9
	_coins.local_coords = false
	_coins.position = SlotCabinet.COIN_AT
	_coins.direction = Vector3(0.0, 0.7, 1.0)
	_coins.spread = 32.0
	_coins.initial_velocity_min = 2.0
	_coins.initial_velocity_max = 3.8
	_coins.gravity = Vector3(0.0, -9.8, 0.0)
	_coins.angle_min = 0.0
	_coins.angle_max = 360.0
	_coins.angular_velocity_min = -540.0
	_coins.angular_velocity_max = 540.0
	_coins.color = SlotCabinet.GOLD
	add_child(_coins)
	_home = position
	set_process(false)
	_bind.call_deferred()


func _add_mesh(mesh: Mesh, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # props never enter the one shadow map (07 §2)
	add_child(mi)
	return mi


func _label(text: String, size: int, color: Color, at: Vector3, pixel: float, outline: int) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = pixel
	l.modulate = color
	l.outline_size = outline
	l.outline_modulate = Color(0.04, 0.02, 0.02)
	l.position = at
	l.double_sided = false
	add_child(l)
	return l


func _bind() -> void:
	var world := get_tree().get_first_node_in_group(&"world_interactions") as WorldInteractions
	if world != null:
		world.interaction_applied.connect(_on_applied)


func _on_applied(peer_id: int, kind: StringName, _target_id: int, payload: Dictionary) -> void:
	if kind == SlotHouse.PROP_KIND and payload.has(&"stops"):
		play(peer_id, payload)


func is_playing() -> bool:
	return is_processing()


## Start a spin from a result payload (tier, bet, stops, win, payout, chaos). A spin still running is finished at once.
func play(peer_id: int, payload: Dictionary) -> void:
	if is_processing():
		_finish()
	var stops: PackedInt32Array = payload[&"stops"]
	_peer = peer_id
	_result = payload
	_t = 0.0
	_landed = false
	_total = SlotMath.spin_sec(stops) + 2.6
	_plans.clear()
	for i in SlotMath.REELS:
		_plans.append(_plan_reel(i, stops))
	_led.text = "GOOD LUCK"
	_pop.visible = false
	_mat.set_shader_parameter(&"chase_speed", 2.5)
	_mat.set_shader_parameter(&"flash", 0.0)
	_pull_lever()
	set_process(true)


## The closed-form run of one drum: constant speed (nudged so the brake starts a whole number of turns short of the stop),
## a cubic brake, a small kick. Same stops on every peer, same animation.
func _plan_reel(i: int, stops: PackedInt32Array) -> Run:
	var r := Run.new()
	r.t_stop = SlotMath.reel_stop_at(i, stops)
	r.t_brake = r.t_stop - EASE_SEC
	r.run = SPIN_RADPS * EASE_SEC / 3.0
	r.from = _angle[i]
	var target := float(stops[i]) * TAU / SlotCabinet.FACES
	var gap := fposmod(target - r.run - r.from, TAU)
	var turns := maxi(roundi((SPIN_RADPS * r.t_brake - gap) / TAU), 0)
	r.v = (gap + turns * TAU) / r.t_brake
	r.final = r.from + gap + turns * TAU + r.run
	return r


func _angle_at(r: Run, t: float) -> float:
	if t <= r.t_brake:
		return r.from + r.v * t
	if t < r.t_stop:
		var u := (t - r.t_brake) / EASE_SEC
		return r.from + r.v * r.t_brake + r.run * (1.0 - pow(1.0 - u, 3.0))
	var s := t - r.t_stop
	return r.final + 0.05 * exp(-12.0 * s) * sin(28.0 * s)


func _process(delta: float) -> void:
	_t += delta
	for i in SlotMath.REELS:
		var plan := _plans[i]
		_drums[i].rotation.x = _angle_at(plan, _t)
		var blur := 1.0 if _t < plan.t_brake else clampf(1.0 - (_t - plan.t_brake) / EASE_SEC, 0.0, 1.0)
		_drums[i].set_instance_shader_parameter(&"blur", blur)
	if not _landed and _t >= SlotMath.reveal_sec(_result[&"stops"]):
		_land()
	if _shake > 0.0:
		_shake = maxf(_shake - delta, 0.0)
		var k := 0.012 * _shake
		position = _home + Vector3(randf_range(-k, k), 0.0, randf_range(-k, k))
	if _t >= _total:
		_finish()


## Snap everything to the resting state: drums on their stops, lights idle, no shake.
func _finish() -> void:
	if not _plans.is_empty():
		for i in SlotMath.REELS:
			_angle[i] = _plans[i].final
			_drums[i].rotation.x = _angle[i]
			_drums[i].set_instance_shader_parameter(&"blur", 0.0)
		_angle = PackedFloat32Array([fposmod(_angle[0], TAU), fposmod(_angle[1], TAU), fposmod(_angle[2], TAU)])
		_plans.clear()
	if not _landed and not _result.is_empty():
		_land()
	position = _home
	_shake = 0.0
	_mat.set_shader_parameter(&"chase_speed", 0.6)
	_mat.set_shader_parameter(&"flash", 0.0)
	_led.text = IDLE_TEXT
	_pop.visible = false
	set_process(false)


func _land() -> void:
	_landed = true
	var win: StringName = _result[&"win"]
	var payout := int(_result[&"payout"])
	var info: Dictionary = SlotMath.WINS[win]
	var mult := int(info.mult)
	_led.text = "%s\n+$%d" % [info.title, payout] if payout > 0 else String(info.title)
	_mat.set_shader_parameter(&"chase_speed", 1.2)
	var chaotic := win == &"zap" or win == &"cursed"
	if win == &"jackpot" or win == &"sevens":
		_celebrate(1.0, Color("FFC93A"), 0.6, "JACKPOT!" if win == &"jackpot" else "TRIPLE 7!", 1.0)
	elif chaotic:
		_celebrate(1.0, Color("3DE0FF"), 0.45, "ZAP!", 0.8)
	elif mult >= BIG_MULT:
		_celebrate(1.0, Color("FFC93A"), 0.0, "+$%d" % payout, 0.75)
	elif payout > 0:
		_celebrate(0.0, Color("FFE58A"), 0.0, "+$%d" % payout, 0.5)
	if payout > int(_result[&"bet"]):  # more than the stake back: coins (a refund is not a win)
		_coins.amount = 70 if win == &"jackpot" else (36 if mult >= BIG_MULT else 18)
		_coins.restart()
		_coins.emitting = true
	landed.emit(_peer, _result)


## `strobe` 1 = bulbs flash; `shake` seconds of cabinet shake; a floating readout of `size` (1 = jackpot).
func _celebrate(strobe: float, color: Color, shake: float, text: String, size: float) -> void:
	_mat.set_shader_parameter(&"flash", strobe)
	_mat.set_shader_parameter(&"flash_tint", Vector3(color.r, color.g, color.b))
	_shake = shake
	_pop.text = text
	_pop.modulate = color
	_pop.visible = true
	_pop.position = SlotCabinet.POP_AT
	_pop.scale = Vector3.ONE * 0.4
	if _tween_pop != null:
		_tween_pop.kill()
	_tween_pop = create_tween()
	_tween_pop.set_parallel(true)
	_tween_pop.tween_property(_pop, "scale", Vector3.ONE * (0.7 + 0.7 * size), 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween_pop.tween_property(_pop, "position:y", SlotCabinet.POP_AT.y + 0.3, 2.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween_pop.tween_property(_pop, "modulate:a", 0.0, 0.6).set_delay(1.6)
	if strobe > 0.0:  # the strobe runs a while, then the bulbs settle
		get_tree().create_timer(1.2 + size * 1.6).timeout.connect(func() -> void:
			if _landed:
				_mat.set_shader_parameter(&"flash", 0.0))


func _pull_lever() -> void:
	if _tween_lever != null:
		_tween_lever.kill()
	_tween_lever = create_tween()
	_tween_lever.tween_property(_lever, "rotation:x", 1.45, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween_lever.tween_property(_lever, "rotation:x", 0.0, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
