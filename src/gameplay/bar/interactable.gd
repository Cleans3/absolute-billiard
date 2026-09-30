class_name Interactable
extends Area3D
## A bar prop the crew can use (docs/plan/03 §3.7). The Player module calls try_use(); the host validates.

const LAYER := 1 << 5  # physics layer 6: interactables, for the Player's use-ray / overlap

@export var interaction: WorldInteraction
@export var kind := &""  # bar_buy / bar_serve: props that have no WorldInteraction resource
@export var target_id := 0  # rail id for `lean_on_rail`; 0 otherwise
@export var prompt := ""

var _cooldown_until_msec := 0


func _ready() -> void:
	add_to_group(&"interactable")
	collision_layer = LAYER
	collision_mask = 0
	monitoring = false


func effective_kind() -> StringName:
	return interaction.id if interaction != null else kind


## Local cooldown gate is for responsiveness only; the host decides. Returns false when nothing was sent.
func try_use(payload := {}) -> bool:
	var hub := get_tree().get_first_node_in_group(&"world_interactions") as WorldInteractions
	if hub == null or Time.get_ticks_msec() < _cooldown_until_msec:
		return false
	if interaction != null:
		_cooldown_until_msec = Time.get_ticks_msec() + int(interaction.cooldown_sec * 1000.0)
	hub.request(effective_kind(), target_id, payload)
	return true
