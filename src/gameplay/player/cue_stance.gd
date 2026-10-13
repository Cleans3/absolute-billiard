class_name CueStance
extends RefCounted
## Where the shooter's body stands in CUE (06 P33 U1, 08 §2.7). The camera is pinned `CueController.BACK_M` behind the cue ball
## whatever is in the way: the table is wider than an arm. The body is not pinned. It stands on the aim line behind the ball at the
## nearest floor point where its pelvis axis (`Humanoid.RIG_SHIFT` left of the line) is BODY_R_M + CLEAR_M outside the table's
## outline, cloth plus wooden rails, and leans over the rail to the stick (`Humanoid.set_cue_rig`).

const BODY_R_M := 0.3   ## the disc about the pelvis axis that holds the hips, legs and feet of the CUE stance (cue_stance_probe checks it)
const CLEAR_M := 0.25   ## ... kept this far outside the outline
const FAR_M := 12.0     ## the aim line is out of any table well before this


## The outline's half extents (table-local x, z): the cloth and the wooden rails around it.
static func outline_half(spec: TableSpec) -> Vector2:
	return Vector2(spec.length_m * 0.5 + spec.rail_width_m, spec.width_m * 0.5 + spec.rail_width_m)


## Metres from a table-local point to the outline rectangle (0 inside it).
static func outline_gap(local: Vector3, half: Vector2) -> float:
	return Vector2(maxf(absf(local.x) - half.x, 0.0), maxf(absf(local.z) - half.y, 0.0)).length()


## The floor point (y = `floor_y`) the Humanoid node stands on for a cue ball at `ball` and the horizontal unit aim `aim`: under the
## camera when that is already clear of the table, else further back along the line. `table` null: under the camera.
static func feet_for(table: Table, ball: Vector3, aim: Vector3, floor_y: float) -> Vector3:
	var flat := Vector3(ball.x, floor_y, ball.z)
	var lo := CueController.BACK_M
	if table == null:
		return flat - aim * lo
	var inv := table.global_transform.affine_inverse()
	var half := outline_half(table.spec)
	var right := aim.cross(Vector3.UP)
	if _clear(inv, half, flat, aim, right, lo):
		return flat - aim * lo
	var hi := FAR_M  # the outline is convex and the line starts inside it: the gap only grows with t, so bisect
	for i in 18:
		var mid := (lo + hi) * 0.5
		if _clear(inv, half, flat, aim, right, mid):
			hi = mid
		else:
			lo = mid
	return flat - aim * hi


static func _clear(inv: Transform3D, half: Vector2, flat: Vector3, aim: Vector3, right: Vector3, t: float) -> bool:
	var pelvis := flat - aim * t - right * Humanoid.RIG_SHIFT
	return outline_gap(inv * pelvis, half) >= BODY_R_M + CLEAR_M
