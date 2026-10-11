extends SceneTree

## One-shot: renders the table in the real bar room from six player-reachable poses (grazing and eye height, both long
## rails, a corner pocket, a side pocket) and measures the seam glare of 06 P32: the mean luminance of the pixels ON a
## seam (cushion nose base meeting the cloth, cushion meeting its rail block) against the cloth just beside it. A seam
## must read no brighter than 1.1 x the cloth. Needs a window.
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_table_seams.gd -- <out_dir> <tag> [key=value ...]
## -> <out_dir>/<tag>_<pose>.png (plain) + <tag>_<pose>_marked.png (sample points drawn) + a ratio table on stdout.
## Experiment overrides (no scene edit): bias=0.04 (TableLamp shadow_bias), normal_bias=<f>, atlas=2048, subdiv=2,
## lamp_energy=<f>, no_probe=1 (drop the ReflectTable probe), no_lamp_shadow=1, msaa=0 and scale=0.85 (the phone's
## QualityManager tiers 1-2).

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const TABLE_POS := Vector3(0, 0, -3.5)
const SIZE := Vector2i(1280, 720)
const SAMPLES := 28
const LIMIT := 1.1

var table: Table
var cam: Camera3D
var room: Node


func _init() -> void:
	call_deferred("_run")


func _opts() -> Dictionary:
	var o := {}
	for a in OS.get_cmdline_user_args().slice(2):
		var kv := String(a).split("=")
		if kv.size() == 2:
			o[kv[0]] = kv[1]
	return o


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := args[0] if args.size() > 0 else "/tmp"
	var tag := args[1] if args.size() > 1 else "seams"
	var o := _opts()
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = SIZE
	root.msaa_3d = Viewport.MSAA_DISABLED if o.has("msaa") and o.msaa == "0" else Viewport.MSAA_2X
	if o.has("scale"):
		root.scaling_3d_scale = float(o.scale)  # QualityManager tier 1/2 render at 0.85 with no MSAA (07 §7.4)
	if o.has("atlas"):
		root.positional_shadow_atlas_size = int(o.atlas)
	if o.has("subdiv"):
		root.set_positional_shadow_atlas_quadrant_subdiv(0, int(o.subdiv))
	room = ROOM.instantiate()
	root.add_child(room)
	var lamp := room.get_node("TableLamp") as SpotLight3D
	if o.has("bias"):
		lamp.shadow_bias = float(o.bias)
	if o.has("normal_bias"):
		lamp.shadow_normal_bias = float(o.normal_bias)
	if o.has("lamp_energy"):
		lamp.light_energy = float(o.lamp_energy)
	if o.has("no_lamp_shadow"):
		lamp.shadow_enabled = false
	if o.has("no_probe"):
		room.get_node("ReflectTable").queue_free()
	table = TABLE.instantiate()
	table.position = TABLE_POS
	root.add_child(table)
	cam = Camera3D.new()
	cam.fov = 70.0
	root.add_child(cam)
	cam.current = true
	await physics_frame
	var worst := 0.0
	var rows: Array[String] = []
	for pose in _poses():
		cam.global_position = table.to_global(pose.eye)
		cam.look_at(table.to_global(pose.target), Vector3.UP)
		for _i in 6:
			await process_frame
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_png("%s/%s_%s.png" % [out_dir, tag, pose.name])
		var marked := img.duplicate() as Image
		for seam_def in _seams(pose):
			var seam := 0.0
			var cloth := 0.0
			var n := 0
			for k in SAMPLES:
				var t := (float(k) + 0.5) / SAMPLES
				var p: Vector3 = (seam_def.a as Vector3).lerp(seam_def.b as Vector3, t)
				var on := table.to_global(p)
				var off := table.to_global(p + (seam_def.beside as Vector3))
				if cam.is_position_behind(on) or cam.is_position_behind(off):
					continue
				var s := _luma(img, cam.unproject_position(on))
				var c := _luma(img, cam.unproject_position(off))
				if s < 0.0 or c < 0.0:
					continue
				seam += s
				cloth += c
				n += 1
				_dot(marked, cam.unproject_position(on), Color.YELLOW)
				_dot(marked, cam.unproject_position(off), Color.CYAN)
			if n == 0:
				continue
			var ratio := seam / cloth if cloth > 0.0 else -1.0
			worst = maxf(worst, ratio)
			rows.append("%-24s %-9s seam %.4f  cloth %.4f  ratio %.2f  (%d pts) %s" % [pose.name, seam_def.name, seam / n, cloth / n, ratio, n, "OK" if ratio <= LIMIT else "GLARE"])
		marked.save_png("%s/%s_%s_marked.png" % [out_dir, tag, pose.name])
	print("--- seam luminance vs cloth, tag=%s %s" % [tag, o])
	for r in rows:
		print(r)
	print("worst ratio %.2f (limit %.2f): %s" % [worst, LIMIT, "OK" if worst <= LIMIT else "GLARE"])
	quit()


## The seams of one pose's rail, each as a polyline `a`-`b` with `beside` pointing at the cloth: the cushion nose
## where it meets the cloth, the nose's top edge, the groove where the cushion's back meets the rail block, and the
## hole's rim where the cloth is cut (when the table has holes).
func _seams(pose: Dictionary) -> Array[Dictionary]:
	var s := table.spec
	var out: Array[Dictionary] = []
	var a: Vector3 = pose.a
	var b: Vector3 = pose.b
	var toward: Vector3 = pose.beside  # from the nose line onto the cloth (length = inset)
	var out_dir := -toward.normalized()
	out.append({name = "nose_base", a = a + Vector3(0, 0.002, 0), b = b + Vector3(0, 0.002, 0), beside = toward})
	out.append({name = "nose_top", a = a + Vector3(0, s.cushion_nose_h_m - 0.003, 0), b = b + Vector3(0, s.cushion_nose_h_m - 0.003, 0), beside = toward + Vector3(0, -s.cushion_nose_h_m, 0)})
	var g := out_dir * (s.ball_radius_m * 2.0 - 0.004) + Vector3(0, 0.004, 0)
	out.append({name = "groove", a = a + g, b = b + g, beside = toward + out_dir * 0.0 - g + Vector3(0, 0, 0)})
	return out


## Linear luminance of the 3x3 patch at `px`, -1 when off screen.
func _luma(img: Image, px: Vector2) -> float:
	var x := int(px.x)
	var y := int(px.y)
	if x < 2 or y < 2 or x >= img.get_width() - 2 or y >= img.get_height() - 2:
		return -1.0
	var sum := 0.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := img.get_pixel(x + dx, y + dy)
			sum += 0.2126 * pow(c.r, 2.2) + 0.7152 * pow(c.g, 2.2) + 0.0722 * pow(c.b, 2.2)
	return sum / 9.0


func _dot(img: Image, px: Vector2, color: Color) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := int(px.x) + dx
			var y := int(px.y) + dy
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, color)


## Six poses a player can reach. `a`-`b` is the seam polyline (table-local, at cloth height); `beside` points from the
## seam onto the cloth. Eye heights: standing 1.7 m, leaning in 1.25 m, grazing 0.99 m (cloth + 9 cm).
func _poses() -> Array[Dictionary]:
	var s := table.spec
	var y := s.bed_height_m
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var c := s.corner_mouth_m / sqrt(2.0)
	var m := s.side_mouth_m * 0.5
	var rail := s.rail_width_m
	var inset := 0.06
	var far_n := {a = Vector3(-hl + c + 0.2, y, -hw), b = Vector3(-m - 0.2, y, -hw), beside = Vector3(0, 0, inset)}
	var far_s := {a = Vector3(-hl + c + 0.2, y, hw), b = Vector3(-m - 0.2, y, hw), beside = Vector3(0, 0, -inset)}
	var side_n := {a = Vector3(m + 0.2, y, -hw), b = Vector3(hl - c - 0.2, y, -hw), beside = Vector3(0, 0, inset)}
	var short_w := {a = Vector3(-hl, y, -hw + c + 0.2), b = Vector3(-hl, y, hw - c - 0.2), beside = Vector3(inset, 0, 0)}
	return [
		_pose("stand_south_to_north", Vector3(-0.6, 1.7, hw + rail + 0.5), Vector3(-0.6, y, -hw), far_n),
		_pose("stand_north_to_south", Vector3(0.8, 1.7, -hw - rail - 0.5), Vector3(0.8, y, hw), far_s.duplicate().merged({a = Vector3(m + 0.2, y, hw), b = Vector3(hl - c - 0.2, y, hw)}, true)),
		_pose("graze_west_along_north", Vector3(-hl - 0.3, y + 0.09, -hw + 0.35), Vector3(0.5, y, -hw), side_n),
		_pose("graze_east_along_south", Vector3(hl + 0.3, y + 0.09, hw - 0.35), Vector3(-0.5, y, hw), far_s),
		_pose("corner_nw_from_east", Vector3(0.9, 1.25, 0.6), Vector3(-hl, y, -hw), far_n),
		_pose("side_n_from_south", Vector3(0.5, 1.5, hw + rail + 0.4), Vector3(0.0, y, -hw), side_n),
		_pose("short_rail_from_east", Vector3(hl - 0.4, 1.4, 0.2), Vector3(-hl, y, 0.0), short_w),
		_pose("jaw_corner_top", Vector3(-hl + c + 0.35, y + 0.45, -hw + 0.45), Vector3(-hl + c, y, -hw), far_n),
		_pose("jaw_side_top", Vector3(m + 0.45, y + 0.45, -hw + 0.45), Vector3(m, y, -hw), side_n),
		_pose("jaw_corner_low", Vector3(-hl + c + 0.6, y + 0.12, -hw + 0.5), Vector3(-hl + c, y + 0.03, -hw), far_n),
	]


func _pose(pose_name: String, eye: Vector3, target: Vector3, seam: Dictionary) -> Dictionary:
	var d := seam.duplicate()
	d.name = pose_name
	d.eye = eye
	d.target = target
	return d
