extends SceneTree

## Headless geometry probe (plan.md T1.3): asserts TableGeometry.layout() produces the right
## shape and that every derived TableSpec value tracks REG_* × scale — no scene, no physics.
##   godot --path . --headless -s tests/physics/geometry_probe.gd

func _init() -> void:
	var spec := TableSpec.new()
	spec.scale = 2.0
	var out := TableGeometry.layout(spec)

	assert(out.pockets.size() == 6, "expected 6 pockets, got %d" % out.pockets.size())
	assert(out.rails.size() == 6, "expected 6 rails, got %d" % out.rails.size())
	assert(out.sights.size() == 18, "expected 18 sights, got %d" % out.sights.size())
	print("geometry: %d pockets, %d rails, %d sights" % [out.pockets.size(), out.rails.size(), out.sights.size()])

	var head: Vector3 = out.spots.head
	var foot: Vector3 = out.spots.foot
	assert(is_equal_approx(head.x, -spec.length_m / 4.0), "head spot not at -length/4")
	assert(is_equal_approx(foot.x, spec.length_m / 4.0), "foot spot not at +length/4")
	print("spots: head.x=%.4f foot.x=%.4f (±length/4 = %.4f)" % [head.x, foot.x, spec.length_m / 4.0])

	var checks := {
		length_m = [spec.length_m, TableSpec.REG_LENGTH],
		width_m = [spec.width_m, TableSpec.REG_WIDTH],
		ball_radius_m = [spec.ball_radius_m, TableSpec.REG_BALL_RADIUS],
		corner_mouth_m = [spec.corner_mouth_m, TableSpec.REG_CORNER_MOUTH],
		side_mouth_m = [spec.side_mouth_m, TableSpec.REG_SIDE_MOUTH],
		jaw_radius_m = [spec.jaw_radius_m, TableSpec.REG_JAW_RADIUS],
		cushion_nose_h_m = [spec.cushion_nose_h_m, TableSpec.REG_CUSHION_NOSE_H],
		rail_width_m = [spec.rail_width_m, TableSpec.REG_RAIL_WIDTH],
		rail_height_m = [spec.rail_height_m, TableSpec.REG_RAIL_TOP_H],
		apron_h_m = [spec.apron_h_m, TableSpec.REG_APRON_H],
		corner_shelf_m = [spec.corner_shelf_m, TableSpec.REG_CORNER_SHELF],
		side_shelf_m = [spec.side_shelf_m, TableSpec.REG_SIDE_SHELF],
		cue_reach_m = [spec.cue_reach_m, TableSpec.REG_CUE_REACH],
	}
	for k in checks:
		var got: float = checks[k][0]
		var reg: float = checks[k][1]
		assert(is_equal_approx(got, reg * spec.scale), "%s: %.6f != REG × scale (%.6f)" % [k, got, reg * spec.scale])
	print("all %d derived values = REG × %.1f" % [checks.size(), spec.scale])

	for r in out.rails:
		assert(not r.facing_a.is_zero_approx() and not r.facing_b.is_zero_approx(), "rail %s missing facing" % r.id)
	assert(is_equal_approx(spec.bed_height_m, 0.9), "bed_height_m must stay player-relative, not scale with `scale`")

	print("GEOMETRY OK")
	quit()
