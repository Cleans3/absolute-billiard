extends SceneTree
## Crockford lobby code round-trip. `godot --path . --headless -s tests/net/lobby_code_probe.gd`


func _init() -> void:
	for n in [0, 1, 31, 32, 1023, 123456789, (1 << 30) - 1]:
		var c := LobbyCode.encode(n)
		assert(c.length() == 6 and LobbyCode.normalize(c) == c, "canonical %s" % c)
		assert(LobbyCode.decode(c) == n, "round trip %d" % n)
	assert(LobbyCode.normalize(" ab3k7q ") == "AB3K7Q", "case + trim")
	assert(LobbyCode.normalize("OIl000") == "011000", "aliases O→0 I/L→1")
	assert(LobbyCode.normalize("AB3K7") == "", "too short")
	assert(LobbyCode.normalize("AB3K7U") == "", "U is not Crockford")
	for i in 200:  # random codes survive text → int → text
		var n := randi() & ((1 << 30) - 1)
		assert(LobbyCode.decode(LobbyCode.encode(n).to_lower()) == n)
	print("LOBBY CODE OK")
	quit()
