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
	NetManager.all_peers_ready.connect(_start)
	$EconomyManager.cue_spec_changed.connect(_on_cue_spec)
	NetManager.main_level_ready()


## The walker's cue talks to this peer's RoundDirector (SYNC replaces `gate` with the shot route).
func _on_local_player(player: CharacterBody3D) -> void:
	var cue := player.get_node("Head/CueController")
	round_director.cue = cue
	cue.set(&"gate", round_director.can_strike)
	cue.set(&"cue_spec", $EconomyManager.build_cue_spec())


## Host: a Lobby-chosen checkpoint resumes the campaign (SaveManager.pending_resume), else a fresh one.
func _start() -> void:
	var resume := SaveManager.take_resume()
	if resume != null:
		game_loop.resume_from(resume)
	else:
		game_loop.start_campaign()


## Shop cue upgrades reach this peer's cue until PhysicsSim.active_cue is the strike's source.
func _on_cue_spec(spec: CueSpec) -> void:
	var player: Node = $PlayerSpawner.get_local_player()
	var cue := player.get_node_or_null("Head/CueController") if player != null else null
	if cue != null:
		cue.set(&"cue_spec", spec)
