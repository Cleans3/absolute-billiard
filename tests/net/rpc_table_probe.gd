extends SceneTree
## Locks 04 §5's RPC table to the code (CLAUDE.md: modes/channels must match exactly). Parses every
## `@rpc(mode, sync, transfer, channel)` in src/**/*.gd and every row of the table, and asserts both
## directions agree on function, mode, sync, transfer, channel, node and (C→H / H→A) direction.
##   godot --path . --headless -s tests/net/rpc_table_probe.gd      prints RPC TABLE OK

const DOC := "res://docs/plan/04-architecture-netcode.md"

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _fail(msg: String) -> void:
	_failures += 1
	printerr("RPC TABLE: " + msg)


func _code(dir: String, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			_scan(dir.path_join(f), out)
	for d in DirAccess.get_directories_at(dir):
		_code(dir.path_join(d), out)


func _scan(path: String, out: Dictionary) -> void:
	var re := RegEx.create_from_string('^@rpc\\("(\\w+)",\\s*"(\\w+)",\\s*"(\\w+)",\\s*(\\d+)\\)')
	var fn := RegEx.create_from_string("^func (\\w+)\\(")
	var lines := FileAccess.get_file_as_string(path).split("\n")
	for i in lines.size():
		var m := re.search(lines[i])
		if m == null:
			continue
		var f := fn.search(lines[i + 1])
		if f == null:
			_fail("%s:%d @rpc not followed by a func" % [path, i + 1])
			continue
		var name := f.get_string(1)
		if out.has(name):
			_fail("%s: rpc func name '%s' is not unique (also %s)" % [path, name, out[name].path])
		out[name] = {mode = m.get_string(1), sync = m.get_string(2), transfer = m.get_string(3), ch = int(m.get_string(4)), path = path}


func _rows() -> Array[PackedStringArray]:
	var rows: Array[PackedStringArray] = []
	var on := false
	for line in FileAccess.get_file_as_string(DOC).split("\n"):
		if line.begins_with("### RPC table"):
			on = true
		elif on and line.begins_with("###"):
			break
		elif on and line.begins_with("| ") and not line.begins_with("| RPC") and not line.begins_with("|---"):
			var cells := PackedStringArray()
			for c in line.split("|"):
				cells.append(c.strip_edges())
			cells = cells.slice(1, cells.size() - 1)  # drop the empty ends of "| a | b |"
			if cells.size() == 7:
				rows.append(cells)
			else:
				_fail("row with %d cells: %s" % [cells.size(), line.left(80)])
	return rows


func _unq(s: String) -> String:
	return s.replace("`", "")


func _run() -> void:
	var code := {}
	_code("res://src", code)
	var rows := _rows()
	var name_re := RegEx.create_from_string("`(_?[a-z][a-z_]*)[`(]")
	var seen := {}
	for r in rows:
		var fn := ""
		var first := ""
		for m in name_re.search_all(r[0]):
			var n := m.get_string(1)
			first = first if first != "" else n
			if code.has(n) and fn == "":
				fn = n
		if fn == "":
			_fail("doc row '%s' has no matching @rpc func in src" % first)
			continue
		if seen.has(fn):
			_fail("doc lists '%s' twice" % fn)
		seen[fn] = true
		var c: Dictionary = code[fn]
		for want in [["mode", _unq(r[3]), c.mode], ["sync", _unq(r[4]), c.sync], ["transfer", _unq(r[5]), c.transfer], ["channel", _unq(r[6]), str(c.ch)]]:
			if want[1] != want[2]:
				_fail("%s: doc %s=%s but code %s (%s)" % [fn, want[0], want[1], want[2], c.path])
		var dir: String = r[2]
		if (dir.begins_with("C") or dir.begins_with("any")) != (c.mode == "any_peer"):
			_fail("%s: direction '%s' disagrees with mode %s" % [fn, dir, c.mode])
		var stem: String = String(c.path).get_file().get_basename().replace("_", "").to_lower()
		var ok := false
		for part in r[1].split("/"):
			ok = ok or stem == part.replace("_", "").to_lower()
		if not ok:
			_fail("%s: doc node '%s' but defined in %s" % [fn, r[1], c.path])
	for fn in code:
		if not seen.has(fn):
			_fail("code rpc '%s' (%s, ch%d) has no row in 04 §5" % [fn, code[fn].path, code[fn].ch])
	print("rpc table: %d code rpcs, %d doc rows" % [code.size(), rows.size()])
	if _failures > 0:
		printerr("RPC TABLE FAILED: %d" % _failures)
		quit(1)
		return
	print("RPC TABLE OK")
	quit()
