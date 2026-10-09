extends SceneTree
## One-shot (needs a window, not --headless): renders the Skins screen's bar previews (polish 2 C2). Per BarSkin one
## panorama, a full turn of the bar room in that skin's colours seen from its middle, in cylindrical projection folded
## into SkinsScreen.PREVIEW_ROWS rows: assets/ui/bar_preview/<skin_id>.png, <= 1024 px a side (07 §8). The Skins screen
## slides a window over it (src/shaders/bar_preview.gdshader), so the room spins smoothly for one texture and no 3D.
## Built from narrow vertical strips, each a rectilinear render of 2.8 degrees either side of its heading: at that width a
## strip is a cylinder slice to within a pixel. Re-run it whenever the room changes (decor, lightmap re-bake, new BarSkin):
##   godot --path . -s src/tools/render_bar_previews.gd            every skin
##   godot --path . -s src/tools/render_bar_previews.gd -- tiki    just that one
## then `godot --path . --headless --import`. Layout constants live in SkinsScreen.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const DEMO_RACK := preload("res://src/gameplay/round/demo_rack.gd")
const OUT_DIR := "res://assets/ui/bar_preview/"
const STRIP_W := 32  ## output px per strip: 32 strips fill a 1024 px row (a half turn), 64 make the full turn
const SUPERSAMPLE := 2  ## strips are rendered at 2x and filtered down
const TABLE_CENTRE := Vector3(0.0, 0.0, -3.5)
const EYE := Vector3(0.0, 1.6, 0.6)  ## standing in the room's middle, the table ahead at heading 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var wanted: Array[StringName] = []
	for a in OS.get_cmdline_user_args():
		wanted.append(StringName(a))
	var sheet_px := SkinsScreen.PREVIEW_SHEET
	var rows := SkinsScreen.PREVIEW_ROWS
	var row_h := sheet_px.y / rows
	var per_row := sheet_px.x / STRIP_W
	var slices := per_row * rows
	var px_per_rad := float(sheet_px.x * rows) / TAU  ## the cylinder's radius in px
	var vp := SubViewport.new()  # shares the root's 3D world; the window itself can stay small
	vp.size = Vector2i(STRIP_W, row_h) * SUPERSAMPLE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_2X
	root.add_child(vp)
	var room: BarRoom = ROOM.instantiate()
	root.add_child(room)
	var table: Table = TABLE.instantiate()
	table.position = TABLE_CENTRE
	root.add_child(table)
	await physics_frame
	var rack := Node3D.new()
	rack.set_script(DEMO_RACK)
	rack.table = table
	root.add_child(rack)
	var cam := Camera3D.new()
	cam.fov = rad_to_deg(2.0 * atan(row_h / (2.0 * px_per_rad)))  # the strip's vertical field: tan(phi) spans the row height
	cam.position = EYE
	cam.current = true
	vp.add_child(cam)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var failed := false
	for skin in SkinCatalog.bars():
		if not wanted.is_empty() and skin.id not in wanted:
			continue
		room.apply_skin(skin)
		table.set_felt_color(skin.felt_color)
		var sheet := Image.create(sheet_px.x, sheet_px.y, false, Image.FORMAT_RGB8)
		for i in slices:
			cam.rotation = Vector3(0.0, -TAU * (i + 0.5) / slices, 0.0)  # heading turns clockwise from the table, left to right on the sheet
			for k in 3:
				await RenderingServer.frame_post_draw
			var strip := vp.get_texture().get_image()
			strip.convert(Image.FORMAT_RGB8)
			strip.resize(STRIP_W, row_h, Image.INTERPOLATE_LANCZOS)
			sheet.blit_rect(strip, Rect2i(0, 0, STRIP_W, row_h), Vector2i((i % per_row) * STRIP_W, (i / per_row) * row_h))
		var path := OUT_DIR + String(skin.id) + ".png"
		var err := sheet.save_png(path)
		failed = failed or err != OK
		print("bar preview %s -> %s %dx%d %s" % [skin.id, path, sheet.get_width(), sheet.get_height(), "OK" if err == OK else error_string(err)])
	quit(1 if failed else 0)
