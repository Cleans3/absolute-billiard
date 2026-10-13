extends Control
## Boot screen (docs/plan/04 §4): Campaign / Endless, Host / Join by code / Advanced IP / Solo, then the room (code,
## roster, Start). The mode pick is the host's (Solo, or the room until Start); it rides GameLoop.pending_mode and clients
## learn it from GameLoop.run_state.
## Settings / Controls / Skins open as modals of this scene's UIRouter.

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
	load_failed = "Couldn't load the bar.",
}
## What the connecting wait is on, by NetManager.connect_step.
const STEPS := {
	relay = "reaching the relay",
	lookup = "looking up the lobby",
	direct = "trying a direct link",
	tunnel = "switching to the relay tunnel",
	steam = "waiting for Steam",
}

const MODE_HINTS := {
	campaign = "3 Nights, then the Buyout and the exit.",
	endless = "Never ends. The quota keeps climbing.",
}

var _connecting := false
var _connect_msec := 0
var _connect_shown := -1

@onready var _home: Array[Control] = [%ModeBox, %Host, %JoinRow, %AdvancedToggle, %Solo, %Footer]
@onready var _resume_screen: Array[Control] = [%ResumeScroll, %ResumeBack]
@onready var _room: Array[Control] = [%RoomCode, %Share, %Roster, %Start, %Leave]
@onready var _status: Label = %Status


func _ready() -> void:
	SaveManager.pending_resume = null  # a stale pick from an earlier visit must not resume this lobby
	var modes := ButtonGroup.new()
	%ModeCampaign.button_group = modes
	%ModeEndless.button_group = modes
	%ModeCampaign.toggled.connect(_on_mode_toggled.bind(GameLoop.MODE_CAMPAIGN))
	%ModeEndless.toggled.connect(_on_mode_toggled.bind(GameLoop.MODE_ENDLESS))
	if GameLoop.pending_mode == GameLoop.MODE_ENDLESS:
		%ModeEndless.button_pressed = true
	else:
		%ModeCampaign.button_pressed = true
	_set_mode(GameLoop.pending_mode)
	%Resume.pressed.connect(_show_resume)
	%ResumeBack.pressed.connect(_set_home.bind(true))
	%Host.pressed.connect(_busy.bind(NetManager.host))
	%Join.pressed.connect(func() -> void: _busy(NetManager.join_code.bind(%Code.text)))
	%JoinIP.pressed.connect(_on_join_ip)
	%HostLan.pressed.connect(_busy.bind(NetManager.host.bind(NetManager.Transport.ENET_DIRECT)))
	%Steam.pressed.connect(_busy.bind(NetManager.host.bind(NetManager.Transport.STEAM)))
	%Solo.pressed.connect(_busy.bind(NetManager.host_solo))
	%AdvancedToggle.toggled.connect(func(on: bool) -> void: %AdvancedRow.visible = on)
	%Settings.pressed.connect(_open_group.bind(&"ui_settings"))
	%Controls.pressed.connect(_open_group.bind(&"ui_controls"))
	%Skins.pressed.connect(_open_group.bind(&"ui_skins"))
	%Quit.pressed.connect(get_tree().quit)
	%Controls.visible = not OS.has_feature("mobile")  # no keyboard to rebind on a phone
	%Quit.visible = OS.has_feature("pc")
	%Share.pressed.connect(_on_share)
	%Start.pressed.connect(_on_start)
	%Leave.pressed.connect(NetManager.leave)
	%Cancel.pressed.connect(NetManager.leave)  # aborts the relay registration / join in flight (NetManager._gen)
	NetManager.session_started.connect(func(_h: bool) -> void: _show_room())
	NetManager.roster_changed.connect(_refresh_room)
	NetManager.session_failed.connect(_on_failed)
	NetManager.session_ended.connect(_on_ended)
	%Leave.pressed.connect(func() -> void: SaveManager.pending_resume = null)
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


func _process(_delta: float) -> void:
	if not _connecting:
		return
	var secs := (Time.get_ticks_msec() - _connect_msec) / 1000
	if secs != _connect_shown:
		_connect_shown = secs
		_status.text = "Connecting: %s… %d s" % [STEPS.get(NetManager.connect_step, "starting"), secs]


## Esc / the phone's Back: out of the lobby, out of a connect, back from the resume list. Settings etc. keep their own Esc.
func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel") or UIRouter.blocking():
		return
	if %ResumeScroll.visible:
		%ResumeBack.pressed.emit()
	elif _connecting or %Roster.visible:
		NetManager.leave()
	else:
		return
	get_viewport().set_input_as_handled()


func _busy(action: Callable) -> void:
	_connecting = true
	_connect_msec = Time.get_ticks_msec()
	_connect_shown = -1
	%Cancel.visible = true
	_status.text = "Connecting: starting… 0 s"
	for b: BaseButton in [%Host, %Steam, %Join, %JoinIP, %HostLan, %Solo]:
		b.disabled = true
	%Cancel.grab_focus()
	action.call()


func _on_start() -> void:
	%Start.disabled = true
	_status.text = "Starting: sending everyone to the bar (%d player%s)" % [NetManager.get_roster().size(), "" if NetManager.get_roster().size() == 1 else "s"]
	NetManager.start_game()


func _on_join_ip() -> void:
	var parts: PackedStringArray = %Address.text.strip_edges().rsplit(":", true, 1)
	var port := int(parts[1]) if parts.size() == 2 else NetManager.config.direct_port
	_busy(NetManager.join_direct.bind(parts[0], port))


func _on_failed(reason: StringName) -> void:
	SaveManager.pending_resume = null
	_set_home(true)
	_status.text = REASONS.get(reason, "Failed: %s" % reason)


## Left the lobby, cancelled a connect, or the host left: back to the main menu, host controls reset.
func _on_ended(_reason: StringName) -> void:
	SaveManager.pending_resume = null
	_set_home(true)
	_status.text = REASONS.get(NetManager.take_notice(), "")
	%Host.grab_focus()


func _on_mode_toggled(on: bool, mode: StringName) -> void:
	if on:
		_set_mode(mode)


func _set_mode(mode: StringName) -> void:
	GameLoop.pending_mode = mode
	%ModeHint.text = MODE_HINTS[String(mode)]


func _open_group(group: StringName) -> void:
	var m := get_tree().get_first_node_in_group(group)
	if m != null:
		m.call(&"open")


func _set_home(on: bool) -> void:
	_connecting = false
	%Cancel.visible = false
	%Start.disabled = false
	for c in _home:
		c.visible = on
	%AdvancedRow.visible = on and %AdvancedToggle.button_pressed
	%Steam.visible = on and NetManager.steam_available()  # PC + addon + Steam client only
	for c in _room:
		c.visible = not on
	for c in _resume_screen:
		c.visible = false
	%Resume.visible = on and not SaveManager.list_checkpoints().is_empty()
	for b: BaseButton in [%Host, %Steam, %Join, %JoinIP, %HostLan, %Solo]:
		b.disabled = false


## The Resume sub-screen: every checkpoint this device holds, newest first (any key, any past crew size).
func _show_resume() -> void:
	for c in %ResumeList.get_children():
		c.queue_free()
	for e in SaveManager.list_checkpoints():
		var row := Button.new()
		row.custom_minimum_size = Vector2(0, 68)
		row.text = resume_label(e)
		row.pressed.connect(_on_resume_pick.bind(e))
		%ResumeList.add_child(row)
	for c in _home:
		c.visible = false
	%Resume.visible = false
	%Steam.visible = false
	for c in _resume_screen:
		c.visible = true
	%ResumeBack.grab_focus()


## "Night 3 · Round 2 done · $1,500 · 3 crew · 2026-09-30 14:05", an Endless run led by "Endless · "
static func resume_label(e: Dictionary) -> String:
	var when := Time.get_datetime_string_from_unix_time(int(e.modified) + int(Time.get_time_zone_from_system().bias) * 60, true)
	var crew := " · %d crew" % e.crew if int(e.crew) > 0 else ""
	var endless := "Endless · " if e.get("mode", &"campaign") == GameLoop.MODE_ENDLESS else ""
	return "%sNight %d · Round %d done · $%d%s · %s" % [endless, e.night, e.round_index, e.cash, crew, when.substr(0, 16)]


## Host from the checkpoint: solo files stay solo; others use LAN when Advanced is open, else the relay.
## Whoever joins next starts from it; the head-count need not match the old crew (no seat lock).
func _on_resume_pick(e: Dictionary) -> void:
	var p := SaveManager.load_checkpoint(e.path)
	if p == null:
		_status.text = "That save can't be read (%s)." % SaveManager.last_error
		return
	SaveManager.pending_resume = p
	_set_home(true)
	if e.key == "solo":
		_busy(NetManager.host_solo)
	elif %AdvancedToggle.button_pressed:
		_busy(NetManager.host.bind(NetManager.Transport.ENET_DIRECT))
	else:
		_busy(NetManager.host)


func _show_room() -> void:
	_status.text = ""
	_set_home(false)
	%Share.visible = NetManager.lobby_code != "" or NetManager.transport == NetManager.Transport.STEAM
	%Start.visible = NetManager.is_host()
	%ModeBox.visible = NetManager.is_host() and SaveManager.pending_resume == null  # a resume brings its own mode; clients learn it in the bar
	if SaveManager.pending_resume != null:
		_status.text = "Resuming %sNight %d, after Round %d." % ["Endless " if SaveManager.pending_resume.mode == GameLoop.MODE_ENDLESS else "", SaveManager.pending_resume.current_night, SaveManager.pending_resume.round_index]
	%Leave.grab_focus()
	_refresh_room()


func _refresh_room() -> void:
	if not %Roster.visible:
		return
	%RoomCode.text = NetManager.lobby_code if NetManager.lobby_code != "" \
		else ("STEAM" if NetManager.transport == NetManager.Transport.STEAM else "LAN")
	var me := multiplayer.get_unique_id()
	var lines := PackedStringArray()
	for e in NetManager.get_roster():
		lines.append("%d. %s%s%s" % [e.seat + 1, e.name, " (host)" if e.seat == 0 else "", " (you)" if e.peer_id == me else ""])
	%Roster.text = "\n".join(lines)
	if NetManager.is_host() and SaveManager.pending_resume != null:
		return  # _show_room already says which Night this lobby resumes
	var crew := "%d/%d players" % [NetManager.get_roster().size(), NetManager.config.max_players]
	_status.text = ("Waiting for the host to start · " if not NetManager.is_host() else "In the lobby · ") + crew


func _on_share() -> void:
	if NetManager.transport == NetManager.Transport.STEAM:
		NetManager.steam_invite()
		return
	if not DeepLink.share(NetManager.share_link()):
		_status.text = "Invite link copied."
