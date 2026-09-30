class_name CameraScorer
extends RefCounted
## Auto-scores a rig's view of the pocket a ball dropped into (docs/plan/02 §3.2):
## view_quality = clamp(occlusion_clear × distance_falloff × facing_dot, 0, 1); the best rig wins.

const FULL_RANGE := 3.0  # closer than this scores full distance marks [tune]
const MAX_RANGE := 12.0  # farther than this scores none


static func view_quality(distance: float, facing_dot: float, clear: bool) -> float:
	if not clear:
		return 0.0
	var falloff := clampf(1.0 - (distance - FULL_RANGE) / (MAX_RANGE - FULL_RANGE), 0.0, 1.0)
	return clampf(falloff * maxf(facing_dot, 0.0), 0.0, 1.0)


## Camera_Mult = (1 + (tier_mult − 1) × view_quality) × stream_camera_bonus_mult.
static func camera_mult(tier_mult: float, quality: float, bonus := 1.0) -> float:
	return (1.0 + (tier_mult - 1.0) * quality) * bonus


## One rig's quality. `exclude` lists the balls' bodies: the ray must not count them as cover.
static func score(rig: CameraRig, target: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array[RID], mask: int) -> float:
	var eye := rig.eye()
	var to_target := target - eye
	var dist := to_target.length()
	if dist < 0.001:
		return 1.0
	var query := PhysicsRayQueryParameters3D.create(eye, target, mask, exclude)
	var clear := space.intersect_ray(query).is_empty()
	return view_quality(dist, rig.forward().dot(to_target / dist), clear)


## The winning rig and its quality, or {} when there are no rigs.
static func best(rigs: Array[CameraRig], target: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array[RID], mask: int) -> Dictionary:
	var out := {}
	var top := -1.0
	for rig in rigs:
		var q := score(rig, target, space, exclude, mask)
		if q > top:
			top = q
			out = {rig = rig, quality = q}
	return out
