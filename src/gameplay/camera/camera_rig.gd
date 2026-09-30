class_name CameraRig
extends Node3D
## A grabbable tripod camera (docs/plan/02 §2). A greybox prop: the view is scored by math, never rendered.
## Looks along -Z rotated by its yaw, tilted down PITCH; the friend who last placed it chose the angle.

const TIER_MULT: Array[float] = [1.0, 1.25, 1.5]  # tier 1 / 2 / 3 [tune]
const EYE_HEIGHT := 1.5
const PITCH := 0.35  # rad down

@export var camera_id: StringName
@export var tier := 1

var held_by := 0  # peer id carrying it; 0 = standing on its tripod


func _ready() -> void:
	var post := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.03
	cyl.bottom_radius = 0.25
	cyl.height = EYE_HEIGHT
	post.mesh = cyl
	post.position.y = EYE_HEIGHT * 0.5
	add_child(post)
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.25, 0.2, 0.4)
	body.mesh = box
	body.position.y = EYE_HEIGHT
	add_child(body)


func tier_mult() -> float:
	return TIER_MULT[clampi(tier, 1, TIER_MULT.size()) - 1]


func eye() -> Vector3:
	return global_position + Vector3.UP * EYE_HEIGHT


func forward() -> Vector3:
	var yaw := rotation.y
	return Vector3(-sin(yaw) * cos(PITCH), -sin(PITCH), -cos(yaw) * cos(PITCH))


func aim_at(point: Vector3) -> void:
	var d := point - global_position
	rotation.y = atan2(-d.x, -d.z)
