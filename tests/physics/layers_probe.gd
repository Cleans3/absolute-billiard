extends SceneTree
## 07 §1 collision layers: balls 1, table 2, pockets 3, world 4; ball mask 1|2|3, so a world-layer body is invisible to balls.
##   godot --path . --headless -s tests/physics/layers_probe.gd

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var table: Table = TABLE.instantiate()
	root.add_child(table)
	await physics_frame
	assert((table.get_node("Bed") as StaticBody3D).collision_layer == 2, "bed on layer 2")
	for c in table.get_children():
		if c is StaticBody3D and c.has_meta(&"rail_id"):
			assert(c.collision_layer == 2 and c.collision_mask == 0, "rail on layer 2")
		if c is Area3D and c.has_meta(&"pocket_id"):
			assert(c.collision_layer == 4 and c.collision_mask == 1 and not c.monitorable, "pocket on layer 3, sees balls only")
	var b: Ball = BALL.instantiate()
	b.ball_type = CUE_T
	b.spec = table.spec
	root.add_child(b)
	assert(b.collision_layer == 1 and b.collision_mask == 7, "ball layer 1, mask 1|2|3")
	var player := (load("res://src/gameplay/player/Player.tscn") as PackedScene).instantiate() as CharacterBody3D
	assert(player.collision_layer == 8 and player.collision_mask == 10, "player on world layer, sees table + world")
	player.free()

	# a world-layer wall across the ball's path must not stop it
	var y := table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	b.global_position = Vector3(-1.0, y, 0)
	table.sim.register(b)
	var wall := StaticBody3D.new()
	wall.collision_layer = 8
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.05, 0.3, 0.6)
	cs.shape = box
	wall.add_child(cs)
	root.add_child(wall)
	wall.global_position = Vector3(-0.5, y, 0)
	await physics_frame
	b.linear_velocity = Vector3(2.0, 0, 0)
	for i in 90:
		await physics_frame
	assert(b.global_position.x > -0.4, "ball passed through the world-layer wall, x=%.2f" % b.global_position.x)
	print("LAYERS OK")
	quit()
