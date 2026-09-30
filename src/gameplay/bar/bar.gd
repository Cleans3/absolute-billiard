class_name Bar
extends Node3D
## Places the Interactable props (docs/plan/03 §3.7). Greybox positions [tune]; PERF owns the visuals.
## Rail ids 1–4 (W, E, N, S) are placeholders until SYNC pins PhysicsSim's rail id scheme.

const REACH_ZONE_RADIUS := 1.2
# [interaction id or bar kind, position, target_id, prompt]
const PROPS: Array = [
	[&"bump_table", Vector3(0.0, 0.0, -1.2), 0, "Bump the table"],
	[&"kick_stool", Vector3(0.0, 0.0, 0.0), 0, "Kick the stool"],
	[&"jukebox", Vector3(6.3, 0.0, 5.8), 0, "Jukebox"],
	[&"flick_lights", Vector3(-6.3, 0.0, 5.8), 0, "Flick the lights"],
	[&"lean_on_rail", Vector3(-3.1, 0.0, -3.5), 1, "Lean on the rail"],
	[&"lean_on_rail", Vector3(3.1, 0.0, -3.5), 2, "Lean on the rail"],
	[&"lean_on_rail", Vector3(0.0, 0.0, -5.0), 3, "Lean on the rail"],
	[&"lean_on_rail", Vector3(0.0, 0.0, -2.0), 4, "Lean on the rail"],
	[&"heckle", Vector3(-5.0, 0.0, 3.5), 0, "Heckle"],
	[&"chalk_the_cue", Vector3(2.4, 0.0, -1.2), 0, "Chalk the cue"],
	[&"throw_drink", Vector3(5.5, 0.0, 4.6), 0, "Throw a drink"],
	[&"bar_buy", Vector3(5.5, 0.0, 4.6), 0, "Buy a drink"],
	[&"bar_serve", Vector3(5.5, 0.0, 4.6), 0, "Serve a drink"],
]


func _ready() -> void:
	for spec: Array in PROPS:
		var prop := Interactable.new()
		prop.interaction = FxCatalog.interaction(spec[0])
		if prop.interaction == null:
			prop.kind = spec[0]
		prop.target_id = spec[2]
		prop.prompt = spec[3]
		prop.position = spec[1]
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = REACH_ZONE_RADIUS
		shape.shape = sphere
		prop.add_child(shape)
		add_child(prop)
