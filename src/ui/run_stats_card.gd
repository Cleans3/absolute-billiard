class_name RunStatsCard
extends Control
## The end-of-run card (docs/plan/02 §3.11): at most MAX_ROWS stat rows in a scroll list, the D–S+ grade big at the bottom.
## Shows a RunStats snapshot (`GameLoop.run_stats.to_dict()`); it opens nothing by itself: the ending that wants it
## instances this scene, calls show_stats() and frees it. Presentation only.

signal closed  ## the optional Close button

const SCENE_PATH := "res://src/ui/RunStatsCard.tscn"  # loaded on demand: the scene references this script, so a preload would be a cycle
const MAX_ROWS := 8
const GRADE_COLORS := {
	"D": Color("FF5A5A"), "C": Color("FFA23D"), "B": Color("F4EAD3"), "A": Color("5BE08A"), "S": Color("3DE0FF"), "S+": Color("F2D98B"),
}

var _stats := {}
var _title_text := "Run over"
var _closable := false
var _shown := false

@onready var _title: Label = %Title
@onready var _rows: VBoxContainer = %Rows
@onready var _scroll: ScrollContainer = %Scroll
@onready var _grade: Label = %Grade
@onready var _close: Button = %Close


func _ready() -> void:
	_close.pressed.connect(func() -> void: closed.emit())
	if _shown:
		_build()


## A new card to add to the tree and fill with show_stats().
static func make() -> RunStatsCard:
	return (load(SCENE_PATH) as PackedScene).instantiate() as RunStatsCard


## `stats` is RunStats.to_dict(); `closable` adds a Close button (the debug hook uses it, an ending does not).
func show_stats(stats: Dictionary, title := "Run over", closable := false) -> void:
	_stats = stats
	_title_text = title
	_closable = closable
	_shown = true
	if is_node_ready():
		_build()


## [label, value] per row, in card order: progress first, the grudges last. Exactly MAX_ROWS; a longer list is a design change.
static func rows(d: Dictionary) -> Array[PackedStringArray]:
	return [
		PackedStringArray(["Nights cleared", str(int(d.get("nights_cleared", 0)))]),
		PackedStringArray(["Balls potted", str(int(d.get("pots", 0)))]),
		PackedStringArray(["Best combo", "x%d" % int(d.get("best_combo", 0))]),
		PackedStringArray(["Trick shots", str(int(d.get("trick_shots", 0)))]),
		PackedStringArray(["Biggest shot", Blackboard.money(int(d.get("best_shot", 0)))]),
		PackedStringArray(["Cash earned", Blackboard.money(int(d.get("cash_earned", 0)))]),
		PackedStringArray(["Scratches", "%d  (fines %s)" % [int(d.get("scratches", 0)), Blackboard.money(int(d.get("fines_paid", 0)))]]),
		PackedStringArray(["Time played", format_time(float(d.get("play_time", 0.0)))]),
	]


## 7:05 under an hour, 1:07:05 over it.
static func format_time(sec: float) -> String:
	var t := maxi(int(sec), 0)
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]


func _build() -> void:
	_title.text = _title_text
	_close.visible = _closable
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for r in rows(_stats):
		var line := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = r[0]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var value_label := Label.new()
		value_label.text = r[1]
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.theme_type_variation = &"Heading"
		line.add_child(name_label)
		line.add_child(value_label)
		_rows.add_child(line)
	_scroll.scroll_vertical = 0
	var grade := RunStats.grade_of(_stats)
	_grade.text = grade
	_grade.add_theme_color_override(&"font_color", GRADE_COLORS[grade])
