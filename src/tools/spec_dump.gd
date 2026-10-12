extends SceneTree

## One-shot: prints every TableSpec constant/export/getter with its default value as a markdown
## table (plan.md T1.8). That output is pasted verbatim into docs/plan/01-physics-table-balls.md
## §2, so names, formulas and defaults can never drift from the code that defines them.
##   godot --path . --headless -s src/tools/spec_dump.gd

func _init() -> void:
	var spec := TableSpec.new()

	print("`REG_*` constants (metres/degrees, 9-ft WPA regulation):\n")
	print("| constant | value |")
	print("|---|---:|")
	var regs := [
		["REG_LENGTH", TableSpec.REG_LENGTH], ["REG_WIDTH", TableSpec.REG_WIDTH],
		["REG_BALL_RADIUS", TableSpec.REG_BALL_RADIUS], ["REG_CORNER_MOUTH", TableSpec.REG_CORNER_MOUTH],
		["REG_SIDE_MOUTH", TableSpec.REG_SIDE_MOUTH], ["REG_CUSHION_NOSE_H", TableSpec.REG_CUSHION_NOSE_H],
		["REG_RAIL_WIDTH", TableSpec.REG_RAIL_WIDTH], ["REG_RAIL_TOP_H", TableSpec.REG_RAIL_TOP_H],
		["REG_APRON_H", TableSpec.REG_APRON_H], ["REG_JAW_RADIUS", TableSpec.REG_JAW_RADIUS],
		["REG_CORNER_SHELF", TableSpec.REG_CORNER_SHELF], ["REG_SIDE_SHELF", TableSpec.REG_SIDE_SHELF],
		["REG_CORNER_FACING_DEG", TableSpec.REG_CORNER_FACING_DEG], ["REG_SIDE_FACING_DEG", TableSpec.REG_SIDE_FACING_DEG],
		["REG_CUE_REACH", TableSpec.REG_CUE_REACH],
	]
	for r in regs:
		print("| `%s` | %s |" % [r[0], r[1]])

	print("\n`@export` fields (feel, `[tune]`, plus `scale` and `bed_height_m`):\n")
	print("| field | default |")
	print("|---|---:|")
	var exports := [
		"scale", "bed_height_m", "cushion_restitution", "cushion_restitution_min",
		"cushion_soft_speed_mps", "cushion_hard_speed_mps", "cushion_friction", "cloth_friction",
		"ball_friction", "ball_restitution", "ball_cascade_enabled", "rolling_resistance", "spin_decay",
		"ball_linear_damp", "ball_angular_damp", "rest_speed_mps", "rest_ang_rad_s", "rest_time_sec",
		"cup_friction", "cup_bounce", "clearance_margin_m", "jaw_restitution", "ccd_step_radii",
		"ccd_speed_mps", "max_ball_speed_mps",
	]
	for k in exports:
		print("| `%s` | %s |" % [k, spec.get(k)])

	print("\nDerived getters at the default `scale = %s` (`REG_* × scale`, `bed_height_m` excepted):\n" % spec.scale)
	print("| getter | value | formula |")
	print("|---|---:|---|")
	var derived := [
		["length_m", "REG_LENGTH × scale"],
		["width_m", "REG_WIDTH × scale"],
		["ball_radius_m", "REG_BALL_RADIUS × scale"],
		["corner_mouth_m", "REG_CORNER_MOUTH × scale"],
		["side_mouth_m", "REG_SIDE_MOUTH × scale"],
		["jaw_radius_m", "REG_JAW_RADIUS × scale"],
		["kitchen_line_x", "-length_m / 4"],
		["rail_height_m", "REG_RAIL_TOP_H × scale"],
		["cushion_nose_h_m", "REG_CUSHION_NOSE_H × scale"],
		["rail_width_m", "REG_RAIL_WIDTH × scale"],
		["apron_h_m", "REG_APRON_H × scale"],
		["corner_shelf_m", "REG_CORNER_SHELF × scale"],
		["side_shelf_m", "REG_SIDE_SHELF × scale"],
		["foot_spot_x", "length_m / 4"],
		["cue_reach_m", "REG_CUE_REACH × scale"],
	]
	for d in derived:
		print("| `%s` | %s | %s |" % [d[0], spec.get(d[0]), d[1]])

	quit()
