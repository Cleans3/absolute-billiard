extends Node3D
## Session root (docs/plan/04 §4). Owns nothing but the kick-off: NetManager has already installed
## the peer when this scene loads, so the host starts the campaign (after the intro cutscene, 09 §3.8.1). "New campaign" = reload this scene.

const NIGHTS: Array[NightConfig] = [
	preload("res://src/resources/nights/night_1.tres"),
	preload("res://src/resources/nights/night_2.tres"),
	preload("res://src/resources/nights/night_3.tres"),
]  # the Campaign; Endless continues past them (GameLoop.night_at)

@onready var game_loop: GameLoop = $GameLoop
@onready var round_director: RoundDirector = $RoundDirector
@onready var cutscenes: CutsceneDirector = $CutsceneDirector


func _ready() -> void:
	game_loop.nights = NIGHTS
	$PlayerSpawner.local_player_spawned.connect(_on_local_player)
	NetManager.all_peers_ready.connect(_start)
	$EconomyManager.cue_spec_changed.connect(_on_cue_spec)
	NetManager.main_level_ready()


## The walker's cue asks this peer's PhysicsSim for a shot; the host validates it (RoundDirector).
func _on_local_player(player: CharacterBody3D) -> void:
	(player as Player).bind(self)
	(player as Player).mode_changed.connect(Callable($UILayer/HUD, &"on_player_mode"))
	var cue := player.get_node("Head/CueController")
	cue.set(&"shot_sink", round_director.table.sim.request_shot)
	cue.set(&"cue_spec", $EconomyManager.build_cue_spec())


## Host: a Lobby-chosen checkpoint resumes the run (SaveManager.pending_resume, with its own mode; no intro), else a fresh one in the Lobby's
## mode: the intro plays on every peer first and the campaign starts when they have all seen it (CutsceneDirector.start_run).
func _start() -> void:
	var resume := SaveManager.take_resume()
	if resume != null:
		game_loop.resume_from(resume)
	else:
		cutscenes.start_run(func(seed_value: int) -> void: game_loop.start_campaign(GameLoop.pending_mode, seed_value))


## Shop cue upgrades reach this peer's cue until PhysicsSim.active_cue is the strike's source.
func _on_cue_spec(spec: CueSpec) -> void:
	var player: Node = $PlayerSpawner.get_local_player()
	var cue := player.get_node_or_null("Head/CueController") if player != null else null
	if cue != null:
		cue.set(&"cue_spec", spec)
