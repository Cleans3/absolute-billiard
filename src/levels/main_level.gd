extends Node3D
## Session root (docs/plan/04 §4). Owns nothing but the kick-off: NetManager has already installed
## the peer when this scene loads, so the host starts the campaign. "New campaign" = reload this scene.

const NIGHTS: Array[NightConfig] = [
	preload("res://src/resources/nights/night_1.tres"),
	preload("res://src/resources/nights/night_2.tres"),
	preload("res://src/resources/nights/night_3.tres"),
	preload("res://src/resources/nights/night_4.tres"),
	preload("res://src/resources/nights/night_5.tres"),
]

@onready var game_loop: GameLoop = $GameLoop


func _ready() -> void:
	game_loop.nights = NIGHTS
	if game_loop.is_host():
		game_loop.start_campaign()
