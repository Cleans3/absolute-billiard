class_name RoundStaging
extends Node3D
## MainLevel/Staging: plays a Round's set-up (06 P33 U16) and clean-up (U15) on every peer. RoundDirector owns the rules (the `staging` flag, who
## may strike); this node only draws, from `StagingPlan`'s pure schedule and the clock it has been running since its own start. Nothing in either
## sequence has a collision object (the vent, the saucer, its beam, the table's pit and flaps), so nothing can snag a player or a ball.
##
## Set-up: the Vent's louvres part, the saucer (Ufo) comes out of the mouth and hovers over the table, the louvres shut behind it, the saucer's beam
## walks along the rack in net_id order and each ball materialises where it stands (Materialise: a glow shell over any ball material, gimmicks
## and the cue ball alike), then the saucer dematerialises. The balls exist on the host from the start (spawned frozen by RoundDirector, hidden here
## until their turn), so the host's physics never waits on the picture. Clean-up: `TablePit`.

signal finished(kind: StringName)

const KIND_SETUP := &"setup"
const KIND_CLEANUP := &"cleanup"
const HOVER_ABOVE_BED := 1.45  ## saucer height over the cloth: under the lamp's shade (2.95), over a standing player's eye
const SWAY := 0.5              ## how far toward the beamed ball the saucer drifts from the table's centre (fraction of the distance)
const START_UP := 0.25         ## the saucer waits this far under the ceiling slab, inside the housing

@export var table: Table
@export var vent: Vent

## `KIND_SETUP`, `KIND_CLEANUP` or &"" (idle).
var kind := &""
var elapsed := 0.0
var _balls: Array[Ball] = []
var _last_p := PackedFloat64Array()  # 64-bit: a float32 would round 0.9999999999 to 1.0 and the `==` below would skip the ball's last update
var _ufo: Ufo
var _pit: TablePit


func _ready() -> void:
	set_process(false)


func is_playing() -> bool:
	return kind != &""


## How long the sequence now playing (or about to play, for `n` balls) takes.
func duration() -> float:
	return StagingPlan.CLEANUP_SEC if kind == KIND_CLEANUP else StagingPlan.setup_duration(_balls.size())


## The set-up of `balls` (hidden by this call, revealed by the beam). `autoplay` false leaves the clock to `seek` (probes, screenshots).
func play_setup(balls: Array[Ball], autoplay := true) -> void:
	finish()
	kind = KIND_SETUP
	elapsed = 0.0
	_balls = balls.duplicate()
	_balls.sort_custom(func(a: Ball, b: Ball) -> bool: return a.net_id < b.net_id)
	_last_p.resize(_balls.size())
	_last_p.fill(-1.0)
	for b in _balls:
		b.visible = false
	if _ufo == null:
		_ufo = Ufo.new()
		_ufo.name = "Ufo"
		add_child(_ufo)
	_ufo.visible = false
	seek(0.0)
	set_process(autoplay)


## The clean-up of `balls`: their resting positions are read now, then the table opens under them.
func play_cleanup(balls: Array[Ball], autoplay := true) -> void:
	finish()
	kind = KIND_CLEANUP
	elapsed = 0.0
	_balls = balls.duplicate()
	if _pit == null:
		_pit = TablePit.new()
		_pit.name = "TablePit"
		add_child(_pit)
	_pit.begin(table, _balls)
	seek(0.0)
	set_process(autoplay)


## Draws the playing sequence at `t` seconds (no clock, no signal).
func seek(t: float) -> void:
	if kind == KIND_SETUP:
		_seek_setup(t)
	elif kind == KIND_CLEANUP:
		_pit.pose(t)


## Jumps to the end state and says `finished` (a no-op while idle). Used when the sequence ends, and when something else needs the table now.
func finish() -> void:
	if kind == &"":
		return
	var done := kind
	if done == KIND_SETUP:
		_seek_setup(StagingPlan.setup_duration(_balls.size()))
		for b in _balls:
			b.visible = true
			Materialise.set_progress(_mesh(b), 1.0)
		_ufo.visible = false
		_ufo.set_beam(Vector3.ZERO, 0.0)
		if vent != null:
			vent.set_openness(0.0)
	else:
		_pit.end()
	kind = &""
	set_process(false)
	_balls = []
	finished.emit(done)


func _process(delta: float) -> void:
	elapsed += delta
	if elapsed >= duration():
		finish()
	else:
		seek(elapsed)


# ---------------------------------------------------------------- set-up

func _seek_setup(t: float) -> void:
	var n := _balls.size()
	if n == 0:
		return
	if vent != null:
		vent.set_openness(StagingPlan.vent_openness(t))
	for i in n:
		var p := StagingPlan.ball_progress(i, n, t)
		if p == _last_p[i]:  # exact on purpose: a tolerance would leave a ball at 0.99999 with its glow on
			continue
		_last_p[i] = p
		_balls[i].visible = p > 0.0
		Materialise.set_progress(_mesh(_balls[i]), p)
	_ufo.visible = StagingPlan.ufo_visible(t, n)
	if not _ufo.visible:
		_ufo.set_beam(Vector3.ZERO, 0.0)
		return
	var focus := StagingPlan.beam_focus(t, n)
	var target := _target(focus)
	var strength := StagingPlan.beam_strength(t, n)
	_ufo.global_position = _ufo_position(t, focus)
	var grow := StagingPlan.louvre_ease((t - StagingPlan.UFO_OUT_FROM) / 0.6)
	var farewell := 1.0 - StagingPlan.ufo_solid(t, n)  # swells a little as it dissolves
	_ufo.scale = Vector3.ONE * (lerpf(0.5, 1.0, grow) + 0.15 * farewell)
	_ufo.set_solid(StagingPlan.ufo_solid(t, n))
	_ufo.set_beam(target, strength)


## Where the saucer's beam lands: ball `focus` (fractional: gliding to the next).
func _target(focus: float) -> Vector3:
	var n := _balls.size()
	var i := clampi(floori(focus), 0, n - 1)
	var j := mini(i + 1, n - 1)
	return _balls[i].global_position.lerp(_balls[j].global_position, focus - float(i))


## Out of the vent's mouth, straight down first, then curving to hover over the table, drifting after the beam.
func _ufo_position(t: float, focus: float) -> Vector3:
	var centre := table.global_position
	var hover_y := centre.y + table.cloth_y() + HOVER_ABOVE_BED
	var drift := Vector3(centre.x, hover_y, centre.z)
	var target := _target(focus)
	var hover := drift + Vector3(target.x - centre.x, 0.0, target.z - centre.z) * SWAY
	var start := vent.global_position + Vector3(0.0, -START_UP, 0.0) if vent != null else hover + Vector3(0.0, 1.0, 0.0)
	var bend := Vector3(start.x, hover_y + 0.4, start.z)
	var u := StagingPlan.ufo_flight(t)
	var out := start.lerp(bend, u).lerp(bend.lerp(hover, u), u)  # quadratic Bezier start -> bend -> hover
	if t > StagingPlan.last_in(_balls.size()):
		out.y += 0.25 * (1.0 - StagingPlan.ufo_solid(t, _balls.size()))
	return out


func _mesh(b: Ball) -> MeshInstance3D:
	return b.get_node(^"Mesh") as MeshInstance3D
