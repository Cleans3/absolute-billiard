class_name TruckOutro
extends Cutscene
## Campaign win, the ride out (docs/plan/09 §3.8, 06 P39 U17): at dawn the crew sits on crates on the bed of a flatbed truck, dazed.
## The truck is STATIONARY in the frame: the world scrolls past it (four recycled chunks of road, lane marks, trees and poles, a
## static ridge), the wheels spin, and the truck shakes: engine buzz, road bumps, roll and pitch, and small lane-change manoeuvres.
## It loops until the player presses Continue on the stats card (`finish()`, then the host sends everyone to the main menu). The
## ending text (`captions`) plays first as subtitles; Skip jumps to the card. The card is RunStatsCard in its compact form, docked
## along the bottom, the list scrollable, the grade at the bottom of it.
## Options: "stats" (RunStats.to_dict()), "captions" (Array[String], the Night's ending_cards), "title".

const CHUNK_LEN := 40.0
const CHUNKS := 4
const SPEED := 24.0  ## m/s the world slides back
const POLE_EVERY := 20.0
const DASH := 4.0  ## a lane dash and its gap are 4 m each
const CAPTION_START := 1.0
const CAPTION_SEC := 4.5
const CARD_AT_SEC := 2.6  ## when the card comes up if there are no captions
const SLIDE_SEC := 0.6
const LOOP_SEC := 20.0  ## bumps and manoeuvres repeat on this period
const WHEEL_R := 0.55
const ROAD_L := -6.8  ## road edges (x)
const ROAD_R := 2.2
const TREE_COUNT := 40

var stats := {}
var captions: Array[String] = []
var card_title := "Paid in full"

var _truck: Node3D
var _wheels: Array[Node3D] = []
var _chunks: Array[Node3D] = []
var _crew: Array[Humanoid] = []
var _card: RunStatsCard
var _card_at := 0.0
var _ph := PackedFloat32Array()
var _bumps := PackedFloat32Array()
var _moves := PackedFloat32Array()  ## manoeuvre start times within LOOP_SEC
var _move_amp := PackedFloat32Array()  ## lateral metres, signed


func id() -> StringName:
	return &"truck_outro"


func length_sec() -> float:
	return 0.0  # open-ended: ends on Continue


func configure(opts: Dictionary) -> void:
	super(opts)
	var snapshot: Variant = opts.get("stats", stats)
	stats = snapshot if snapshot is Dictionary else {}
	card_title = str(opts.get("title", card_title))
	var lines: Variant = opts.get("captions", null)
	if lines is Array:
		captions.clear()
		for l: Variant in lines:
			captions.append(str(l))


func _environment() -> Environment:
	# ambient 1.01: the old 110 m sun omni's share (it moved the picture by under 1 %), folded in
	return CutsceneKit.sky_env(Color(0.14, 0.18, 0.36), Color(0.98, 0.62, 0.42), Color(0.2, 0.17, 0.2), Color(0.42, 0.36, 0.4), 1.01, 0.012)


func _build() -> void:
	fade_in = 0.8
	fade_out = 0.0
	for i in 8:
		_ph.append(rng.randf() * TAU)
	for k in 6:
		_bumps.append(rng.randf_range(0.0, LOOP_SEC))
	for k in 3:
		_moves.append(LOOP_SEC / 3.0 * k + rng.randf_range(1.0, 3.5))
		_move_amp.append(rng.randf_range(0.28, 0.5) * (1.0 if rng.randf() < 0.5 else -1.0))
	_build_world()
	_build_truck()
	_build_sky()
	_build_crew()
	_build_card()
	_card_at = CAPTION_START + captions.size() * CAPTION_SEC + 0.5 if not captions.is_empty() else CARD_AT_SEC


# --- the world ----------------------------------------------------------------------------------------------------------------------

func _build_world() -> void:
	for i in CHUNKS:
		var s := CutsceneKit.Soup.new()
		var grass := Color("2c3320")
		s.box(Vector3(-45.0, -0.5, CHUNK_LEN * 0.5), Vector3(40.0, 0.5, CHUNK_LEN * 0.5), grass)  # fields and woods floor, far side
		s.box(Vector3(9.7, -0.5, CHUNK_LEN * 0.5), Vector3(4.3, 0.5, CHUNK_LEN * 0.5), grass)  # verge, near side (the camera stands on it)
		s.box(Vector3((ROAD_L + ROAD_R) * 0.5, -0.49, CHUNK_LEN * 0.5), Vector3((ROAD_R - ROAD_L) * 0.5, 0.5, CHUNK_LEN * 0.5), Color("2e2e33"))  # asphalt
		s.box(Vector3(3.8, -0.49, CHUNK_LEN * 0.5), Vector3(1.6, 0.5, CHUNK_LEN * 0.5), Color("4a4338"))  # gravel shoulder
		var line := Color("e8e0b0")
		s.box(Vector3(ROAD_R - 0.3, 0.015, CHUNK_LEN * 0.5), Vector3(0.07, 0.015, CHUNK_LEN * 0.5), Color("d8d8d8"))  # edge lines
		s.box(Vector3(ROAD_L + 0.3, 0.015, CHUNK_LEN * 0.5), Vector3(0.07, 0.015, CHUNK_LEN * 0.5), Color("d8d8d8"))
		var z := 0.0
		while z < CHUNK_LEN - 0.01:
			s.box(Vector3(-2.3, 0.015, z + DASH * 0.5), Vector3(0.07, 0.015, DASH * 0.5), line)  # the centre line, dashed
			z += DASH * 2.0
		var pz := 0.0
		while pz < CHUNK_LEN - 0.01:
			_pole(s, 3.7, pz + POLE_EVERY * 0.5)
			pz += POLE_EVERY
		for k in 10:  # roadside reflector posts, a quick flick past the camera
			s.box(Vector3(2.7, 0.45, 2.0 + k * 4.0), Vector3(0.04, 0.45, 0.04), Color("d9d9d0"))
		for k in TREE_COUNT:
			_pine(s, Vector3(rng.randf_range(-70.0, -9.0), 0.0, rng.randf_range(0.0, CHUNK_LEN)), rng.randf_range(1.2, 2.4), rng.randf())
		var chunk := Node3D.new()
		chunk.name = "Chunk%d" % i
		add_child(chunk)
		CutsceneKit.add_mesh(chunk, s.mesh())
		_chunks.append(chunk)
	var ridge := CutsceneKit.Soup.new()  # far hills: they do not scroll, which is what far things do
	for k in 8:
		ridge.cyl(Vector3(-170.0 + rng.randf_range(-12.0, 12.0), 0.0, -130.0 + 36.0 * k), rng.randf_range(16.0, 28.0), Vector2(46.0, 46.0), Vector2(2.0, 2.0), 7, Color(0.22, 0.2, 0.3).lightened(rng.randf_range(0.0, 0.12)), 0)
	CutsceneKit.add_mesh(self, ridge.mesh())


func _pole(s: CutsceneKit.Soup, x: float, z: float) -> void:
	var wood := Color("3b2c20")
	s.cyl(Vector3(x, 0.0, z), 7.6, Vector2(0.13, 0.13), Vector2(0.1, 0.1), 5, wood, 0)
	s.box(Vector3(x, 7.2, z), Vector3(0.05, 0.06, 0.9), wood)  # the cross-arm runs along the road


func _pine(s: CutsceneKit.Soup, at: Vector3, k: float, g: float) -> void:
	var leaf := Color(0.07 + 0.05 * g, 0.16 + 0.1 * g, 0.09 + 0.04 * g)
	s.cyl(at, 1.6 * k, Vector2(0.2 * k, 0.2 * k), Vector2(0.14 * k, 0.14 * k), 5, Color("2e2118"), 0)
	for i in 3:
		var w := (1.9 - 0.45 * i) * k
		s.cyl(at + Vector3(0.0, (1.0 + 1.15 * i) * k, 0.0), 1.9 * k, Vector2(w, w), Vector2.ZERO, 6, leaf.lightened(0.08 * i), 0)


func _build_sky() -> void:
	var sun := MeshInstance3D.new()
	var disc := SphereMesh.new()
	disc.radius = 6.0
	disc.height = 12.0
	disc.radial_segments = 16
	disc.rings = 8
	sun.mesh = disc
	sun.position = Vector3(-170.0, 24.0, -70.0)
	sun.material_override = CutsceneKit.glow(Color(1.0, 0.86, 0.55))
	sun.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sun)
	if QualityManager.current_tier < 1:  # a 32 m alpha sphere over the sky: tier 0 only (C6)
		var halo := MeshInstance3D.new()
		var big := SphereMesh.new()
		big.radius = 16.0
		big.height = 32.0
		big.radial_segments = 16
		big.rings = 8
		halo.mesh = big
		halo.position = sun.position
		var halo_mat := CutsceneKit.glow(Color(1.0, 0.7, 0.4))
		halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		halo_mat.albedo_color.a = 0.16
		halo.material_override = halo_mat
		halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(halo)
	# Two realtime lights on every tier (C6: 4 / 3 / 2, ranges <= 25 m). The 110 m sun omni that rimmed the crew from 50 m away is gone: its 1/d
	# falloff left it almost nothing there (hiding it moved the picture by 0.2 of 255, the sky fill by 1.4); the ambient carries it.
	CutsceneKit.omni(self, Vector3(8.0, 4.0, 3.0), Color(0.75, 0.8, 1.0), 1.3, 16.0)  # sky fill from the camera's side


# --- the truck ----------------------------------------------------------------------------------------------------------------------

func _build_truck() -> void:
	_truck = Node3D.new()
	_truck.name = "Truck"
	add_child(_truck)
	var s := CutsceneKit.Soup.new()
	var cab := Color("46586e")
	var dark := Color("17181c")
	var glass := Color("0d1218")
	var bed := Color("6d5238")
	s.box(Vector3(0.0, 1.15, 1.2), Vector3(1.25, 0.1, 3.2), bed)  # the deck, top at y 1.25
	s.box(Vector3(0.0, 0.8, 0.3), Vector3(1.0, 0.15, 4.9), dark)  # chassis
	s.box(Vector3(0.0, 1.95, -1.9), Vector3(1.2, 0.7, 0.08), Color("5a4430"))  # headboard behind the cab
	s.box(Vector3(0.0, 1.7, -3.1), Vector3(1.2, 0.95, 1.0), cab)  # cab
	s.box(Vector3(0.0, 1.25, -4.7), Vector3(1.15, 0.5, 0.6), cab)  # bonnet
	s.box(Vector3(0.0, 2.2, -4.1), Vector3(1.0, 0.4, 0.03), glass)  # windscreen
	s.box(Vector3(1.2, 2.2, -3.1), Vector3(0.03, 0.4, 0.55), glass)  # side window
	s.box(Vector3(1.2, 1.55, -3.1), Vector3(0.025, 0.5, 0.5), cab.darkened(0.12))  # door panel
	s.box(Vector3(0.0, 0.55, -5.4), Vector3(1.0, 0.12, 0.05), Color("a0a0a8"))  # front bumper
	s.box(Vector3(1.2, 1.45, 1.2), Vector3(0.04, 0.2, 3.2), Color("5a4430"))  # side board, the crew sits behind it
	s.box(Vector3(-1.2, 1.45, 1.2), Vector3(0.04, 0.2, 3.2), Color("5a4430"))
	s.box(Vector3(0.0, 1.45, 4.4), Vector3(1.2, 0.2, 0.04), Color("5a4430"))  # tailgate
	for z in [-1.7, 0.4, 2.5, 4.3]:
		s.box(Vector3(1.2, 1.7, z), Vector3(0.06, 0.45, 0.06), Color("3e2f21"))  # stakes
		s.box(Vector3(-1.2, 1.7, z), Vector3(0.06, 0.45, 0.06), Color("3e2f21"))
	# cargo and seats: one crate under each crew member, the rest of the load across the deck
	for i in MAX_CREW:
		s.box(Vector3(0.75, 1.5, _seat_z(i)), Vector3(0.4, 0.25, 0.43), Color("7a5a36").lightened(0.04 * i))
	s.box(Vector3(-0.6, 1.5, 0.2), Vector3(0.5, 0.25, 0.45), Color("6a4c30"))
	s.box(Vector3(-0.6, 1.85, 0.2), Vector3(0.45, 0.2, 0.4), Color("7a5a36"))
	s.box(Vector3(-0.6, 1.6, 2.6), Vector3(0.55, 0.35, 0.9), Color("3c4a3a"))  # a tarp-covered pile
	s.cyl(Vector3(-0.2, 1.25, 3.9), 0.18, Vector2(0.3, 0.3), Vector2(0.28, 0.28), 10, Color("8a7650"))  # a coil of rope
	# the far side's wheels never turn into view: static
	for z in [-4.3, 0.3, 1.9]:
		s.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(-1.5, 0.55, z))
		s.cyl(Vector3.ZERO, 0.4, Vector2(WHEEL_R, WHEEL_R), Vector2(WHEEL_R, WHEEL_R), 10, dark)
	s.xf = Transform3D.IDENTITY
	CutsceneKit.add_mesh(_truck, s.mesh())
	# the near side's wheels spin: one mesh, three nodes
	var w := CutsceneKit.Soup.new()
	w.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(-0.2, 0.0, 0.0))  # lies along X, centred on the pivot
	w.cyl(Vector3.ZERO, 0.4, Vector2(WHEEL_R, WHEEL_R), Vector2(WHEEL_R, WHEEL_R), 12, Color("0b0b0d"))
	w.cyl(Vector3.ZERO, 0.43, Vector2(0.3, 0.3), Vector2(0.3, 0.3), 10, Color("70747c"))
	w.xf = Transform3D.IDENTITY
	for k in 5:  # lug nuts on the hub's outer face, so the spin reads
		var a := TAU * k / 5.0
		w.box(Vector3(0.235, cos(a) * 0.2, sin(a) * 0.2), Vector3(0.025, 0.04, 0.04), Color("d6d6dc"))
	var wheel_mesh := w.mesh()
	for z in [-4.3, 0.3, 1.9]:
		var pivot := Node3D.new()
		pivot.position = Vector3(1.3, WHEEL_R, z)
		_truck.add_child(pivot)
		CutsceneKit.add_mesh(pivot, wheel_mesh)
		_wheels.append(pivot)
	# headlight glow on the world ahead is off-screen; a cab light keeps the door lit
	CutsceneKit.omni(_truck, Vector3(2.2, 2.4, -3.0), Color(1.0, 0.85, 0.65), 0.8, 4.0)


func _seat_z(i: int) -> float:
	return 3.3 - 1.05 * i


func _build_crew() -> void:
	_crew = CrewDress.spawn(_truck, crew_size, crew_skins)
	for i in _crew.size():
		_crew[i].position = Vector3(0.75, 1.75 - 0.86, _seat_z(i))  # the pelvis (bottom at 0.86) on the crate top; the legs hide in the crate
		_crew[i].rotation.y = -PI * 0.5  # facing the camera side (+X)
		_crew[i].set_hand(0, Vector3(0.2, 0.92, -0.3))  # hands on the lap
		_crew[i].set_hand(1, Vector3(-0.2, 0.92, -0.3))


func _build_card() -> void:
	_card = RunStatsCard.make()
	shell.dock.add_child(_card)
	_card.show_stats(stats, card_title, true, "Continue", true)
	_card.closed.connect(finish)
	_card.visible = false


# --- the timeline -------------------------------------------------------------------------------------------------------------------

## The stats card comes up now (Skip, before the captions have run out).
func skip() -> void:
	if playing and skippable and t < _card_at:
		_card_at = t
		clear_caption()


func _lane(time: float) -> float:
	var lateral := 0.0
	for k in _moves.size():
		var d := fposmod(time - _moves[k], LOOP_SEC)
		lateral += _move_amp[k] * smoothstep(0.0, 1.3, d) * (1.0 - smoothstep(2.4, 3.7, d))
	return lateral


func _jolt(time: float) -> float:
	var j := 0.0
	for b in _bumps:
		j += CutsceneKit.bump(fposmod(time - b, LOOP_SEC), 0.0, 0.03, 3.5, 6.0)
	return j


func _update(time: float, _dt: float) -> void:
	# the world slides back; the wheels roll
	for i in _chunks.size():
		_chunks[i].position.z = fposmod(i * CHUNK_LEN + SPEED * time, CHUNK_LEN * CHUNKS) - CHUNK_LEN * CHUNKS * 0.5
	for w in _wheels:
		w.rotation.x = -SPEED * time / WHEEL_R
	# the truck shakes
	var jolt := _jolt(time)
	var buzz := 0.006 * sin(time * 47.0 + _ph[0]) + 0.004 * sin(time * 31.0 + _ph[1])
	var bounce := 0.014 * sin(time * 13.0 + _ph[2]) + buzz + jolt
	var lane := _lane(time)
	var yaw := -(_lane(time + 0.05) - _lane(time - 0.05)) / 0.1 * 0.12 + 0.004 * sin(time * 1.7 + _ph[3])
	var roll := 0.012 * sin(time * 0.9 + _ph[4]) + 0.006 * sin(time * 2.3 + _ph[5]) + 0.5 * jolt
	var pitch := 0.008 * sin(time * 1.3 + _ph[6]) + 0.25 * jolt
	_truck.position = Vector3(lane, bounce, 0.0)
	_truck.rotation = Vector3(pitch, yaw, roll)
	# the crew rides it out: heads drop on the bumps, lazy looks around
	for i in _crew.size():
		var ph := _ph[(i + 2) % 8]
		var drowsy := -0.3 - 0.12 * float(i % 2)
		_crew[i].set_look(0.3 * sin(time * 0.4 + ph), drowsy + 0.05 * sin(time * 1.1 + ph) - 6.0 * bounce)
	# the camera: a handheld shot from the roadside, truck high in the frame so the bottom is free for the card
	var cam := Vector3(6.4 + 0.15 * sin(time * 0.3 + _ph[7]), 2.3 + 0.06 * sin(time * 0.5), 1.9 + 0.2 * sin(time * 0.23) + 0.01 * sin(time * 9.0))
	camera.transform = CutsceneKit.look_from(cam, Vector3(0.7, 0.1, 1.7))
	camera.fov = 56.0
	_update_overlay(time)


func _update_overlay(time: float) -> void:
	var line := ""
	if time >= CAPTION_START and time < _card_at:
		var k := int((time - CAPTION_START) / CAPTION_SEC)
		if k < captions.size() and time - CAPTION_START - k * CAPTION_SEC < CAPTION_SEC - 0.4:
			line = captions[k]
	if line == "":
		clear_caption()
	else:
		caption_line(line)
	var slide := smoothstep(_card_at, _card_at + SLIDE_SEC, time)
	_card.visible = time >= _card_at
	shell.dock.offset_top = -CutsceneShell.DOCK_HEIGHT * slide
	shell.dock.offset_bottom = CutsceneShell.DOCK_HEIGHT * (1.0 - slide)
	shell.skip_button.visible = skippable and time < _card_at
