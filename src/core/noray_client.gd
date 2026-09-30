class_name NorayClient
extends RefCounted
## Minimal client for foxssake/noray (MIT): line-based TCP control (`name text\n`) plus the UDP
## remote registrar. Every wait is wall-clock bounded and awaits process frames.

var oid := ""
var pid := ""
var local_port := 0  ## UDP source port the registrar saw; hand the SAME port to ENet

var _tcp := StreamPeerTCP.new()
var _rx := ""
var _inbox: Array[PackedStringArray] = []  # [name, text]


static func _frame() -> Signal:
	return (Engine.get_main_loop() as SceneTree).process_frame


static func _now() -> int:
	return Time.get_ticks_msec()


func open(host: String, port: int, timeout_sec: float) -> bool:
	if _tcp.connect_to_host(host, port) != OK:
		return false
	var t0 := _now()
	while true:
		_tcp.poll()
		match _tcp.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				return true
			StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
				return false
		if _now() - t0 > timeout_sec * 1000.0:
			return false
		await _frame()
	return false


## Registers this connection as a host: the server answers `set-oid` and `set-pid`.
func register_host(timeout_sec: float) -> bool:
	send("register-host")
	oid = await wait_command("set-oid", timeout_sec)
	pid = await wait_command("set-pid", timeout_sec)
	return oid != "" and pid != ""


## Tells the UDP registrar which address we appear from. Binds a fresh socket, spams the pid until
## the registrar answers `OK`, records the local port, then closes the socket so ENet can take it.
func register_remote(host: String, udp_port: int, timeout_sec: float) -> bool:
	var ip := IP.resolve_hostname(host, IP.TYPE_IPV4)
	if ip == "":
		return false
	var udp := PacketPeerUDP.new()
	if udp.bind(0) != OK:
		return false
	udp.set_dest_address(ip, udp_port)
	var t0 := _now()
	var last_send := -1000
	while _now() - t0 < timeout_sec * 1000.0:
		if _now() - last_send >= 250:
			udp.put_packet(pid.to_utf8_buffer())
			last_send = _now()
		if udp.get_available_packet_count() > 0:
			var ok := udp.get_packet().get_string_from_utf8() == "OK"
			if ok:
				local_port = udp.get_local_port()
			udp.close()
			return ok
		await _frame()
	udp.close()
	return false


func send(line: String) -> void:
	_tcp.put_data((line + "\n").to_utf8_buffer())


## Next `name` command's text, or "" on timeout. Other commands stay queued.
func wait_command(name: String, timeout_sec: float) -> String:
	var t0 := _now()
	while true:
		_pump()
		for i in _inbox.size():
			if _inbox[i][0] == name:
				var text := _inbox[i][1]
				_inbox.remove_at(i)
				return text
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED or _now() - t0 > timeout_sec * 1000.0:
			return ""
		await _frame()
	return ""


func close() -> void:
	_tcp.disconnect_from_host()


func _pump() -> void:
	_tcp.poll()
	var n := _tcp.get_available_bytes() if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED else 0
	if n > 0:
		_rx += _tcp.get_string(n)
	var nl := _rx.find("\n")
	while nl >= 0:
		var line := _rx.substr(0, nl).strip_edges()
		_rx = _rx.substr(nl + 1)
		var sp := line.find(" ")
		_inbox.append(PackedStringArray([line if sp < 0 else line.substr(0, sp), "" if sp < 0 else line.substr(sp + 1)]))
		nl = _rx.find("\n")
