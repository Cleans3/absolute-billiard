class_name RackDropper
extends RefCounted

## Seeded Bridson Poisson-disk drop (01 §3), kept as a formation round the foot spot, and the clear-spot search RoundDirector reuses for
## respawns. Positions are table-local Vector2(x, z); nothing here knows a metre, only ball radii.

const TYPE_DIR := "res://src/resources/ball_types/"
const SPACING_RADII := 2.2       # Bridson minimum spacing r, in ball radii (2.4 before the formation rack: a looser pack passes less of the break on)
const POCKET_KEEPOUT_RADII := 0.35  # clear ring past a pocket hole + ball radius, in ball radii
const CANDIDATES := 30           # Bridson k
const SHRINK := 0.95             # spacing multiplier when a sample comes up short
const MAX_PRIZES := 2            # 01 §2: "one or two per Round"
const MAX_OBJECT_BALLS := 12     # 07 §1 phone budget; obstacles (stone_ball) count toward it (06 P8)
const STONES_PER_RACK := 1       # [tune] when `stone_ball` is in the pool
const CENTRE_TIE_M := 1e-4       # slots this close in distance to the centroid tie (06 P31)


static func ball_type(id: StringName) -> BallType:
	return load(TYPE_DIR + String(id) + ".tres")


## Object-ball placements for a Round: [{type: BallType, pos: Vector2}], `count` of them, none
## on the head spot (the cue ball's) or in a pocket mouth. Same config + seed → same rack.
static func drop(spec: TableSpec, layout: TableLayout, config: NightConfig, seed: int, round_index := 0) -> Array[Dictionary]:
	if round_index >= 1 and round_index <= config.authored_racks.size() and config.authored_racks[round_index - 1] != null:
		return authored(spec, config.authored_racks[round_index - 1])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var head := Vector2(layout.spots.head.x, layout.spots.head.z)
	var n := rack_size(config)
	var r := SPACING_RADII * spec.ball_radius_m
	var floor_r := 2.0 * spec.ball_radius_m + spec.clearance_margin_m
	var points := poisson(interior(spec), r, rng, [head], keepouts(spec, layout))
	while points.size() < n and r > floor_r:
		r = maxf(r * SHRINK, floor_r)
		points = poisson(interior(spec), r, rng, [head], keepouts(spec, layout))
	assert(points.size() >= n, "table too small for %d balls" % n)
	# The rack is a formation: the n samples nearest the foot spot, most open spots first. The table-wide scatter this replaced left
	# the cue ball one or two balls to hit (adhoc-1013c U12: a full-power break moved 12-20 % of the balls, a formation 85-95 %).
	var foot := Vector2(layout.spots.foot.x, layout.spots.foot.z)
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.distance_squared_to(foot) < b.distance_squared_to(foot))
	points.resize(n)

	# 06 P31: the black ball opens the Round in the middle of the formation; the rest are dealt by openness as before.
	var types := compose(config, n, rng)
	var black := _black_index(types)
	var out: Array[Dictionary] = []
	if black >= 0:
		var mid := centre_slot(points, Vector2(layout.spots.foot.x, layout.spots.foot.z))
		out.append({type = types[black], pos = points[mid]})
		types.remove_at(black)
		points.remove_at(mid)
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return _openness(spec, layout, a) > _openness(spec, layout, b))
	for i in points.size():
		out.append({type = types[i], pos = points[i]})
	return out


## The first penalty ("black") ball of `types`, or -1.
static func _black_index(types: Array[BallType]) -> int:
	for i in types.size():
		if types[i].behaviour_tags.has(&"penalty"):
			return i
	return -1


## The slot nearest the formation's centroid (06 P31); a tie goes to the slot nearer `foot`, then the lower index.
static func centre_slot(points: Array[Vector2], foot: Vector2) -> int:
	var centroid := Vector2.ZERO
	for p in points:
		centroid += p
	centroid /= float(points.size())
	var best := 0
	for i in range(1, points.size()):
		var d := points[i].distance_to(centroid)
		var bd := points[best].distance_to(centroid)
		if d < bd - CENTRE_TIE_M or (absf(d - bd) <= CENTRE_TIE_M and points[i].distance_to(foot) < points[best].distance_to(foot) - CENTRE_TIE_M):
			best = i
	return best


## Object balls in a Round: the Night's count plus any obstacles in the pool, capped at 12 (06 P8).
static func rack_size(config: NightConfig) -> int:
	return mini(config.object_ball_count + _obstacle_slots(config), MAX_OBJECT_BALLS)


static func _obstacle_slots(config: NightConfig) -> int:
	for id in config.unlocked_ball_types:
		var t := ball_type(id)
		if t != null and t.behaviour_tags.has(&"obstacle"):
			return STONES_PER_RACK
	return 0


## Types a shuffle may re-roll a ball into: prizes, penalties and positive commons of the pool
## (never obstacles or gimmicks, which are placed once by design).
static func reroll_pool(config: NightConfig) -> Array[BallType]:
	var out: Array[BallType] = []
	for id in config.unlocked_ball_types:
		var t := ball_type(id)
		if t != null and not t.behaviour_tags.has(&"obstacle") and not t.behaviour_tags.has(&"gimmick"):
			out.append(t)
	return out


## A hand-authored rack as placements; `positions` are fractions of the interior half-extents.
static func authored(spec: TableSpec, rack: RackLayout) -> Array[Dictionary]:
	var half := interior(spec).size * 0.5
	var out: Array[Dictionary] = []
	for i in rack.type_ids.size():
		out.append({type = ball_type(rack.type_ids[i]), pos = Vector2(rack.positions[i].x * half.x, rack.positions[i].y * half.y)})
	return out


## `n` ball types, highest value first: obstacles (`obstacle`, worth 0), 1-2 prize (`high_value`),
## one penalty, each unlocked gimmick once, the rest the positive commons weighted by 1 / value
## (cheap balls are common). Missing tiers are skipped.
static func compose(config: NightConfig, n: int, rng: RandomNumberGenerator) -> Array[BallType]:
	var prizes: Array[BallType] = []
	var penalties: Array[BallType] = []
	var gimmicks: Array[BallType] = []
	var obstacles: Array[BallType] = []
	var commons: Array[BallType] = []
	for id in config.unlocked_ball_types:
		var t := ball_type(id)
		if t == null:
			push_error("RackDropper: no BallType '%s' under %s" % [id, TYPE_DIR])
		elif t.behaviour_tags.has(&"obstacle"):
			obstacles.append(t)
		elif t.behaviour_tags.has(&"high_value"):
			prizes.append(t)
		elif t.behaviour_tags.has(&"penalty"):
			penalties.append(t)
		elif t.behaviour_tags.has(&"gimmick"):
			gimmicks.append(t)
		elif t.base_value > 0:
			commons.append(t)
	var out: Array[BallType] = []
	var stones := mini(_obstacle_slots(config), n)
	var slots := n - stones
	if not prizes.is_empty():
		for i in mini(rng.randi_range(1, MAX_PRIZES), slots):
			out.append(prizes[rng.randi() % prizes.size()])
	if not penalties.is_empty() and out.size() < slots:
		out.append(penalties[rng.randi() % penalties.size()])
	for g in gimmicks:
		if out.size() < slots:
			out.append(g)
	var total := 0.0
	for t in commons:
		total += 1.0 / t.base_value
	while out.size() < slots and not commons.is_empty():
		var roll := rng.randf() * total
		var pick := commons[commons.size() - 1]
		for t in commons:
			roll -= 1.0 / t.base_value
			if roll <= 0.0:
				pick = t
				break
		out.append(pick)
	out.sort_custom(func(a: BallType, b: BallType) -> bool: return a.base_value > b.base_value)
	for i in stones:
		out.append(obstacles[0])
	return out


## Closest clear spot to `near` inside `region`: `near` itself if `others` all sit ≥ the ball
## spacing away, else the nearest Bridson sample that does. Seeded, so respawns replay.
static func place_near(spec: TableSpec, layout: TableLayout, near: Vector2, region: Rect2, others: Array[Vector2], seed: int) -> Vector2:
	var r := SPACING_RADII * spec.ball_radius_m
	var blocked := keepouts(spec, layout)
	if region.has_point(near) and _clear(near, others, r) and _clear_of_keepouts(near, blocked):
		return near
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var best := near
	var best_d := INF
	for p in poisson(region, r, rng, others, blocked):
		if p.distance_squared_to(near) < best_d:
			best_d = p.distance_squared_to(near)
			best = p
	assert(best_d < INF, "no clear spot in region")
	return best


## Where a ball centre may sit: the playfield inset by ball radius + clearance.
static func interior(spec: TableSpec) -> Rect2:
	var m := spec.ball_radius_m + spec.clearance_margin_m
	var half := Vector2(spec.length_m, spec.width_m) * 0.5 - Vector2(m, m)
	return Rect2(-half, half * 2.0)


## Head-side quarter of `interior`, wholly behind kitchen_line_x (x + radius < line).
static func kitchen(spec: TableSpec) -> Rect2:
	var r := interior(spec)
	r.end.x = spec.kitchen_line_x - spec.ball_radius_m - spec.clearance_margin_m
	return r


## Pocket holes as Vector3(x, z, radius) — a ball centre must stay outside every one (a ball on a hole falls in).
static func keepouts(spec: TableSpec, layout: TableLayout) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var reach := spec.ball_radius_m * (1.0 + POCKET_KEEPOUT_RADII)
	for p in layout.pockets:
		var hole: TableLayout.Hole = layout.holes[p.id]
		out.append(Vector3(p.position.x, p.position.z, hole.cup_radius + (hole.cup_radius - hole.radius) + reach))
	return out


## Bridson over `bounds`. `fixed` points (other balls) are never returned but every sample
## keeps ≥ r from them; `blocked` discs are Vector3(x, z, radius).
static func poisson(bounds: Rect2, r: float, rng: RandomNumberGenerator, fixed: Array[Vector2], blocked: Array[Vector3]) -> Array[Vector2]:
	var cell := r / sqrt(2.0)
	var grid := {}  # Vector2i -> Array[Vector2]; cells hold several `fixed` points at most
	for f in fixed:
		_grid_add(grid, f, bounds, cell)
	var out: Array[Vector2] = []
	var active: Array[Vector2] = []
	# start from any admissible random point (a handful of tries covers all realistic tables)
	for _i in CANDIDATES:
		var p := Vector2(rng.randf_range(bounds.position.x, bounds.end.x), rng.randf_range(bounds.position.y, bounds.end.y))
		if _admissible(p, grid, bounds, cell, r, blocked):
			out.append(p)
			active.append(p)
			_grid_add(grid, p, bounds, cell)
			break
	while not active.is_empty():
		var idx := rng.randi_range(0, active.size() - 1)
		var origin := active[idx]
		var found := false
		for _k in CANDIDATES:
			var ang := rng.randf() * TAU
			var dist := r * (1.0 + rng.randf())  # annulus [r, 2r]
			var p := origin + Vector2.from_angle(ang) * dist
			if _admissible(p, grid, bounds, cell, r, blocked):
				out.append(p)
				active.append(p)
				_grid_add(grid, p, bounds, cell)
				found = true
				break
		if not found:
			active.remove_at(idx)
	return out


static func _grid_add(grid: Dictionary, p: Vector2, bounds: Rect2, cell: float) -> void:
	var key := Vector2i(((p - bounds.position) / cell).floor())
	if not grid.has(key):
		grid[key] = [] as Array[Vector2]
	grid[key].append(p)


static func _admissible(p: Vector2, grid: Dictionary, bounds: Rect2, cell: float, r: float, blocked: Array[Vector3]) -> bool:
	if not bounds.has_point(p) or not _clear_of_keepouts(p, blocked):
		return false
	var key := Vector2i(((p - bounds.position) / cell).floor())
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var pts: Array = grid.get(key + Vector2i(dx, dz), [])
			for q in pts:
				if p.distance_squared_to(q) < r * r:
					return false
	return true


static func _clear(p: Vector2, others: Array[Vector2], r: float) -> bool:
	for q in others:
		if p.distance_squared_to(q) < r * r:
			return false
	return true


static func _clear_of_keepouts(p: Vector2, blocked: Array[Vector3]) -> bool:
	for b in blocked:
		if p.distance_squared_to(Vector2(b.x, b.y)) < b.z * b.z:
			return false
	return true


## Distance to the nearest cushion line or pocket centre: how uncontroversial a spot is to hit.
static func _openness(spec: TableSpec, layout: TableLayout, p: Vector2) -> float:
	var d := minf(spec.length_m * 0.5 - absf(p.x), spec.width_m * 0.5 - absf(p.y))
	for pk in layout.pockets:
		d = minf(d, p.distance_to(Vector2(pk.position.x, pk.position.z)))
	return d
