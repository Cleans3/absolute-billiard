class_name RoomPrewarm
extends Node3D
## The parked copy of an in-room cutscene's new visual pieces (adhoc-1014b S6, `FailRoom.prewarm` / `WinRoom.prewarm`): a beacon (AlertLight and
## its spot) at its mount, and a CutScreen on the shader the beat will use, barely washed so that it draws. The beat's own `_build` makes its own
## copies later and finds the shaders and pipelines warm. The owner draws this for two frames, hides it (the screen pass follows: a Control does
## not inherit a Node3D's `visible`, so it listens for it) and keeps it for the level's lifetime. Nothing here touches the world.

const NO_CULL := 16384.0  ## GeometryInstance3D.extra_cull_margin's top: wherever the camera is, the pieces are not culled and so are drawn

var _cut: CutScreen


## A hidden-ready root under `level` with the beacon in `color` and the screen pass (`blurs` as the beat sets it). Null without a level. Add
## anything else to it, then `finish()`.
static func make(level: Node, part_name: StringName, color: Color, blurs: bool) -> RoomPrewarm:
	if level == null or not level.is_inside_tree():
		return null
	var warm := RoomPrewarm.new()
	warm.name = part_name
	warm.top_level = true  # the mount is a world position whatever the level's transform
	level.add_child(warm)
	var alert := AlertLight.new()
	alert.position = AlertLight.MOUNT
	warm.add_child(alert)
	alert.pose(0.0, color, 1.0)  # the spot on: it is the pipeline that counts, not the colour
	warm._cut = CutScreen.new()
	warm._cut.blurs = blurs
	warm.add_child(warm._cut)
	warm._cut.set_wash(color, 0.004, 0.0, 0.0, 0.0)  # a wash nobody can see, but a real draw
	return warm


## Every drawable piece is kept in the frustum, so the two drawn frames compile what the beat will draw.
func finish() -> RoomPrewarm:
	for g in find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).extra_cull_margin = NO_CULL
	return self


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _cut != null:
		_cut.visible = _cut.active and is_visible_in_tree()
