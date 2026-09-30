extends SceneTree

## Static 07 §8 gates, no device: no texture above 1024^2, mobile export presets ship ETC2/ASTC only,
## exported PCK within budget and within 10% of the baseline (05 §9 "re-baseline only with a written reason").
##   godot --headless --path . -s src/tools/check_gates.gd -- [--pck=build/ci/m0.pck]
## Baseline: tests/perf/baseline.json {"pck_bytes": N}; allowed growth = max(10%, 2 MB).

const MAX_TEX := 1024
const PCK_MAX_MB := 90.0  # 07 §8 AAB ceiling
const SKIP := ["res://addons/", "res://docs/", "res://build/", "res://android/", "res://.godot/", "res://tests/"]
const IMG_EXT := ["png", "jpg", "jpeg", "webp", "exr", "hdr", "tga", "bmp"]

var _fails := 0


func _init() -> void:
	call_deferred("_run")


func _fail(msg: String) -> void:
	_fails += 1
	printerr("GATE FAIL: ", msg)


func _run() -> void:
	var n := _scan("res://")
	print("textures scanned: %d" % n)
	_presets()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pck="):
			_pck(a.substr(6))
	print("GATES %s" % ("FAIL" if _fails > 0 else "OK"))
	quit(1 if _fails > 0 else 0)


func _scan(dir: String) -> int:
	var count := 0
	for s in SKIP:
		if dir.begins_with(s):
			return 0
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in IMG_EXT:
			var img := Image.load_from_file(dir.path_join(f))
			count += 1
			if img == null:
				_fail("cannot read %s" % dir.path_join(f))
			elif maxi(img.get_width(), img.get_height()) > MAX_TEX:
				_fail("%s is %dx%d, max %d (07 §8)" % [dir.path_join(f), img.get_width(), img.get_height(), MAX_TEX])
	for d in DirAccess.get_directories_at(dir):
		count += _scan(dir.path_join(d))
	return count


func _presets() -> void:
	if not bool(ProjectSettings.get_setting("rendering/textures/vram_compression/import_etc2_astc", false)):
		_fail("project.godot: rendering/textures/vram_compression/import_etc2_astc must be true")
	var cf := ConfigFile.new()
	if cf.load("res://export_presets.cfg") != OK:
		_fail("export_presets.cfg unreadable")
		return
	for sec in cf.get_sections():
		if sec.ends_with(".options") or not cf.has_section_key(sec, "platform"):
			continue
		var platform: String = cf.get_value(sec, "platform")
		if platform != "Android" and platform != "iOS":
			continue
		var opt := sec + ".options"
		if cf.get_value(opt, "texture_format/s3tc_bptc", false):
			_fail("%s: mobile preset ships S3TC/BPTC textures (07 §8)" % cf.get_value(sec, "name"))
		if platform == "Android" and cf.get_value(opt, "architectures/armeabi-v7a", false):
			print("note: %s builds armeabi-v7a too (07 §8 wants arm64-v8a only)" % cf.get_value(sec, "name"))


func _pck(path: String) -> void:
	if not FileAccess.file_exists(path):
		_fail("pck %s missing" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var bytes := f.get_length()
	f.close()
	print("pck %s: %d bytes" % [path, bytes])
	if bytes > PCK_MAX_MB * 1048576.0:
		_fail("pck %.1f MB over %.0f MB" % [bytes / 1048576.0, PCK_MAX_MB])
	var bf := FileAccess.open("res://tests/perf/baseline.json", FileAccess.READ)
	if bf != null:
		var base := int(JSON.parse_string(bf.get_as_text()).get("pck_bytes", 0))
		var allowed := maxf(base * 1.10, base + 2.0 * 1048576.0)
		if base > 0 and bytes > allowed:
			_fail("pck grew %d -> %d (> 10%%/2 MB over baseline); re-baseline tests/perf/baseline.json with a written reason" % [base, bytes])
