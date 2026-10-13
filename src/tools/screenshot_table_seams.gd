extends SceneTree

## One-shot: renders the table in the real bar room from six player-reachable poses (grazing and eye height, both long
## rails, a corner pocket, a side pocket) and measures the seam glare of 06 P32: the mean luminance of the pixels ON a
## seam (cushion nose base meeting the cloth, cushion meeting its rail block) against the cloth just beside it. A seam
## must read no brighter than 1.1 x the cloth. Needs a window.
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_table_seams.gd -- <out_dir> <tag> [key=value ...]
## -> <out_dir>/<tag>_<pose>.png (plain) + <tag>_<pose>_marked.png (sample points drawn) + a ratio table on stdout.
## Experiment overrides (no scene edit): bias=0.04 (TableLamp shadow_bias), normal_bias=<f>, atlas=2048, subdiv=2,
## lamp_energy=<f>, lamp_specular=0, no_probe=1 (drop the ReflectTable probe), no_probes=1 (drop every ReflectionProbe),
## no_lamp_shadow=1, msaa=0 and scale=0.85 (the phone's QualityManager tiers 1-2). acne=1 adds a straight-down view of the
## cloth and prints its pixel noise (shadow acne / swimming shows as noise, peter-panning as a lit band at the cushion foot).
## leaks=1 [sweep=1] [jitter=<mm>] is the crack detector (`_run_leaks`).
## topdown=1 adds straight-down views, the whole table and a close-up of every pocket (adhoc-1014a V1, before/after of the
## hole): `<tag>_top_table.png`, `<tag>_top_<pocket id>.png`. topdown=only skips the six poses and the ratio table.

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
	if o.has("leaks"):
		await _run_leaks(out_dir, tag, o)
		return
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
	if o.has("no_probes"):  # every ReflectionProbe gone: no baked room reflection or specular ambient on the table
		for n in room.find_children("*", "ReflectionProbe", true, false):
			n.queue_free()
	if o.has("lamp_specular"):
		lamp.light_specular = float(o.lamp_specular)
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
	for pose in ([] if o.get("topdown", "") == "only" else _poses()):
		cam.global_position = table.to_global(pose.eye)
		cam.look_at(table.to_global(pose.target), Vector3.UP)
		for _i in 6:
			await process_frame
		var img := _shot()
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
			var is_seam: bool = seam_def.name != "rail_top"  # the rail top is a surface, not a seam: its cloth reference can sit in the cushion's shadow
			if is_seam:
				worst = maxf(worst, ratio)
			rows.append("%-24s %-9s seam %.4f  cloth %.4f  ratio %.2f  (%d pts) %s" % [pose.name, seam_def.name, seam / n, cloth / n, ratio, n, ("OK" if ratio <= LIMIT else "GLARE") if is_seam else "info"])
		marked.save_png("%s/%s_%s_marked.png" % [out_dir, tag, pose.name])
	if o.has("acne"):
		rows.append(await _acne(out_dir, tag))
	if o.has("topdown"):
		await _topdown(out_dir, tag)
	print("--- seam luminance vs cloth, tag=%s %s" % [tag, o])
	for r in rows:
		print(r)
	print("worst ratio %.2f (limit %.2f): %s" % [worst, LIMIT, "OK" if worst <= LIMIT else "GLARE"])
	quit()


## Straight down at the cloth from 1.5 m, then 0.35 m above a rail's cushion foot: the pixel-to-neighbour noise of the
## cloth (shadow acne and a too-small normal bias show as stripes there) and the band of cloth the cushion's shadow
## fails to reach (peter-panning: lit cloth between the cushion foot and its shadow, as a fraction of the shadow's width).
func _acne(out_dir: String, tag: String) -> String:
	var s := table.spec
	cam.global_position = table.to_global(Vector3(0.0, s.bed_height_m + 1.5, 0.0))
	cam.look_at(table.to_global(Vector3(0.0, s.bed_height_m, 0.0)), Vector3.FORWARD)
	for _i in 6:
		await process_frame
	var img := _shot()
	img.save_png("%s/%s_topdown.png" % [out_dir, tag])
	var noise := 0.0
	var n := 0
	for y in range(260, 460, 3):
		for x in range(400, 880, 3):
			var c := _luma(img, Vector2(x, y))
			var nb := (_luma(img, Vector2(x - 3, y)) + _luma(img, Vector2(x + 3, y)) + _luma(img, Vector2(x, y - 3)) + _luma(img, Vector2(x, y + 3))) * 0.25
			noise += absf(c - nb)
			n += 1
	return "%-24s cloth noise %.5f (mean |px - neighbours|, %d px)" % ["topdown_acne", noise / n, n]


## The viewport as an 8-bit sRGB image: with `use_hdr_2d` (the project's setting) `get_image()` is linear, which reads far too dark and
## would be linearised twice by `_luma`.
func _shot() -> Image:
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	if root.use_hdr_2d:
		img.linear_to_srgb()
	return img


## Straight down (north up) under the ceiling, lamp layer culled and a flat fill light so the rails and pits read: the whole
## table, then every pocket from 1.1 m with the frame centred 0.25 m in from the hole centre.
func _topdown(out_dir: String, tag: String) -> void:
	var s := table.spec
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	fill.light_energy = 0.9
	fill.shadow_enabled = false
	root.add_child(fill)
	cam.cull_mask = 0xFFFFF & ~CeilingCam.LAMP_LAYER
	var views: Array[Dictionary] = [{name = "table", eye = Vector3(0.0, s.bed_height_m + 2.2, 0.0), target = Vector3(0.0, s.bed_height_m, 0.0), fov = 100.0}]
	for id in table.pockets:
		var at: Vector3 = table.pockets[id].position
		var c := Vector3(at.x, s.bed_height_m, at.z) + Vector3(-signf(at.x), 0.0, -signf(at.z)) * 0.25
		views.append({name = String(id), eye = c + Vector3(0.0, 1.1, 0.0), target = c, fov = 70.0})
	for v in views:
		cam.fov = v.fov
		cam.global_position = table.to_global(v.eye)
		cam.look_at(table.to_global(v.target), Vector3.FORWARD)
		for _i in 6:
			await process_frame
		_shot().save_png("%s/%s_top_%s.png" % [out_dir, tag, v.name])


## Crack detector (06 P32): the table alone over a flat backdrop, rendered twice per view with two backdrop colours. A pixel
## that differs between the two shows the backdrop, i.e. the room behind the table; a run of such pixels thinner than
## LEAK_MAX_PX that is bounded by table pixels on both sides (along a row or a column) is a crack, not open background.
## On the phone a crack like that shows the lit floor or the lamp as a bright line. Views: the six player poses, a close-up
## of every pocket, and (sweep=1) an orbit of 24 azimuths x 3 heights. -> counts per view, `<tag>_leak_<view>.png` when > 0.
func _run_leaks(out_dir: String, tag: String, o: Dictionary) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.7)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	root.add_child(sun)
	table = TABLE.instantiate()
	root.add_child(table)
	if o.has("jitter"):  # phone precision stand-in: every visual mesh shifted by up to jitter mm per axis, so seams that only
		var rng := RandomNumberGenerator.new()  # closed because two meshes touch exactly open up
		rng.seed = 7
		var mm := float(o.jitter) * 0.001
		for c in table.get_children():
			if c is MeshInstance3D:
				c.position += Vector3(rng.randf_range(-mm, mm), rng.randf_range(-mm, mm), rng.randf_range(-mm, mm))
	cam = Camera3D.new()
	cam.fov = 70.0
	root.add_child(cam)
	cam.current = true
	await physics_frame
	var views: Array[Dictionary] = _poses()
	views.append_array(_pocket_views())
	if o.has("sweep"):
		views.append_array(_orbit_views())
	var total := 0
	for v in views:
		cam.global_position = table.to_global(v.eye)
		cam.look_at(table.to_global(v.target), Vector3.UP)
		var shots: Array[Image] = []
		for bg in [Color(1, 0, 1), Color(0, 1, 1)]:
			env.background_color = bg
			for _i in 4:
				await process_frame
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			shots.append(img)
		var hits := _crack_pixels(shots[0], shots[1])
		total += hits.size()
		if hits.size() > 0:
			var marked := shots[0]
			for px in hits:
				_dot(marked, px, Color.RED)
			marked.save_png("%s/%s_leak_%s.png" % [out_dir, tag, v.name])
		print("%-28s cracks %4d %s" % [v.name, hits.size(), _where(hits)])
	print("--- cracks total %d over %d views, tag=%s %s: %s" % [total, views.size(), tag, o, "OK" if total == 0 else "LEAKS"])
	quit()


const LEAK_MAX_PX := 5
const LEAK_DIFF := 0.25
const LEAK_NEAR := 12  # px: a sliver this close to open background is a silhouette tip


## Pixels of `a` that are a crack: backdrop shows (differs from `b`) in a run <= LEAK_MAX_PX bounded by table pixels.
func _crack_pixels(a: Image, b: Image) -> Array[Vector2i]:
	var w := a.get_width()
	var h := a.get_height()
	var da := a.get_data()
	var db := b.get_data()
	var diff := PackedByteArray()
	diff.resize(w * h)
	for i in w * h:
		var j := i * 3
		var d := maxi(maxi(absi(da[j] - db[j]), absi(da[j + 1] - db[j + 1])), absi(da[j + 2] - db[j + 2]))
		diff[i] = 1 if float(d) / 255.0 > LEAK_DIFF else 0
	var hit := PackedByteArray()
	hit.resize(w * h)
	for y in h:
		_runs(diff, hit, y * w, 1, w)
	for x in w:
		_runs(diff, hit, x, w, h)
	var thin := hit.duplicate()
	# backdrop that never reaches the image border is enclosed by the table: a hole in it, however wide
	var open := PackedByteArray()
	open.resize(w * h)
	var stack: Array[int] = []
	for i in w * h:
		var x := i % w
		var y := i / w
		if (x == 0 or y == 0 or x == w - 1 or y == h - 1) and diff[i] == 1 and open[i] == 0:
			open[i] = 1
			stack.append(i)
			while not stack.is_empty():
				var c: int = stack.pop_back()
				var cx := c % w
				var cy := c / w
				for ny in range(maxi(cy - 1, 0), mini(cy + 2, h)):  # 8-connected: the tip of the open window under the apron
					for nx in range(maxi(cx - 1, 0), mini(cx + 2, w)):  # can sit one diagonal step from the rest of it
						var n := ny * w + nx
						if diff[n] == 1 and open[n] == 0:
							open[n] = 1
							stack.append(n)
	for i in w * h:
		if diff[i] == 1 and open[i] == 0:
			hit[i] = 1
		elif hit[i] == 1 and _near(open, thin, i, w, h):
			hit[i] = 0  # a sliver of the silhouette (sights against the sky, a stair-step), not a crack in the table
	var out: Array[Vector2i] = []
	for i in w * h:
		if hit[i] == 1:
			out.append(Vector2i(i % w, i / w))
	return out


func _near(open: PackedByteArray, thin: PackedByteArray, i: int, w: int, h: int) -> bool:
	var x := i % w
	var y := i / w
	if x < LEAK_NEAR or y < LEAK_NEAR or x >= w - LEAK_NEAR or y >= h - LEAK_NEAR:
		return true  # the view's edge cuts a silhouette sliver short
	for dy in range(maxi(0, y - LEAK_NEAR), mini(h, y + LEAK_NEAR + 1)):
		for dx in range(maxi(0, x - LEAK_NEAR), mini(w, x + LEAK_NEAR + 1)):
			if open[dy * w + dx] == 1 and thin[dy * w + dx] == 0:
				return true
	return false


## Marks, along one line of `n` samples from `start` with stride `step`, every run of diff pixels that is short and has
## a table pixel on both ends (a run touching the image border is open background).
func _runs(diff: PackedByteArray, hit: PackedByteArray, start: int, step: int, n: int) -> void:
	var run_from := -1
	for k in n:
		var on := diff[start + k * step] == 1
		if on and run_from < 0:
			run_from = k
		elif not on and run_from >= 0:
			if run_from > 0 and k - run_from <= LEAK_MAX_PX:
				for m in range(run_from, k):
					hit[start + m * step] = 1
			run_from = -1


## Where the cracks are, as table-local positions on the cloth plane: the three biggest 8 cm cells.
func _where(hits: Array[Vector2i]) -> String:
	var cells := {}
	for px in hits:
		var from := cam.project_ray_origin(Vector2(px))
		var dir := cam.project_ray_normal(Vector2(px))
		var plane := Plane(Vector3.UP, table.to_global(Vector3(0, table.spec.bed_height_m, 0)).y)
		var at = plane.intersects_ray(from, dir)
		if at == null:
			continue
		var p := table.to_local(at as Vector3)
		var key := Vector2i(roundi(p.x / 0.08), roundi(p.z / 0.08))
		cells[key] = int(cells.get(key, 0)) + 1
	var keys := cells.keys()
	keys.sort_custom(func(l: Vector2i, r: Vector2i) -> bool: return cells[l] > cells[r])
	var parts: Array[String] = []
	for key: Vector2i in keys.slice(0, 3):
		parts.append("(%.2f,%.2f)x%d" % [key.x * 0.08, key.y * 0.08, cells[key]])
	return " ".join(parts)


## A close-up of every pocket from inside the table and from across it, 0.6 m above the cloth.
func _pocket_views() -> Array[Dictionary]:
	var s := table.spec
	var out: Array[Dictionary] = []
	for id in table.pockets:
		var at: Vector3 = table.pockets[id].position
		var inward := Vector3(-at.x, 0.0, -at.z).normalized()
		var p := Vector3(at.x, s.bed_height_m, at.z)
		out.append({name = "pocket_%s_in" % id, eye = p + inward * 0.5 + Vector3(0, 0.45, 0), target = p})
		out.append({name = "pocket_%s_low" % id, eye = p + inward * 0.7 + Vector3(0, 0.08, 0), target = p + Vector3(0, 0.02, 0)})
	return out


func _orbit_views() -> Array[Dictionary]:
	var s := table.spec
	var out: Array[Dictionary] = []
	for k in 24:
		var ang := TAU * k / 24.0
		for h in [0.1, 0.5, 0.8]:
			var eye := Vector3(cos(ang) * (s.length_m * 0.5 + 0.9), s.bed_height_m + h, sin(ang) * (s.width_m * 0.5 + 0.9))
			out.append({name = "orbit_%02d_h%d" % [k, int(h * 10)], eye = eye, target = Vector3(0, s.bed_height_m, 0)})
	return out


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
	var top := out_dir * ((s.ball_radius_m * 2.0 + s.rail_width_m) * 0.5) + Vector3(0, s.rail_height_m, 0)
	out.append({name = "rail_top", a = a + top, b = b + top, beside = toward - top})
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
