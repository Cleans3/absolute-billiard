extends SceneTree

## One-shot (adhoc-1013c W1, U4): the real MainLevel (Solo) at the phone's quality tier, from the views where the glare shows
## (the side and corner pockets, the rail's outer face, a tripod near and far, the bartender's face), to PNGs plus a "halo" count:
## the pixels brighter than 0.55 with a near-black pixel (< 0.04) within 2 px, in the centre half of the frame, which is what
## "black with a bright white outline" is. Needs a window. The desktop is not proof (07: the phone glare never reproduced here);
## this is the before/after pair for the changes that can be shown.
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_glare.gd -- <out_dir> <tag> [key=value ...]
## tier=0|1|2 (default 1: MSAA off, scale 0.85, the QualityManager tier through Settings), aa=off|fxaa|smaa (override
## the tier's screen-space AA), no_glow=1, no_probes=1, no_lamp_shadow=1, lamp_specular=<f>.

const SIZE := Vector2i(1280, 720)
const HALO_LIGHT := 0.55
const HALO_DARK := 0.04
const HALO_REACH := 2


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
	var tag := args[1] if args.size() > 1 else "glare"
	var o := _opts()
	DirAccess.make_dir_recursive_absolute(out_dir)
	Settings.path = "user://shot_glare_settings.cfg"
	Settings.set_value(&"quality", Settings.QUALITY[1 + int(o.get("tier", "1"))])
	SaveManager.root = "user://shot_glare"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	root.size = SIZE
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	if is_instance_valid(lobby):
		lobby.queue_free()
	_experiments(level, o)
	var cam := Camera3D.new()
	cam.fov = 70.0
	level.add_child(cam)
	var rows: Array[String] = []
	var first := true
	for v in _views(level):
		cam.global_position = v.eye
		cam.look_at(v.target, v.get("up", Vector3.UP))
		for i in (60 if first else 14):
			cam.current = true  # the player's camera reclaims current while it spawns
			_override_aa(o)
			for cl: CanvasLayer in root.find_children("*", "CanvasLayer", true, false):
				cl.visible = false
			for c: Control in root.get_children().filter(func(n: Node) -> bool: return n is Control):
				c.visible = false
			await process_frame
		first = false
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_png("%s/%s_%s.png" % [out_dir, tag, v.name])
		rows.append("%-16s halo px %5d" % [v.name, _halo(img)])
	print("--- glare, tag=%s %s msaa=%d scale=%.2f aa=%d" % [tag, o, root.msaa_3d, root.scaling_3d_scale, root.screen_space_aa])
	for r in rows:
		print(r)
	quit()


func _override_aa(o: Dictionary) -> void:
	if o.has("aa"):
		root.screen_space_aa = {off = Viewport.SCREEN_SPACE_AA_DISABLED, fxaa = Viewport.SCREEN_SPACE_AA_FXAA, smaa = Viewport.SCREEN_SPACE_AA_SMAA}[o.aa]


func _experiments(level: Node, o: Dictionary) -> void:
	if o.has("no_glow"):
		for we: WorldEnvironment in level.find_children("*", "WorldEnvironment", true, false):
			we.environment.glow_enabled = false
	if o.has("no_probes"):
		for n in level.find_children("*", "ReflectionProbe", true, false):
			n.queue_free()
	var lamp := level.find_child("TableLamp", true, false) as SpotLight3D
	if lamp != null:
		if o.has("no_lamp_shadow"):
			lamp.shadow_enabled = false
		if o.has("lamp_specular"):
			lamp.light_specular = float(o.lamp_specular)


## World-space eyes and targets: the table sits at (0, 0, -3.5), cloth at y 0.9; the Bartender behind the counter at (6, 0, 2.5).
func _views(level: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		{name = "side_near", eye = Vector3(0.5, 1.6, -1.4), target = Vector3(0.0, 0.95, -2.17)},
		{name = "side_far", eye = Vector3(0.7, 1.55, -1.4), target = Vector3(0.0, 0.95, -4.83)},
		{name = "side_outer", eye = Vector3(0.45, 1.3, -1.0), target = Vector3(0.0, 0.7, -1.87)},
		{name = "corner_near", eye = Vector3(1.5, 1.5, -0.9), target = Vector3(2.6, 0.92, -2.17)},
		{name = "rail_graze", eye = Vector3(-2.6, 1.1, -0.9), target = Vector3(-1.0, 0.95, -2.2)},
		{name = "side_top", eye = Vector3(0.0, 2.1, -2.17), target = Vector3(0.0, 0.9, -2.17), up = Vector3.FORWARD},
		{name = "corner_top", eye = Vector3(2.6, 2.1, -2.17), target = Vector3(2.6, 0.9, -2.17), up = Vector3.FORWARD},
		{name = "bartender", eye = Vector3(4.4, 1.65, 2.5), target = Vector3(6.0, 1.6, 2.5)},
	]
	var rig: CameraRig = null
	for n in level.find_children("*", "CameraRig", true, false):
		rig = n
		break
	if rig != null:
		var at := rig.global_position
		out.append({name = "tripod_near", eye = at + Vector3(1.3, 1.5, 1.3), target = at + Vector3(0.0, 1.0, 0.0)})
		out.append({name = "tripod_far", eye = at + Vector3(2.8, 1.7, 2.8), target = at + Vector3(0.0, 1.0, 0.0)})
	return out


## Pixels > HALO_LIGHT with a pixel < HALO_DARK within HALO_REACH, over the centre half of the frame.
func _halo(img: Image) -> int:
	var w := img.get_width()
	var h := img.get_height()
	var luma := PackedFloat32Array()
	luma.resize(w * h)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			luma[y * w + x] = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	var n := 0
	for y in range(h / 4, h * 3 / 4):
		for x in range(w / 4, w * 3 / 4):
			if luma[y * w + x] <= HALO_LIGHT:
				continue
			var dark := false
			for dy in range(-HALO_REACH, HALO_REACH + 1):
				for dx in range(-HALO_REACH, HALO_REACH + 1):
					if luma[(y + dy) * w + x + dx] < HALO_DARK:
						dark = true
			if dark:
				n += 1
	return n
