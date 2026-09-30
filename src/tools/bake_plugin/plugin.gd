@tool
extends EditorPlugin

## Driven by src/tools/bake_lightmaps.sh only. Opens BarRoom.tscn, selects its LightmapGI, presses the
## 3D toolbar's "Bake Lightmaps" button (the only bake entry point — LightmapGI.bake is not in the
## scripting API), saves, quits. Needs a real window + Vulkan RD.

const SCENE := "res://src/gameplay/bar_room/BarRoom.tscn"
const LMBAKE := "res://src/gameplay/bar_room/BarRoom.lmbake"


func _enter_tree() -> void:
	if OS.get_cmdline_user_args().has("bake-bar-room"):
		_bake.call_deferred()


func _find_button(n: Node) -> Button:
	if n is Button and (n as Button).text.contains("Bake Lightmaps"):
		return n
	for c in n.get_children():
		var b := _find_button(c)
		if b != null:
			return b
	return null


func _bake() -> void:
	for i in 60:
		await get_tree().process_frame
	EditorInterface.open_scene_from_path(SCENE)
	for i in 60:
		await get_tree().process_frame
	var root := EditorInterface.get_edited_scene_root()
	var lm := root.get_node("Lightmap") as LightmapGI
	# an already-saved LightmapGIData makes the plugin bake straight into it instead of asking for a path
	var data := LightmapGIData.new()
	ResourceSaver.save(data, LMBAKE)
	data.take_over_path(LMBAKE)
	lm.light_data = data
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(lm)
	for i in 30:
		await get_tree().process_frame
	var btn := _find_button(EditorInterface.get_base_control())
	if btn == null:
		printerr("BAKE FAIL: Bake Lightmaps button not found")
		get_tree().quit(1)
		return
	print("BAKE press root=", root.name, " in_tree=", lm.is_inside_tree(), " visible=", btn.is_visible_in_tree(), " disabled=", btn.disabled)
	btn.pressed.emit()
	for i in 300:
		await get_tree().process_frame
	EditorInterface.save_scene()
	print("BAKE DONE light_data=", lm.light_data)
	get_tree().quit(0 if lm.light_data != null else 1)
