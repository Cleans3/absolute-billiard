class_name BallType
extends Resource

@export var id: String
@export var display_name: String
@export var color := Color.WHITE
@export var base_value := 0
@export var behaviour_tags: Array[StringName] = []
@export var mass_multiplier := 1.0
@export var radius_multiplier := 1.0
@export var counts_for_clear := true
