class_name BartenderChat
extends Node
## Director of the Bartender's unprompted talk (C4, 06 P21). Ambient lines on a timer, weighted by the phase and the
## purse; reactions to the play (scratch, foul, miss, pot, trick shot) a beat after the shot settles. Lines come from
## `BartenderLines` through a shuffle bag per pool, so nothing repeats until a pool is used up and never back to back.
## Everything here is cosmetic and local: each peer runs its own director; reactions are seeded by the shot so most
## peers hear the same remark.

signal said(text: String, pool: StringName)

const FIRST_SEC := Vector2(5.0, 8.0)       ## first ambient line after the room loads
const AMBIENT_SEC := Vector2(11.0, 19.0)
const REACT_DELAY_SEC := Vector2(0.9, 1.8)
const GAP_SEC := 1.0                       ## silence after a line
const RECENT_MAX := 12                     ## lines not repeated while a fresh one exists
const LOW_SHARE := 0.35                    ## Cash under this share of the quota counts as behind
const REACT_CHANCE := {&"neg_scratch": 1.0, &"pos_trick": 1.0, &"neg_foul": 0.75, &"pos_pot": 0.45, &"neg_miss": 0.55}
const PRIORITY := {&"neg_scratch": 3, &"pos_trick": 3, &"neg_foul": 2, &"pos_pot": 1, &"neg_miss": 1}

var rng := RandomNumberGenerator.new()

var _economy: EconomyManager
var _loop: GameLoop
var _rd: Node                              ## RoundDirector
var _bags := {}                            ## pool -> Array[int]: lines not yet drawn this lap
var _recent: Array[String] = []            ## raw templates, newest last
var _ambient_in := 0.0
var _busy := 0.0                           ## the line being shown + GAP_SEC
var _queued := &""
var _queued_in := 0.0
var _queued_seed := 0
var _shooter := 0
var _shot_seed := 1                        ## of the shot being resolved: peers seeded alike pick alike
var _last_scratch_msec := -100000


func _ready() -> void:
	rng.randomize()
	_ambient_in = rng.randf_range(FIRST_SEC.x, FIRST_SEC.y)


## Wire to the level's nodes by name (all optional: a probe can stand in any of them).
func bind(level: Node) -> void:
	_economy = level.get_node_or_null("EconomyManager") as EconomyManager
	_loop = level.get_node_or_null("GameLoop") as GameLoop
	_rd = level.get_node_or_null("RoundDirector")
	if _economy != null:
		_economy.fined.connect(_on_fined)
	if _rd != null:
		_rd.connect(&"shot_started", _on_shot_started)
		_rd.connect(&"shot_ended", _on_shot_ended)
	if _loop != null:
		_loop.intermission_started.connect(_on_intermission)


func _process(delta: float) -> void:
	_busy = maxf(0.0, _busy - delta)
	if _queued != &"":
		_queued_in -= delta
		if _queued_in <= 0.0 and _busy <= 0.0:
			var pool := _queued
			_queued = &""
			say(pool, _queued_seed)
		return
	_ambient_in -= delta
	if _ambient_in <= 0.0 and _busy <= 0.0:
		_ambient_in = rng.randf_range(AMBIENT_SEC.x, AMBIENT_SEC.y)
		say(_ambient_pool())


# --- reactions ---------------------------------------------------------------------------------------

func _on_shot_started(shot_id: String, shooter_id: int) -> void:
	_shooter = shooter_id
	_shot_seed = hash(shot_id)


## P16: the scratch fine reaches every peer; it is the scratch signal (a plain foul is `shot_ended`'s).
func _on_fined(reason: StringName, _amount: int) -> void:
	if reason == &"scratch":
		_last_scratch_msec = Time.get_ticks_msec()
		react(&"neg_scratch", _shot_seed)


func _on_shot_ended(shot_id: String, _shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool) -> void:
	var pool := &"neg_miss"
	if foul:
		pool = &"neg_foul"
	elif not trick_ids.is_empty():
		pool = &"pos_trick"
	elif raw_points > 0:
		pool = &"pos_pot"
	if foul and Time.get_ticks_msec() - _last_scratch_msec < 3000:
		return  # the scratch line already covers it
	react(pool, hash(shot_id))


func _on_intermission() -> void:
	_ambient_in = minf(_ambient_in, rng.randf_range(2.0, 4.0))  # people are at the counter: sell something


## A reaction line, a beat later. One waits at a time; a higher priority replaces a lower one, a chance gates the mild ones.
func react(pool: StringName, seed: int) -> void:
	if rng.randf() > float(REACT_CHANCE.get(pool, 1.0)):
		return
	if _queued != &"" and int(PRIORITY[pool]) < int(PRIORITY[_queued]):
		return
	_queued = pool
	_queued_seed = seed if seed != 0 else 1
	_queued_in = rng.randf_range(REACT_DELAY_SEC.x, REACT_DELAY_SEC.y)


# --- picking -----------------------------------------------------------------------------------------

func say(pool: StringName, seed := 0) -> void:
	if pool == &"special" and shelf_names().is_empty():
		pool = &"pitch"
	var text := pick(pool, seed)
	_busy = line_seconds(text) + GAP_SEC
	said.emit(text, pool)


## The next line of a pool with its tokens filled. `seed` != 0 picks by that number (reactions) instead of the bag.
func pick(pool: StringName, seed := 0) -> String:
	var lines: Array = BartenderLines.POOLS[pool]
	var i := -1
	if seed != 0:
		i = absi(seed) % lines.size()
		for _n in lines.size():
			if not _recent.has(lines[i]):
				break
			i = (i + 1) % lines.size()
	else:
		i = _draw(pool, lines)
	_recent.append(lines[i])
	if _recent.size() > RECENT_MAX:
		_recent.pop_front()
	return _fill(lines[i])


func _draw(pool: StringName, lines: Array) -> int:
	var bag: Array = _bags.get(pool, [])
	if bag.is_empty():
		bag = range(lines.size())
		bag.shuffle()
	var i := -1
	for k in range(bag.size() - 1, -1, -1):
		if not _recent.has(lines[bag[k]]):
			i = bag[k]
			bag.remove_at(k)
			break
	if i < 0:
		i = bag.pop_back()
	_bags[pool] = bag
	return i


func _fill(template: String) -> String:
	var text := template
	if text.contains("{drink}"):
		var names := shelf_names()
		text = text.replace("{drink}", names[rng.randi() % names.size()] if not names.is_empty() else "house special")
	if text.contains("{who}"):
		text = text.replace("{who}", _who())
	if _economy != null:
		text = text.replace("{cash}", "$%d" % _economy.cash)
	if _loop != null and _loop.current_night() != null:
		text = text.replace("{quota}", "$%d" % _loop.current_night().quota)
	return text.replace("{cash}", "your purse").replace("{quota}", "the quota")


func _who() -> String:
	if _shooter == 0 or _shooter == multiplayer.get_unique_id():
		return "you"
	var net := get_tree().root.get_node_or_null(^"NetManager")
	if net != null:
		for e: Dictionary in net.get_roster():
			if e.peer_id == _shooter:
				return String(e.name)
	return "somebody"


## Display names of the Drinks still on the shelf: what "special of the day" may name.
func shelf_names() -> PackedStringArray:
	var out := PackedStringArray()
	if _economy == null:
		return out
	for i in _economy.stock_size():
		var d := FxCatalog.drink(_economy.stock_id(i))
		if d != null and _economy.stock_left(i) > 0:
			out.append(d.display_name)
	return out


func _ambient_pool() -> StringName:
	var intermission := _loop != null and _loop.phase == GameLoop.Phase.INTERMISSION
	var weights := {
		&"pep": 2.0 if intermission else 4.0,
		&"pitch": 4.0 if intermission else 2.0,
		&"special": (3.0 if intermission else 1.0) if not shelf_names().is_empty() else 0.0,
	}
	var cash := _cash_state()
	if cash != &"":
		weights[cash] = 2.5
	var total := 0.0
	for w: float in weights.values():
		total += w
	var roll := rng.randf() * total
	for pool: StringName in weights:
		roll -= weights[pool]
		if roll <= 0.0:
			return pool
	return &"pep"


## cash_low when the purse is well under the ask, cash_high once it is covered; else nothing to remark on.
func _cash_state() -> StringName:
	if _economy == null or _loop == null or _loop.current_night() == null:
		return &""
	var quota := _loop.current_night().quota
	if quota <= 0:
		return &""
	if _economy.cash >= quota:
		return &"cash_high"
	return &"cash_low" if _economy.cash < quota * LOW_SHARE else &""


## How long a line stays up and talks.
static func line_seconds(text: String) -> float:
	return clampf(1.6 + text.length() * 0.05, 2.6, 7.0)
