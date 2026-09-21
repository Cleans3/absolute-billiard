class_name RackDropper
extends RefCounted

## Seeded Bridson Poisson-disk drop (01 §3) and the clear-spot search RoundDirector reuses for
## respawns. Positions are table-local Vector2(x, z); nothing here knows a metre, only ball radii.

const TYPE_DIR := "res://src/resources/ball_types/"
const SPACING_RADII := 2.4       # Bridson minimum spacing r, in ball radii
const POCKET_KEEPOUT_RADII := 0.35  # clear ring past a pocket mouth + ball radius, in ball radii
const CANDIDATES := 30           # Bridson k
const SHRINK := 0.95             # spacing multiplier when a sample comes up short
const MAX_PRIZES := 2            # 01 §2: "one or two per Round"


static func ball_type(id: StringName) -> BallType:
	return load(TYPE_DIR + String(id) + ".tres")


## Object-ball placements for a Round: [{type: BallType, pos: Vector2}], `count` of them, none
## on the head spot (the cue ball's) or in a pocket mouth. Same config + seed → same rack.
static func drop(spec: TableSpec, layout: TableLayout, config: NightConfig, seed: int) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var head := Vector2(layout.spots.head.x, layout.spots.head.z)
	var n := config.object_ball_count
	var r := SPACING_RADII * spec.ball_radius_m
	var floor_r := 2.0 * spec.ball_radius_m + spec.clearance_margin_m
	var points := poisson(interior(spec), r, rng, [head], keepouts(spec, layout))
	while points.size() < n and r > floor_r:
		r = maxf(r * SHRINK, floor_r)
		points = poisson(interior(spec), r, rng, [head], keepouts(spec, layout))
	assert(points.size() >= n, "table too small for %d balls" % n)
	# seeded Fisher-Yates (Array.shuffle uses the global RNG), keep n, most open spots first
	for i in range(points.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := points[i]
		points[i] = points[j]
		points[j] = t
	points.resize(n)
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return _openness(spec, layout, a) > _openness(spec, layout, b))

	var types := compose(config, n, rng)
	var out: Array[Dictionary] = []
	for i in n:
		out.append({type = types[i], pos = points[i]})
	return out


## `n` ball types, highest value first: 1-2 prize (`high_value`), one penalty, the rest the
## positive commons weighted by 1 / value (cheap balls are common). Missing tiers are skipped.
static func compose(config: NightConfig, n: int, rng: RandomNumberGenerator) -> Array[BallType]:
	var prizes: Array[BallType] = []
	var penalties: Array[BallType] = []
	var commons: Array[BallType] = []
	for id in config.unlocked_ball_types:
		var t := ball_type(id)
		if t == null:
			push_error("RackDropper: no BallType '%s' under %s" % [id, TYPE_DIR])
		elif t.behaviour_tags.has(&"high_value"):
			prizes.append(t)
		elif t.behaviour_tags.has(&"penalty"):
			penalties.append(t)
		elif t.base_value > 0:
			commons.append(t)
	var out: Array[BallType] = []
	if not prizes.is_empty():
		for i in mini(rng.randi_range(1, MAX_PRIZES), n):
			out.append(prizes[rng.randi() % prizes.size()])
	if not penalties.is_empty() and out.size() < n:
		out.append(penalties[rng.randi() % penalties.size()])
	var total := 0.0
	for t in commons:
		total += 1.0 / t.base_value
	while out.size() < n and not commons.is_empty():
		var roll := rng.randf() * total
		var pick := commons[commons.size() - 1]
		for t in commons:
			roll -= 1.0 / t.base_value
			if roll <= 0.0:
				pick = t
				break
		out.append(pick)
	out.sort_custom(func(a: BallType, b: BallType) -> bool: return a.base_value > b.base_value)
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


## Pocket mouths as Vector3(x, z, radius) — a ball centre must stay outside every one.
static func keepouts(spec: TableSpec, layout: TableLayout) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var reach := spec.ball_radius_m * (1.0 + POCKET_KEEPOUT_RADII)
	for p in layout.pockets:
		out.append(Vector3(p.position.x, p.position.z, p.mouth_width_m * 0.5 + reach))
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
