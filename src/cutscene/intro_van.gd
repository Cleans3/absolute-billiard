class_name IntroVan
extends Cutscene
## Intro, part 1 (docs/plan/09 §3.8, 06 P39): the back of the Rope's van at night, 2 s. The crew sits on the two side benches, hands
## tied, each in a gag, a blindfold or a hood (seeded per seat, CrewDress). The van rocks and hits bumps, a dome light flickers,
## headlights from behind and streetlamps sweep the faces. Camera: inside at the rear doors, drifting slowly in.

const LENGTH_SEC := 2.0
const SEAT_X := 0.74
const SEAT_Z: Array[float] = [-0.45, -0.45, 0.55, 0.55]  ## seats 0..3: left, right, left, right bench
const SEAT_Y := -0.42  ## Humanoid origin: its pelvis (bottom at 0.86) rests on the 0.44 bench top, the legs hide inside the bench

var _van: Node3D
var _crew: Array[Humanoid] = []
var _dome: OmniLight3D
var _beam: SpotLight3D
var _lamp: OmniLight3D
var _ph := PackedFloat32Array()  ## seeded phases
var _bumps := PackedFloat32Array()  ## seeded times of the road bumps


func id() -> StringName:
	return &"intro_van"


func length_sec() -> float:
	return LENGTH_SEC


func _environment() -> Environment:
	return CutsceneKit.night_env(Color.BLACK, Color(0.06, 0.06, 0.09), 1.0, Color.BLACK, 0.0)


func _build() -> void:
	fade_in = 0.35
	fade_out = 0.25
	for i in 12:
		_ph.append(rng.randf() * TAU)
	_bumps = PackedFloat32Array([rng.randf_range(0.25, 0.5), rng.randf_range(0.85, 1.1), rng.randf_range(1.45, 1.7)])
	_van = Node3D.new()
	_van.name = "Van"
	add_child(_van)
	_build_interior()
	_crew = CrewDress.spawn(_van, crew_size, crew_skins)
	for i in _crew.size():
		var side := -1.0 if i % 2 == 0 else 1.0
		_crew[i].position = Vector3(side * SEAT_X, SEAT_Y, SEAT_Z[i])
		_crew[i].rotation.y = side * PI * 0.5  # left bench faces +X, right bench faces -X: across the aisle
		CrewDress.dress(_crew[i], CrewDress.kind_for(cut_seed, i))
		CrewDress.tie_hands(_crew[i])
	_dome = CutsceneKit.omni(_van, Vector3(0.0, 1.62, 0.0), Color(1.0, 0.82, 0.55), 1.4, 3.6)
	_beam = CutsceneKit.spot(self, Vector3(0.0, 1.4, 2.4), Vector3(0.0, 0.9, -1.0), Color(0.85, 0.92, 1.0), 3.0, 7.0, 58.0)
	_lamp = CutsceneKit.omni(self, Vector3(-2.6, 1.6, 0.0), Color(1.0, 0.7, 0.35), 1.2, 4.0)
	CutsceneKit.omni(_van, Vector3(0.0, 1.2, -1.5), Color(0.35, 0.55, 0.7), 0.5, 2.6)  # the cab's glow through the bulkhead


func _build_interior() -> void:
	var s := CutsceneKit.Soup.new()
	s.box(Vector3(0.0, -0.05, 0.1), Vector3(1.0, 0.05, 1.9), Color("3a3a3e"))  # floor
	s.box(Vector3(0.0, 1.78, 0.1), Vector3(1.0, 0.04, 1.9), Color("77777c"))  # ceiling
	s.box(Vector3(-1.0, 0.9, 0.1), Vector3(0.04, 0.9, 1.9), Color("6b6e75"))  # walls
	s.box(Vector3(1.0, 0.9, 0.1), Vector3(0.04, 0.9, 1.9), Color("6b6e75"))
	s.box(Vector3(0.0, 0.9, -1.76), Vector3(1.0, 0.9, 0.04), Color("575a60"))  # bulkhead to the cab
	s.box(Vector3(0.0, 0.9, 1.98), Vector3(1.0, 0.9, 0.03), Color("4d4f55"))  # rear doors (behind the camera)
	for side in [-1.0, 1.0]:
		s.box(Vector3(side * 0.72, 0.22, 0.0), Vector3(0.27, 0.22, 1.25), Color("261a16"))  # benches
		s.box(Vector3(side * 0.72, 0.455, 0.0), Vector3(0.27, 0.015, 1.25), Color("34261e"))
		for z in [-1.2, 0.0, 1.2]:
			s.box(Vector3(side * 0.96, 0.9, z), Vector3(0.05, 0.88, 0.05), Color("4b4e55"))  # wall ribs
	for z in [-1.2, -0.4, 0.4, 1.2]:
		s.box(Vector3(0.0, 1.72, z), Vector3(1.0, 0.05, 0.05), Color("4b4e55"))  # roof beams
	s.box(Vector3(0.1, 0.2, -1.35), Vector3(0.34, 0.2, 0.28), Color("40321e"))  # a crate
	s.cyl(Vector3(-0.2, 0.0, -0.95), 0.12, Vector2(0.24, 0.24), Vector2(0.22, 0.22), 10, Color("8a7650"))  # a coil of rope
	CutsceneKit.add_mesh(_van, s.mesh(CutsceneKit.textured("metal", Color.WHITE, 1.6)))
	var glass := MeshInstance3D.new()  # the cab window, a dim blue square
	var quad := QuadMesh.new()
	quad.size = Vector2(0.55, 0.24)
	glass.mesh = quad
	glass.position = Vector3(0.0, 1.35, -1.715)
	glass.material_override = CutsceneKit.glow(Color(0.1, 0.2, 0.27))
	_van.add_child(glass)


func _update(time: float, _dt: float) -> void:
	var bob := 0.010 * sin(time * 9.0 + _ph[0]) + 0.006 * sin(time * 17.0 + _ph[1])
	var pitch := 0.006 * sin(time * 3.1 + _ph[4])
	var jolt := 0.0
	for b in _bumps:
		bob += CutsceneKit.bump(time, b, 0.035, 4.0, 7.0)
		pitch += CutsceneKit.bump(time, b + 0.02, 0.012, 3.0, 8.0)
		jolt += CutsceneKit.bump(time, b, 1.0, 4.0, 7.0)
	var roll := 0.012 * sin(time * 4.3 + _ph[2]) + 0.006 * sin(time * 11.0 + _ph[3])
	_van.position = Vector3(0.012 * sin(time * 6.2 + _ph[5]), bob, 0.0)
	_van.rotation = Vector3(pitch, 0.0, roll)
	for i in _crew.size():
		var hooded := CrewDress.kind_for(cut_seed, i) == CrewDress.Kind.HOOD
		var ph := _ph[6 + i]
		_crew[i].set_look(0.3 * sin(time * 1.3 + ph), (-0.1 if hooded else -0.28) + 0.05 * sin(time * 2.2 + ph) - 0.5 * jolt)
	var cam_pos := Vector3(0.012 * sin(time * 7.0 + _ph[10]), 1.28 + 0.008 * sin(time * 9.5), 1.62 - 0.2 * time)
	camera.transform = CutsceneKit.look_from(cam_pos, Vector3(0.0, 1.0, -0.9))
	camera.fov = 66.0 - 3.0 * time / LENGTH_SEC
	var dip := 0.2 if fposmod(time * 1.7 + _ph[8], 3.0) < 0.12 else 1.0
	_dome.light_energy = 1.4 * dip * (0.88 + 0.12 * sin(time * 23.0 + _ph[7]))
	_beam.light_energy = 3.0 * pow(maxf(0.0, sin(time * 2.6 + _ph[9])), 4.0)  # a car behind, its lights sweeping the faces
	_lamp.position = Vector3(-2.6, 1.6, 4.0 - fposmod(time * 3.5 + _ph[11], 1.0) * 8.0)  # streetlamps going by outside the wall
