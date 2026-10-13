class_name Bar
extends Node3D
## Places the Interactable props (docs/plan/03 §3.7). Greybox positions [tune]; PERF owns the visuals.
## `lean_on_rail` target_id = 1 + index in Stats.RAILS.

const REACH_ZONE_RADIUS := 1.2
const SEAT_ZONE_RADIUS := 0.7
const STOOL_TOP := 0.808  ## build_bar_room.gd's stool seat height
const SOFA_TOP := 0.46    ## the lounge sofa's cushion: the model's 0.23 at decor scale 2.0 (decor_plan.gd, loungeSofa)
const PEDESTAL := preload("res://src/gameplay/bar/GoLivePedestal.tscn")
const GO_LIVE_AT := Vector3(-3.7, 0.0, -1.0)  ## beside the table's south-west corner (table centre (0, 0, -3.5))
const PHONE_PROP_AT := Vector3(6.1, 0.0, 3.5)  ## the aisle behind the counter, in front of the phone (09 §2.2)
const PHONE_AT := Vector3(6.8, 1.28, 3.5)  ## the phone on the back-bar panel (x 6.8 face), between the cabinet and the low shelf
const JUKEBOX_AT := Vector3(6.55, 1.1, 5.8)  ## the baked jukebox's body (build_bar_room.gd `_jukebox`): where its music comes from
const SLOT_AT := Vector3(-6.3, 0.0, 1.5)  ## the slot machine's footprint centre, against the west wall; its front faces +X (docs/plan/02 §3.9)
## Sittable seats (06 P33 U7, local Interactables of kind `sit`, not in PROPS: they are not host prompts and the decor keep-clear
## list is made from PROPS). [id, floor point, Player yaw the sitter faces, seat top]. The counter stools (build_bar_room.gd STOOL_X)
## face the counter (+X), the table stools face their table, each lounge sofa (decor_plan.gd) seats two facing into the room (+Z).
const SEATS: Array = [
	[&"stool_counter_1", Vector3(4.3, 0.0, 1.0), -PI / 2.0, STOOL_TOP],
	[&"stool_counter_2", Vector3(4.3, 0.0, 2.0), -PI / 2.0, STOOL_TOP],
	[&"stool_counter_3", Vector3(4.3, 0.0, 3.0), -PI / 2.0, STOOL_TOP],
	[&"stool_counter_4", Vector3(4.3, 0.0, 4.0), -PI / 2.0, STOOL_TOP],
	[&"stool_table_1e", Vector3(-4.45, 0.0, 2.6), PI / 2.0, STOOL_TOP],
	[&"stool_table_1w", Vector3(-5.95, 0.0, 2.6), -PI / 2.0, STOOL_TOP],
	[&"stool_table_2e", Vector3(-4.45, 0.0, 4.4), PI / 2.0, STOOL_TOP],
	[&"stool_table_2w", Vector3(-5.95, 0.0, 4.4), -PI / 2.0, STOOL_TOP],
	[&"stool_table_3e", Vector3(-2.05, 0.0, 5.6), PI / 2.0, STOOL_TOP],
	[&"stool_table_3w", Vector3(-3.55, 0.0, 5.6), -PI / 2.0, STOOL_TOP],
	[&"sofa_ne_1", Vector3(5.1, 0.0, -6.55), PI, SOFA_TOP],
	[&"sofa_ne_2", Vector3(6.1, 0.0, -6.55), PI, SOFA_TOP],
	[&"sofa_nw_1", Vector3(-6.1, 0.0, -6.55), PI, SOFA_TOP],
	[&"sofa_nw_2", Vector3(-5.1, 0.0, -6.55), PI, SOFA_TOP],
]
# [interaction id or bar kind, position, target_id, prompt]
const PROPS: Array = [
	[&"bump_table", Vector3(0.0, 0.0, -1.2), 0, "Bump the table"],
	[&"kick_stool", Vector3(0.0, 0.0, 0.0), 0, "Kick the stool"],
	[&"jukebox", Vector3(6.3, 0.0, 5.8), 0, "Jukebox"],
	[&"flick_lights", Vector3(-6.3, 0.0, 5.8), 0, "Flick the lights"],
	[&"lean_on_rail", Vector3(-3.44, 0.0, -3.5), 1, "Lean on the rail"],  # rail_w
	[&"lean_on_rail", Vector3(3.44, 0.0, -3.5), 2, "Lean on the rail"],  # rail_e
	[&"lean_on_rail", Vector3(-1.3, 0.0, -5.67), 3, "Lean on the rail"],  # rail_n_w
	[&"lean_on_rail", Vector3(1.3, 0.0, -5.67), 4, "Lean on the rail"],  # rail_n_e
	[&"lean_on_rail", Vector3(-1.3, 0.0, -1.33), 5, "Lean on the rail"],  # rail_s_w
	[&"lean_on_rail", Vector3(1.3, 0.0, -1.33), 6, "Lean on the rail"],  # rail_s_e
	[&"heckle", Vector3(-5.0, 0.0, 3.5), 0, "Heckle"],
	[&"chalk_the_cue", Vector3(2.4, 0.0, -1.2), 0, "Chalk the cue"],
	[&"go_live", GO_LIVE_AT, 0, "GO LIVE"],  # no WorldInteraction resource: GameLoop.toggle_ready (02 §3.1)
	[&"answer_phone", PHONE_PROP_AT, 0, "Answer the phone"],  # no WorldInteraction resource: StoryDirector (09 §3.2)
	[&"slot_spin", SLOT_AT, 0, "Play the slots"],  # no WorldInteraction resource: SlotHouse (02 §3.9); SlotProp opens the SlotScreen
	# the counter props: customer side of the counter (x 4.7-5.5), the bartender stands behind it at (6.0, 0, 2.5)
	[&"throw_drink", Vector3(4.2, 0.0, 2.5), 0, "Throw a drink"],
	[&"bar_buy", Vector3(4.2, 0.0, 2.5), 0, "Buy a drink"],
	[&"bar_serve", Vector3(4.2, 0.0, 2.5), 0, "Serve a drink"],
]


func _ready() -> void:
	for spec: Array in PROPS:
		var prop: Interactable = SlotProp.new() if spec[0] == SlotHouse.PROP_KIND else (JukeboxProp.new() if spec[0] == &"jukebox" else Interactable.new())
		prop.interaction = FxCatalog.interaction(spec[0])
		if prop.interaction == null:
			prop.kind = spec[0]
		prop.target_id = spec[2]
		prop.prompt = spec[3]
		prop.position = spec[1]
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = REACH_ZONE_RADIUS
		shape.shape = sphere
		prop.add_child(shape)
		add_child(prop)
		if spec[0] == &"go_live":
			_add_pedestal(prop)
		elif spec[0] == &"answer_phone":
			_add_phone(prop)
		elif spec[0] == SlotHouse.PROP_KIND:
			_add_slot()
		elif spec[0] == &"jukebox":
			_add_jukebox()
	_add_seats()


## One local `sit` Interactable per SEATS row (06 P33 U7): `Player.sit_on` reads the seat from it, a puppet finds its seat's height there.
func _add_seats() -> void:
	for row: Array in SEATS:
		var seat := Interactable.new()
		seat.name = String(row[0])
		seat.kind = Interactable.SIT
		seat.prompt = "Sit"
		seat.position = row[1]
		seat.seat_yaw = row[2]
		seat.seat_top = row[3]
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = SEAT_ZONE_RADIUS
		shape.shape = sphere
		seat.add_child(shape)
		add_child(seat)


## The visible button + ready list at the go_live prop's spot (its labels billboard, so it needs no facing).
func _add_pedestal(prop: Interactable) -> void:
	var pedestal: GoLivePedestal = PEDESTAL.instantiate()
	pedestal.position = prop.position
	pedestal.game_loop = get_node_or_null(^"../GameLoop") as GameLoop
	pedestal.prop = prop
	add_child(pedestal)


## The slot machine on the prop's spot: a dynamic prop, not in the lightmap. Yaw 90: its +Z front faces +X, into the room.
func _add_slot() -> void:
	var machine := SlotMachine.new()
	machine.position = SLOT_AT
	machine.rotation.y = PI / 2.0
	add_child(machine)


## The jukebox's music: one node at the baked jukebox, on every peer (its three @rpc ride this path; docs/plan/04 §5).
func _add_jukebox() -> void:
	var box := JukeboxPlayer.new()
	box.name = "Jukebox"
	box.position = JUKEBOX_AT
	box.game_loop = get_node_or_null(^"../GameLoop") as GameLoop
	box.world = get_node_or_null(^"../WorldInteractions") as WorldInteractions
	add_child(box)


## The wall phone itself; the prop on the floor is its use target while it rings. Faces -X, into the room.
func _add_phone(prop: Interactable) -> void:
	var phone := Phone.new()
	phone.position = PHONE_AT
	phone.rotation.y = -PI / 2.0
	add_child(phone)
	phone.bind_prop(prop)
