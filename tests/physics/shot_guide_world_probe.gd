extends SceneTree

## The shot guide is on the table (adhoc-1014a V7, 01 §3 "Shot guide"): a real CueController hangs under a translated, rotated, tilted
## `Head` (the guide is built in world coordinates and is `top_level`, which keeps the transform it had when it entered the tree), aims
## 10 random shots, and every vertex of the ribbon must sit on the cloth of the world table, the ghost ring where the HOST's cue ball
## first touches the object ball (within 15 mm: the flat stroke's 12 mm of shot_guide_probe plus the throw in the probe's own estimate). Also: hidden outside aiming, on the
## layer the shooter's camera draws and the mirror / TV cameras do not.
##   godot --path . --headless -s tests/physics/shot_guide_world_probe.gd        prints GUIDE WORLD OK

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_CTRL := preload("res://src/gameplay/cue/CueController.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const SHOTS := 10
const HIT_TOL_M := 0.015
const SLACK_M := 0.03  # the ribbon's half width + the ring's, plus a margin

## Where the host's cue ball first touched the object ball: the object ball leaves along the line of centres (ball-ball friction is 0.06),
## so the touch is one reach behind its start, opposite the way it first moved. Independent of how coarse the physics frames are.
class Rec extends Node:
	var cue: Ball
	var obj: Ball
	var on := false
	var start := Vector3.ZERO
	var hit := Vector3.ZERO
	var got := false

	func arm() -> void:
		on = true
		got = false
		start = obj.global_position

	func _physics_process(_delta: float) -> void:
		if not on or got:
			return
		var moved := obj.global_position - start
		if moved.length() > 0.04:
			hit = start - moved.normalized() * (cue.radius + obj.radius)
			got = true


var table: Table
var rec := Rec.new()
var head := Node3D.new()
var ctrl: CueController
var _fail := 0
var _worst_hit := 0.0
var _worst_y := 0.0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	root.add_child(rec)
	# the Head of a player seated at slot 3: a seat to the side, 1.6 m up, turned and tilted
	head.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(11.0), deg_to_rad(37.0), deg_to_rad(5.0))), Vector3(-1.5 + 2.0, 1.6, 1.2 - 0.12))
	root.add_child(head)
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("GUIDE WORLD: " + msg)


func _run() -> void:
	await physics_frame
	ctrl = CUE_CTRL.instantiate()
	head.add_child(ctrl)  # guide is built in CueController._ready, under the moved parent, like the Player's
	ctrl.table = table
	var guide := ctrl.guide
	var y := table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	var cue := _ball(CUE_T, Vector3(-1.5, y, 0.1))
	var obj := _ball(RED_T, Vector3(0.0, y, 0.0))
	rec.cue = cue
	rec.obj = obj
	_check(not guide.visible, "the guide starts hidden")
	_check(guide.layers == ShotGuide.LAYER, "the guide is on render layer 12 only")
	_check(Camera3D.new().cull_mask & ShotGuide.LAYER != 0, "the shooter's camera (all layers but HEAD) draws layer 12")
	_check(((Mirror.LAYER | Humanoid.HEAD_LAYER) | Mirror.ROOM_LAYER | StreamTv.feed_mask(0) | StreamTv.feed_mask(1)) & ShotGuide.LAYER == 0, "the mirror's and the TV feeds' cameras do not draw layer 12")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1014
	var r := table.spec.ball_radius_m
	for i in SHOTS:
		var start := Vector3(rng.randf_range(-1.9, -1.0), y, rng.randf_range(-0.5, 0.5))
		var gap := rng.randf_range(0.7, 1.5)
		var cut := rng.randf_range(-0.8, 0.8) * r  # object ball offset across the line, under a ball radius: always a hit
		var dir := Vector2(1.0, rng.randf_range(-0.25, 0.25)).normalized()
		cue.restore(start)
		obj.restore(start + Vector3(dir.x, 0.0, dir.y) * gap + Vector3(-dir.y, 0.0, dir.x) * cut)
		for k in 60:
			await physics_frame
		while table.sim.awake > 0:
			await physics_frame
		var power := rng.randf_range(0.35, 0.65)
		ctrl.begin(cue, atan2(-dir.x, -dir.y))
		ctrl.power = power
		ctrl.set_spin(Vector2(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.4, 0.4)))
		for k in 3:
			await process_frame
		await _case(i, guide, cue, obj, power, start)
	ctrl.end()
	_check(not guide.visible, "the guide hides when aiming ends")
	if _fail > 0:
		printerr("GUIDE WORLD FAILED: %d" % _fail)
		quit(1)
		return
	print("guide world: %d shots under a moved parent, ghost ring %.1f mm off the host's first touch at worst, ribbon %.1f mm off the cloth at worst" % [SHOTS, _worst_hit * 1000.0, _worst_y * 1000.0])
	print("GUIDE WORLD OK")
	quit()


func _case(i: int, guide: ShotGuide, cue: Ball, obj: Ball, power: float, start: Vector3) -> void:
	var label := "shot %d" % i
	var model := guide.model
	_check(guide.visible, "%s: the guide shows while aiming" % label)
	_check(guide.global_transform.is_equal_approx(Transform3D.IDENTITY), "%s: the guide is at the world origin, not under the Head (%s)" % [label, guide.global_position])
	_check(model.hit == ShotModel.Hit.BALL, "%s: the guide expects to hit the object ball" % label)
	var verts: PackedVector3Array = (guide.mesh as ImmediateMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(verts.size() > 12, "%s: the guide drew %d vertices" % [label, verts.size()])
	var cloth := table.global_position.y + table.spec.bed_height_m
	var lo := INF
	var hi := -INF
	var near_start := INF
	var ring_near := INF
	var hx := table.spec.length_m * 0.5 + table.spec.rail_width_m
	var hz := table.spec.width_m * 0.5 + table.spec.rail_width_m
	var host_hit := Vector3.ZERO
	var ghost := model.hit_pos  # before the strike: the guide keeps tracing the ball once it moves
	rec.arm()
	var intent := ctrl.build_intent(power)
	cue.strike(intent, ctrl.cue_spec)
	var t := 0.0
	while t < 2.5 and not rec.got:
		await physics_frame
		t += 1.0 / 120.0
	host_hit = rec.hit
	_check(rec.got, "%s: the object ball was struck" % label)
	var r := cue.radius
	for v in verts:
		var w := guide.global_transform * v
		lo = minf(lo, w.y)
		hi = maxf(hi, w.y)
		_check(absf(w.x - table.global_position.x) <= hx and absf(w.z - table.global_position.z) <= hz, "%s: a vertex %s is off the table" % [label, w])
		near_start = minf(near_start, Vector2(w.x - start.x, w.z - start.z).length())
		if rec.got:
			ring_near = minf(ring_near, absf(Vector2(w.x - host_hit.x, w.z - host_hit.z).length() - r))
	_worst_y = maxf(_worst_y, maxf(absf(lo - (cloth + ShotGuide.LIFT_M)), absf(hi - (cloth + ShotGuide.LIFT_M))))
	_check(lo >= cloth and hi <= cloth + 0.02, "%s: the ribbon floats %.0f..%.0f mm over the cloth (a flat shot is within 20 mm)" % [label, (lo - cloth) * 1000.0, (hi - cloth) * 1000.0])
	_check(near_start <= SLACK_M, "%s: the ribbon starts %.0f mm from the cue ball" % [label, near_start * 1000.0])
	if rec.got:
		var err := Vector2(ghost.x - host_hit.x, ghost.z - host_hit.z).length()
		_worst_hit = maxf(_worst_hit, err)
		_check(err <= HIT_TOL_M, "%s: the guide's ghost ball is %.1f mm from where the host's cue ball first touches" % [label, err * 1000.0])
		_check(ring_near <= 0.012, "%s: no ring vertex within 12 mm of a ball radius about the host's first touch (nearest %.1f mm)" % [label, ring_near * 1000.0])
	rec.on = false
	ctrl.end()
	_check(not guide.visible, "%s: the shot is away, the guide is hidden" % label)
	while table.sim.awake > 0:
		await physics_frame


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	return b

