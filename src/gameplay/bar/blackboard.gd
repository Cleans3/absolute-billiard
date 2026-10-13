class_name Blackboard
extends Node3D
## The wall blackboard (docs/plan/08 §2.8, adhoc-1010a C9): Night, Round, viewers and hype, the running Hazard, the Drinks in
## effect, the last Round's result and the Night's ask. Everything the lean HUD no longer carries. Pure presentation: it listens
## to the mirrored game state (the same signals on every peer) and rewrites a line only when its text really changed, so a
## quiet Round costs nothing. Hype moves in 5% steps for that reason. The slate (smears, chalk rules, hype bar) is one shader
## quad; the lines are Label3D, which keep their mipmaps and stay readable from across the room. The story (docs/plan/09 §3.4-3.5):
## the running Hazard's flavor line sits under its name, and the debt line is Moe's ledger.

const ROUND_CASH := [&"shot", &"tip", &"scratch", &"off_table", &"world"]  ## Cash reasons that make up a Round's result
const REASONS := {&"timer": "Time up", &"cleared": "Table cleared", &"shots": "Out of shots"}
const MAX_DRINK_LINES := 3
const HYPE_STEP := 5

@export var game_loop: GameLoop
@export var economy: EconomyManager
@export var stream: StreamManager
@export var effects: EffectManager

var _ask := 0  ## this Night's demand, from night_started
var _viewers := 0
var _hype_pct := 0
var _last := ""  ## the finished Round: reason, points, Cash
var _round_cash := 0
var _counting := false  ## Cash since the Round began still counts towards `_last`

@onready var _slate: ShaderMaterial = $Slate.get_surface_override_material(0)
@onready var _header: Label3D = %Header
@onready var _viewers_label: Label3D = %Viewers
@onready var _hype_label: Label3D = %Hype
@onready var _hazard: Label3D = %Hazard
@onready var _hazard_story: Label3D = %HazardStory
@onready var _hazard_icon: Sprite3D = %HazardIcon
@onready var _drinks: Label3D = %Drinks
@onready var _footer: Label3D = %Footer


func _ready() -> void:
	if game_loop != null:
		game_loop.night_started.connect(_on_night_started)
		game_loop.round_started.connect(_on_round_started)
		game_loop.round_ended.connect(_on_round_ended)
		game_loop.state_changed.connect(_refresh_header)
	if economy != null:
		economy.cash_changed.connect(_on_cash_changed)
	if stream != null:
		stream.viewers_changed.connect(_on_viewers)
		_on_viewers(stream.viewers, stream.hype)
	if effects != null:
		effects.live_changed.connect(_refresh_live)
	_refresh_header()
	_refresh_live()
	_refresh_footer()


func _on_night_started(_night_number: int, quota: int) -> void:
	_ask = quota
	_last = ""
	_counting = false
	_refresh_header()
	_refresh_footer()


func _on_round_started(_round_index: int, _time_limit: float, _hazard_tier: int) -> void:
	_round_cash = 0
	_counting = true


func _on_round_ended(reason: StringName, round_points: int) -> void:
	_last = "%s · %d pts" % [REASONS.get(reason, reason), round_points]
	_refresh_footer()


func _on_cash_changed(_balance: int, delta: int, reason: StringName) -> void:
	if _counting and ROUND_CASH.has(reason):
		_round_cash += delta
	_refresh_footer()  # the ledger's "paid so far" follows the purse; a label is only rewritten when its text changed


func _on_viewers(viewers: int, hype: float) -> void:
	var pct := roundi(hype * 100.0 / HYPE_STEP) * HYPE_STEP
	if viewers != _viewers or pct != _hype_pct:
		_viewers = viewers
		_hype_pct = pct
		_write(_viewers_label, "VIEWERS %d" % _viewers)
		_write(_hype_label, "HYPE %d%%" % _hype_pct)
		_slate.set_shader_parameter(&"hype", _hype_pct / 100.0)


func _refresh_header() -> void:
	if game_loop == null or game_loop.nights.is_empty():
		return
	var config := game_loop.current_night()
	var text := "NIGHT %d" % config.night_number
	match game_loop.phase:
		GameLoop.Phase.NIGHT_START, GameLoop.Phase.INTERMISSION:
			text += "  ·  NEXT ROUND %d/%d" % [game_loop.round_index + 1, config.rounds_count]
		GameLoop.Phase.RECKONING:
			text += "  ·  RECKONING"
		GameLoop.Phase.GAME_OVER:
			text = "GAME OVER"
		GameLoop.Phase.CAMPAIGN_WON:
			text = "CAMPAIGN WON"
		_:
			text += "  ·  ROUND %d/%d" % [game_loop.round_index, config.rounds_count]
	_write(_header, text)


## The Event and Drinks in effect. Both are mirrored on every peer, so every peer's board agrees.
func _refresh_live() -> void:
	if effects == null:
		return
	var live := effects.live_events()
	var events: Array[String] = []
	for e in live:
		events.append(e.display_name)
	_write(_hazard, ", ".join(events) if not events.is_empty() else "none")
	_write(_hazard_story, live[0].story_line if not live.is_empty() else "")
	_hazard_icon.visible = not live.is_empty()
	if not live.is_empty():
		_hazard_icon.texture = IconCatalog.hazard(live[0])
	var drinks := effects.live_drinks()
	var shown := drinks.slice(0, MAX_DRINK_LINES if drinks.size() <= MAX_DRINK_LINES else MAX_DRINK_LINES - 1)
	var lines: Array[String] = []
	for d: Dictionary in shown:
		lines.append("%s · %s%s" % [d.drink.display_name, _name_of(d.peer_id), " (gift)" if d.gift else ""])
	if drinks.size() > shown.size():
		lines.append("+%d more" % (drinks.size() - shown.size()))
	_write(_drinks, "DRINKS  none" if lines.is_empty() else "DRINKS\n" + "\n".join(lines))


func _refresh_footer() -> void:
	var last := "none yet"
	if not _last.is_empty():
		last = "%s · %s$%d" % [_last, "+" if _round_cash >= 0 else "-", absi(_round_cash)]
	_write(_footer, "LAST ROUND  %s\n%s" % [last, ledger()])


## Moe's ledger (09 §3.5): the Night's demand and what the crew has paid so far; the Buyout and the Endless rate worded as Moe would.
## Cash can be negative after a scratch fine, and the ledger shows it as it is.
func ledger() -> String:
	if game_loop != null and game_loop.is_final_night():
		return "THE BUYOUT · %s · LAST CALL" % money(_ask)
	if game_loop != null and not game_loop.nights.is_empty() and game_loop.night_index >= game_loop.nights.size():
		return "MOE RAISED THE RATE · %s" % money(_ask)
	return "MOE WANTS %s · PAID SO FAR %s" % [money(_ask), money(economy.cash if economy != null else 0)]


## $1,350 / -$25: thousands grouped, the sign in front of the dollar sign.
static func money(amount: int) -> String:
	var digits := str(absi(amount))
	var out := ""
	for i in digits.length():
		out += digits[i]
		var left := digits.length() - 1 - i
		if left > 0 and left % 3 == 0:
			out += ","
	return ("-$" if amount < 0 else "$") + out


## Label3D rebuilds its mesh on every assignment, even of the same text: write only a change.
func _write(label: Label3D, text: String) -> void:
	if label.text != text:
		label.text = text


func _name_of(peer_id: int) -> String:
	var net := get_node_or_null(^"/root/NetManager")  # by path: `-s` probes compile before autoload names exist
	if net != null:
		for e: Dictionary in net.call(&"get_roster"):
			if e.peer_id == peer_id:
				return str(e.get("name", "Crew"))
	return "Crew"
