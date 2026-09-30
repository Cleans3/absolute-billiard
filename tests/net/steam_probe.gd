extends SceneTree
## M7 init probe: SteamAPI init for app 480 through the real transport script. Prints `STEAM OK` or
## `STEAM SKIP: <reason>` (not a PC build / addon absent / Steam client not running); a missing optional
## dependency never fails the suite. `godot --path . --headless -s tests/net/steam_probe.gd`


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var script: GDScript = load("res://src/core/transport_steam.gd")
	if not OS.has_feature("pc"):
		print("STEAM SKIP: not a PC build")
	elif not Engine.has_singleton(&"Steam"):
		print("STEAM SKIP: GodotSteam addon absent (src/tools/fetch_godotsteam.sh)")
	elif not script.supported():
		print("STEAM SKIP: SteamMultiplayerPeer addon absent (src/tools/fetch_godotsteam.sh)")
	else:
		var t: Node = script.new()
		root.add_child(t)
		if t.init_steam():
			print("STEAM OK")
		else:
			print("STEAM SKIP: Steam client not running or steam_appid.txt missing (init for app 480 failed)")
	quit()
