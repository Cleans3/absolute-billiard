class_name DebugRackPresets
extends RefCounted

## Rack presets (T2.7): break, straight-in, cut, stun — cycled by debug_rack_next (F7).
## Entries are table-local metres derived from the live TableSpec (no hand-scaled
## literals), shaped per contract §DemoRack: {type: StringName, x: float, z: float}.

const ORDER := ["break", "straight_in", "cut", "stun"]

var _index := 0


func next(spec: TableSpec) -> Array[Dictionary]:
	var preset_name: String = ORDER[_index]
	_index = (_index + 1) % ORDER.size()
	return build(preset_name, spec)


func build(preset_name: String, spec: TableSpec) -> Array[Dictionary]:
	match preset_name:
		"straight_in":
			return _straight_in(spec)
		"cut":
			return _cut(spec)
		"stun":
			return _stun(spec)
		_:
			return _break(spec)


func _break(spec: TableSpec) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var gap := spec.ball_radius_m * 2.0 + 0.001
	var foot_x := spec.length_m * 0.25
	var order := ["red", "blue", "red", "red", "gold", "blue", "red", "black", "red", "blue"]
	var i := 0
	for row in range(4):
		for k in range(row + 1):
			if i >= order.size():
				break
			entries.append({
				type = StringName(order[i]),
				x = foot_x + row * gap * 0.866,
				z = (k - row * 0.5) * gap,
			})
			i += 1
	entries.append({type = &"cue", x = -spec.length_m * 0.25, z = 0.0})
	return entries


func _straight_in(spec: TableSpec) -> Array[Dictionary]:
	var hl := spec.length_m * 0.5
	var edge_z := spec.width_m * 0.5 - spec.ball_radius_m * 4.0
	var pocket_x := hl - spec.ball_radius_m * 4.0
	return [
		{type = &"red", x = pocket_x, z = edge_z},
		{type = &"cue", x = pocket_x - spec.length_m * 0.25, z = edge_z},
	]


func _cut(spec: TableSpec) -> Array[Dictionary]:
	var hl := spec.length_m * 0.5
	return [
		{type = &"red", x = hl * 0.35, z = spec.width_m * 0.2},
		{type = &"cue", x = 0.0, z = -spec.width_m * 0.3},
	]


func _stun(spec: TableSpec) -> Array[Dictionary]:
	return [
		{type = &"red", x = spec.length_m * 0.15, z = 0.0},
		{type = &"cue", x = -spec.length_m * 0.15, z = 0.0},
	]
