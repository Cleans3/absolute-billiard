extends Node

## The M0 device run (07 §9): break -> bar -> effects -> soak, one after another, then a budget summary in
## user://perf/summary.csv and on stdout (`PERF|...` lines), then quit. Booted by the `m0` export feature
## (project.godot `run/main_scene.m0`) or by hand: `godot --path . res://src/debug/perf_sequence.tscn`.
## Parameters (all optional) come from user://perf_params.cfg (`key=value` per line, pushed by m0_device_run.sh)
## or `-- --key=value`: quick=1 (short smoke), runs, bar-seconds, effects-seconds, soak-minutes, step-limit-ms.

const STAGES: Array[String] = ["perf_break", "perf_bar", "perf_effects", "perf_soak"]

var _params := {}


func _ready() -> void:
	var boot_ms := Time.get_ticks_msec()  # engine start -> first scene ready (07 §6, compare with `am start -W`)
	_read_params()
	await get_tree().process_frame
	var rows: Array[Dictionary] = [{fixture = "boot", budget = "engine_start_to_sequence_ready", value = boot_ms, limit = 4000.0,
			op = "<=", unit = "ms", status = "INFO"}]
	var quick := bool(int(_params.get("quick", 0)))
	for stage in STAGES:
		var p := {}
		match stage:
			"perf_break":
				p.runs = int(_params.get("runs", 12 if quick else 100))
				p["step-limit-ms"] = float(_params.get("step-limit-ms", 1.0))
			"perf_bar":
				p.seconds = float(_params.get("bar-seconds", 12.0 if quick else 60.0))
			"perf_effects":
				p.seconds = float(_params.get("effects-seconds", 8.0 if quick else 30.0))
			"perf_soak":
				p.minutes = float(_params.get("soak-minutes", 0.6 if quick else 5.0))
		p["quick"] = int(quick)
		var fx: PerfFixture = (load("res://src/debug/%s.tscn" % stage) as PackedScene).instantiate()
		fx.params = p
		print("PERF|SEQUENCE|start|%s" % stage)
		add_child(fx)
		var got: Array = await fx.finished
		rows.append_array(got)
		fx.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	_write_summary(rows)
	print("PERF|SEQUENCE|DONE")
	get_tree().quit(0)


func _read_params() -> void:
	var f := FileAccess.open("user://perf_params.cfg", FileAccess.READ)
	if f != null:
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line.contains("="):
				var kv := line.split("=", true, 1)
				_params[kv[0].strip_edges()] = kv[1].strip_edges()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_params[kv[0]] = kv[1]


func _write_summary(rows: Array[Dictionary]) -> void:
	DirAccess.make_dir_recursive_absolute("user://perf")
	var f := FileAccess.open("user://perf/summary.csv", FileAccess.WRITE)
	f.store_line("fixture,budget,value,op,limit,unit,status")
	for r in rows:
		f.store_line("%s,%s,%.3f,%s,%.3f,%s,%s" % [r.fixture, r.budget, r.value, r.op, r.limit, r.unit, r.status])
		print(PerfFixture.format_row(r))
	f.close()
