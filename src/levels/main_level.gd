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
@onready var round_director: RoundDirector = $RoundDirector


func _ready() -> void:
	game_loop.nights = NIGHTS
	$PlayerSpawner.local_player_spawned.connect(_on_local_player)
	NetManager.all_peers_ready.connect(game_loop.start_campaign)
	NetManager.main_level_ready()


## The walker's cue asks this peer's PhysicsSim for a shot; the host validates it (RoundDirector).
func _on_local_player(player: CharacterBody3D) -> void:
	var cue := player.get_node("Head/CueController")
	cue.set(&"shot_sink", round_director.table.sim.request_shot)
