extends Control
## Boot screen (docs/plan/04 §4): Host / Join by code / Advanced IP / Solo, then the room (code, roster, Start).

const REASONS := {
	bad_code = "That is not a lobby code.",
	unknown_code = "No lobby with that code.",
	relay_unreachable = "Can't reach the relay server.",
	relay_failed = "The relay refused the connection.",
	connection_failed = "Couldn't connect.",
	timeout = "Timed out connecting.",
	host_port_busy = "Port already in use.",
	host_failed = "Couldn't open the lobby.",
	join_failed = "Couldn't join.",
	host_left = "The host left the lobby.",
}

@onready var _home: Array[Control] = [%Host, $Center/Menu/JoinRow, %AdvancedToggle, %Solo]
@onready var _room: Array[Control] = [%RoomCode, %Share, %Roster, %Start, %Leave]
@onready var _status: Label = %Status


func _ready() -> void:
	%Host.pressed.connect(_busy.bind(NetManager.host))
	%Join.pressed.connect(func() -> void: _busy(NetManager.join_code.bind(%Code.text)))
	%JoinIP.pressed.connect(_on_join_ip)
	%HostLan.pressed.connect(_busy.bind(NetManager.host.bind(NetManager.Transport.ENET_DIRECT)))
	%Solo.pressed.connect(_busy.bind(NetManager.host_solo))
	%AdvancedToggle.toggled.connect(func(on: bool) -> void: %AdvancedRow.visible = on)
	%Share.pressed.connect(_on_share)
	%Start.pressed.connect(NetManager.start_game)
	%Leave.pressed.connect(NetManager.leave)
	NetManager.session_started.connect(func(_h: bool) -> void: _show_room())
	NetManager.roster_changed.connect(_refresh_room)
	NetManager.session_failed.connect(_on_failed)
	_status.text = REASONS.get(NetManager.take_notice(), "")
	_set_home(true)
	%Host.grab_focus()
	var code := DeepLink.take_launch_code()
	if code != "":
		%Code.text = code
		%Join.pressed.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and %Code.visible:  # warm start via a new invite link
		var code := DeepLink.take_launch_code()
		if code != "":
			%Code.text = code
			%Join.pressed.emit()


func _busy(action: Callable) -> void:
	_status.text = "Connecting…"
	for b: BaseButton in [%Host, %Join, %JoinIP, %HostLan, %Solo]:
		b.disabled = true
	action.call()


func _on_join_ip() -> void:
	var parts: PackedStringArray = %Address.text.strip_edges().rsplit(":", true, 1)
	var port := int(parts[1]) if parts.size() == 2 else NetManager.config.direct_port
	_busy(NetManager.join_direct.bind(parts[0], port))


func _on_failed(reason: StringName) -> void:
	_status.text = REASONS.get(reason, "Failed: %s" % reason)
	_set_home(true)


func _set_home(on: bool) -> void:
	for c in _home:
		c.visible = on
	for c in _room:
		c.visible = not on
	for b: BaseButton in [%Host, %Join, %JoinIP, %HostLan, %Solo]:
		b.disabled = false


func _show_room() -> void:
	_status.text = ""
	_set_home(false)
	%Share.visible = NetManager.lobby_code != ""
	%Start.visible = NetManager.is_host()
	%Leave.grab_focus()
	_refresh_room()


func _refresh_room() -> void:
	if not %Roster.visible:
		return
	%RoomCode.text = NetManager.lobby_code if NetManager.lobby_code != "" else "LAN"
	var me := multiplayer.get_unique_id()
	var lines := PackedStringArray()
	for e in NetManager.get_roster():
		lines.append("%d. %s%s%s" % [e.seat + 1, e.name, " (host)" if e.seat == 0 else "", " (you)" if e.peer_id == me else ""])
	%Roster.text = "\n".join(lines)
	if not NetManager.is_host():
		_status.text = "Waiting for the host to start…"


func _on_share() -> void:
	if not DeepLink.share(NetManager.share_link()):
		_status.text = "Invite link copied."
