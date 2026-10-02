class_name Bar
extends Node3D
## Places the Interactable props (docs/plan/03 §3.7). Greybox positions [tune]; PERF owns the visuals.
## `lean_on_rail` target_id = 1 + index in Stats.RAILS.

const REACH_ZONE_RADIUS := 1.2
# [interaction id or bar kind, position, target_id, prompt]
const PROPS: Array = [
	[&"bump_table", Vector3(0.0, 0.0, -1.2), 0, "Bump the table"],
	[&"kick_stool", Vector3(0.0, 0.0, 0.0), 0, "Kick the stool"],
	[&"jukebox", Vector3(6.3, 0.0, 5.8), 0, "Jukebox"],
	[&"flick_lights", Vector3(-6.3, 0.0, 5.8), 0, "Flick the lights"],
	[&"lean_on_rail", Vector3(-3.44, 0.0, -3.5), 1, "Lean on the rail"],  # rail_w
	[&"lean_on_rail", Vector3(3.44, 0.0, -3.5), 2, "Lean on the rail"],  # rail_e
	[&"lean_on_rail", Vector3(-1.3, 0.0, -5.67), 3, "Lean on the rail"],  # rail_n_w
	[&"lean_on_rail", Vector3(1.3, 0.0, -5.67), 4, "Lean on the rail"],  # rail_n_e
	[&"lean_on_rail", Vector3(-1.3, 0.0, -1.33), 5, "Lean on the rail"],  # rail_s_w
	[&"lean_on_rail", Vector3(1.3, 0.0, -1.33), 6, "Lean on the rail"],  # rail_s_e
	[&"heckle", Vector3(-5.0, 0.0, 3.5), 0, "Heckle"],
	[&"chalk_the_cue", Vector3(2.4, 0.0, -1.2), 0, "Chalk the cue"],
	# the counter props: customer side of the counter (x 4.7-5.5), the bartender stands behind it at (6.0, 0, 2.5)
	[&"throw_drink", Vector3(4.2, 0.0, 2.5), 0, "Throw a drink"],
	[&"bar_buy", Vector3(4.2, 0.0, 2.5), 0, "Buy a drink"],
	[&"bar_serve", Vector3(4.2, 0.0, 2.5), 0, "Serve a drink"],
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
