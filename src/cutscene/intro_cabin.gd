class_name IntroCabin
extends Cutscene
## Intro, part 2 (docs/plan/09 §3.8, 06 P39): the van brakes to a halt in a clearing, a cabin in the woods ahead with its porch light
## on, "GUS'S CORNER POCKET est. 1979" on a board; the engine dies, the headlights fade, and the cabin door swings open on a warm
## glow. It ends there (3 s). "Thrown into the bar, door locked" is MainLevel's (F3b). Night, fog, a moon, ~170 trees in one mesh.

const LENGTH_SEC := 3.0
const STOP_T := 1.5  ## the van is at rest from here
const V0 := 9.0  ## m/s when the shot opens
const STOP_Z := -3.0  ## where the van's middle comes to rest
const CABIN_Z := -15.0  ## the cabin's centre; it faces +Z
const FRONT_Z := -12.3  ## its front wall
const HALF_W := 3.5
const DOOR_AT := 1.9
const DOOR_SEC := 0.8
const DOOR_X := 0.55  ## half the doorway
const TREES := 170
const LOG_R := 0.17

var _van: Node3D
var _door: Node3D
var _head: SpotLight3D
var _tail_glow: OmniLight3D
var _tail_mat: StandardMaterial3D
var _porch: OmniLight3D
var _door_beam: SpotLight3D
var _tier := 0  ## QualityManager.current_tier, read once in _build
var _glow_mat: StandardMaterial3D
var _ph := PackedFloat32Array()


func id() -> StringName:
	return &"intro_cabin"


func length_sec() -> float:
	return LENGTH_SEC


func _environment() -> Environment:
	# ambient 1.02: the old 90 m moon omni's share (it moved the picture by 0.03 of 255), folded in
	return CutsceneKit.night_env(Color(0.008, 0.012, 0.026), Color(0.1, 0.12, 0.22), 1.02, Color(0.03, 0.045, 0.08), 0.025)


func _build() -> void:
	fade_in = 0.3
	fade_out = 0.35
	_tier = QualityManager.current_tier
	for i in 8:
		_ph.append(rng.randf() * TAU)
	_build_ground()
	_build_trees()
	_build_cabin()
	_build_porch()
	_build_van()
	_build_sky()
	# Realtime lights per tier (C6: 4 / 3 / 2, every range <= 25 m). Each hidden in turn moved the picture by (of 255, on average): the 90 m moon
	# omni 0.03, the omni inside the doorway 0.03, the door beam 0.2, the porch 0.3, the headlights 0.3, the brake glow 1.0. So the moon (its
	# disc and the ambient are the moonlight now) and the doorway omni are gone on every tier, the door beam on tier 1 (the porch takes its
	# glow), the headlights on tier 2 (the only pair that keeps 90 % of the luma while the van brakes is brake glow + porch).
	_porch = CutsceneKit.omni(self, Vector3(-1.2, 2.3, FRONT_Z + 2.3), Color(1.0, 0.72, 0.35), 2.2, 9.0)
	if _tier < 1:
		_door_beam = CutsceneKit.spot(self, Vector3(0.0, 1.4, FRONT_Z - 0.6), Vector3(0.0, 0.0, FRONT_Z + 6.0), Color(1.0, 0.65, 0.3), 0.0, 14.0, 42.0)


# --- the world --------------------------------------------------------------------------------------------------------------------

func _build_ground() -> void:
	var s := CutsceneKit.Soup.new()
	s.box(Vector3(0.0, -0.5, -20.0), Vector3(80.0, 0.5, 70.0), Color("0e1a12"))  # forest floor
	s.box(Vector3(0.0, 0.01, 9.5), Vector3(2.1, 0.02, 21.5), Color("2b2118"))  # the dirt road
	s.box(Vector3(0.0, 0.012, -9.8), Vector3(6.0, 0.02, 3.0), Color("2b2118"))  # the clearing in front of the porch
	CutsceneKit.add_mesh(self, s.mesh())


func _build_trees() -> void:
	var s := CutsceneKit.Soup.new()
	var placed := 0
	var tries := 0
	while placed < TREES and tries < TREES * 8:
		tries += 1
		var x := rng.randf_range(-50.0, 50.0)
		var z := rng.randf_range(-64.0, 18.0)
		var k := rng.randf_range(0.8, 1.7)
		var g := rng.randf()
		if absf(x) < 4.5 and z > FRONT_Z + 1.0:
			continue  # the road
		if Vector2(x, z).distance_to(Vector2(0.0, CABIN_Z)) < 9.5:
			continue  # the clearing
		if Vector2(x, z).distance_to(Vector2(-3.0, 2.0)) < 3.5:
			continue  # not through the camera
		_tree(s, Vector3(x, 0.0, z), k, g)
		placed += 1
	CutsceneKit.add_mesh(self, s.mesh())


func _tree(s: CutsceneKit.Soup, at: Vector3, k: float, g: float) -> void:
	var leaf := Color(0.04 + 0.04 * g, 0.14 + 0.1 * g, 0.07 + 0.04 * g)
	s.cyl(at, 1.6 * k, Vector2(0.2 * k, 0.2 * k), Vector2(0.14 * k, 0.14 * k), 5, Color("2a1d14"), 0)
	for i in 3:
		var w := (1.9 - 0.45 * i) * k
		s.cyl(at + Vector3(0.0, (1.0 + 1.15 * i) * k, 0.0), 1.9 * k, Vector2(w, w), Vector2.ZERO, 6, leaf.lightened(0.07 * i), 0)


func _build_sky() -> void:
	var moon := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 2.6
	ball.height = 5.2
	ball.radial_segments = 16
	ball.rings = 8
	moon.mesh = ball
	moon.position = Vector3(-22.0, 20.0, -80.0)
	moon.material_override = CutsceneKit.glow(Color(0.92, 0.95, 1.0))
	moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(moon)
	var halo := MeshInstance3D.new()
	var halo_mat := CutsceneKit.glow(Color(0.6, 0.72, 1.0))
	if _tier < 1:
		var big := SphereMesh.new()
		big.radius = 6.0
		big.height = 12.0
		big.radial_segments = 16
		big.rings = 8
		halo.mesh = big
		halo.position = moon.position
		halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		halo_mat.albedo_color.a = 0.1
	else:  # no alpha sphere: the same 10 % blue over the flat sky as an opaque disc just behind the moon, facing the shot's start
		var disc := CylinderMesh.new()
		disc.top_radius = 6.2
		disc.bottom_radius = 6.2
		disc.height = 0.05
		disc.radial_segments = 24
		disc.rings = 1
		disc.cap_bottom = false
		var away := (moon.position - Vector3(-3.0, 1.15, 5.2)).normalized()
		halo.mesh = disc
		halo.position = moon.position + away * 3.0
		halo.basis = Basis(Quaternion(Vector3.UP, -away))
		halo_mat.albedo_color = Color(0.008, 0.012, 0.026).srgb_to_linear().lerp(Color(0.6, 0.72, 1.0).srgb_to_linear(), 0.1).linear_to_srgb()  # the sky colour is sRGB too
	halo.material_override = halo_mat
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(halo)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.5, 0.5)
	var star_mat := CutsceneKit.glow(Color(0.85, 0.9, 1.0))
	star_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = star_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = 90
	for i in 90:
		var dir := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.18, 1.0), rng.randf_range(-1.0, 0.2)).normalized()
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * rng.randf_range(0.5, 1.4)), dir * 150.0))
	var stars := MultiMeshInstance3D.new()
	stars.multimesh = mm
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stars)


# --- the cabin ----------------------------------------------------------------------------------------------------------------------

## A log lying along X from x0 to x1 at height y, depth z.
func _log_x(s: CutsceneKit.Soup, x0: float, x1: float, y: float, z: float, col: Color) -> void:
	s.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(x0, y, z))
	s.cyl(Vector3.ZERO, x1 - x0, Vector2(LOG_R, LOG_R), Vector2(LOG_R, LOG_R), 8, col)
	s.xf = Transform3D.IDENTITY


## A log lying along Z from z0 to z1 at height y, offset x.
func _log_z(s: CutsceneKit.Soup, z0: float, z1: float, y: float, x: float, col: Color) -> void:
	s.xf = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(x, y, z0))
	s.cyl(Vector3.ZERO, z1 - z0, Vector2(LOG_R, LOG_R), Vector2(LOG_R, LOG_R), 8, col)
	s.xf = Transform3D.IDENTITY


func _log_color() -> Color:
	return Color("5c3d24").lightened(rng.randf_range(-0.12, 0.1))


func _build_cabin() -> void:
	var s := CutsceneKit.Soup.new()
	var back_z := CABIN_Z - (FRONT_Z - CABIN_Z)
	for i in 9:
		var y := LOG_R + 0.33 * i
		var over := HALF_W + 0.3
		if y + LOG_R < 2.05:  # below the lintel the front wall is split by the doorway
			_log_x(s, -over, -DOOR_X, y, FRONT_Z, _log_color())
			_log_x(s, DOOR_X, over, y, FRONT_Z, _log_color())
		else:
			_log_x(s, -over, over, y, FRONT_Z, _log_color())
		_log_x(s, -over, over, y, back_z, _log_color())
		_log_z(s, back_z - 0.3, FRONT_Z + 0.3, y + 0.165, -HALF_W, _log_color())
		_log_z(s, back_z - 0.3, FRONT_Z + 0.3, y + 0.165, HALF_W, _log_color())
	# roof: two slabs meeting at the ridge, shingles dark; gables closed with a triangle of boards
	var slope := deg_to_rad(21.0)
	var shingle := Color("1d1819")
	s.xf = Transform3D(Basis(Vector3.BACK, slope), Vector3(-1.95, 3.85, CABIN_Z))
	s.box(Vector3.ZERO, Vector3(2.2, 0.07, 3.5), shingle)
	s.xf = Transform3D(Basis(Vector3.BACK, -slope), Vector3(1.95, 3.85, CABIN_Z))
	s.box(Vector3.ZERO, Vector3(2.2, 0.07, 3.5), shingle)
	s.xf = Transform3D.IDENTITY
	s.tri(Vector3(-HALF_W, 3.0, FRONT_Z + 0.02), Vector3(HALF_W, 3.0, FRONT_Z + 0.02), Vector3(0.0, 4.55, FRONT_Z + 0.02), Vector3.BACK, Color("4a3220"))
	s.tri(Vector3(-HALF_W, 3.0, back_z - 0.02), Vector3(HALF_W, 3.0, back_z - 0.02), Vector3(0.0, 4.55, back_z - 0.02), Vector3.FORWARD, Color("4a3220"))
	s.box(Vector3(2.3, 4.2, CABIN_Z - 0.8), Vector3(0.32, 1.3, 0.32), Color("4a4747"))  # chimney
	# doorway frame
	var dark := Color("2a1a10")
	s.box(Vector3(-DOOR_X - 0.07, 1.03, FRONT_Z + 0.1), Vector3(0.07, 1.03, 0.1), dark)
	s.box(Vector3(DOOR_X + 0.07, 1.03, FRONT_Z + 0.1), Vector3(0.07, 1.03, 0.1), dark)
	s.box(Vector3(0.0, 2.1, FRONT_Z + 0.1), Vector3(DOOR_X + 0.14, 0.07, 0.1), dark)
	# a window left of the door: frame only, the glow is its own mesh
	s.box(Vector3(-2.2, 1.5, FRONT_Z + 0.2), Vector3(0.5, 0.04, 0.04), dark)
	s.box(Vector3(-2.2, 0.95, FRONT_Z + 0.2), Vector3(0.5, 0.04, 0.04), dark)
	s.box(Vector3(-2.68, 1.225, FRONT_Z + 0.2), Vector3(0.04, 0.3, 0.04), dark)
	s.box(Vector3(-1.72, 1.225, FRONT_Z + 0.2), Vector3(0.04, 0.3, 0.04), dark)
	s.box(Vector3(-2.2, 1.225, FRONT_Z + 0.2), Vector3(0.025, 0.3, 0.03), dark)
	CutsceneKit.add_mesh(self, s.mesh())
	var pane := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.92, 0.55)
	pane.mesh = quad
	pane.position = Vector3(-2.2, 1.225, FRONT_Z + 0.19)
	pane.material_override = CutsceneKit.glow(Color(0.9, 0.5, 0.22), 0.7)
	add_child(pane)
	# the doorway's glow (behind the door) and a hint of the bar inside
	var back := MeshInstance3D.new()
	var wall := QuadMesh.new()
	wall.size = Vector2(1.5, 2.1)
	back.mesh = wall
	back.position = Vector3(0.0, 1.05, FRONT_Z - 2.4)
	_glow_mat = CutsceneKit.glow(Color(1.0, 0.62, 0.28), 0.0)
	back.material_override = _glow_mat
	add_child(back)
	var inner := CutsceneKit.Soup.new()
	inner.box(Vector3(0.0, 0.8, FRONT_Z - 1.1), Vector3(0.55, 0.07, 0.34), Color("246b3a"))  # a pool table's cloth, seen through the door
	inner.box(Vector3(0.0, 0.4, FRONT_Z - 1.1), Vector3(0.5, 0.33, 0.3), Color("3a2415"))
	inner.box(Vector3(0.0, 0.03, FRONT_Z - 1.4), Vector3(1.4, 0.03, 1.4), Color("2a1a10"))
	CutsceneKit.add_mesh(self, inner.mesh())
	# the door: a pivot on the left jamb, swings inward (-Z)
	_door = Node3D.new()
	_door.position = Vector3(-DOOR_X, 0.0, FRONT_Z + 0.08)
	add_child(_door)
	var d := CutsceneKit.Soup.new()
	d.box(Vector3(DOOR_X, 1.02, 0.0), Vector3(DOOR_X, 1.02, 0.04), Color("3b2514"))
	for i in 4:
		d.box(Vector3(DOOR_X, 0.3 + 0.5 * i, 0.045), Vector3(DOOR_X - 0.03, 0.02, 0.01), Color("2a190d"))  # plank seams
	d.box(Vector3(2.0 * DOOR_X - 0.15, 1.0, 0.07), Vector3(0.04, 0.04, 0.03), Color("a8864a"))  # handle
	CutsceneKit.add_mesh(_door, d.mesh())


func _build_porch() -> void:
	var s := CutsceneKit.Soup.new()
	var z0 := FRONT_Z + 1.4
	s.box(Vector3(0.0, 0.1, z0), Vector3(2.6, 0.1, 1.4), Color("9a7a58"))  # deck
	s.box(Vector3(0.0, 0.04, FRONT_Z + 2.95), Vector3(1.0, 0.04, 0.25), Color("8a6a4a"))  # step
	for x in [-2.5, 2.5]:
		s.box(Vector3(x, 1.3, FRONT_Z + 2.5), Vector3(0.09, 1.3, 0.09), Color("3a2a1c"))  # posts
	s.box(Vector3(0.0, 2.65, FRONT_Z + 2.5), Vector3(2.6, 0.09, 0.09), Color("3a2a1c"))  # beam
	s.box(Vector3(0.0, 2.78, z0), Vector3(2.8, 0.05, 1.6), Color("1d1819"))  # porch roof
	s.box(Vector3(0.0, 2.38, FRONT_Z + 2.55), Vector3(1.0, 0.2, 0.025), Color("20160e"))  # the sign board
	CutsceneKit.add_mesh(self, s.mesh(CutsceneKit.textured("floor", Color.WHITE, 1.4)))
	var bulb := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.08
	ball.height = 0.16
	ball.radial_segments = 8
	ball.rings = 4
	bulb.mesh = ball
	bulb.position = Vector3(-1.2, 2.3, FRONT_Z + 2.3)
	bulb.material_override = CutsceneKit.glow(Color(1.0, 0.82, 0.5))
	add_child(bulb)
	var title := Label3D.new()
	title.text = "GUS'S CORNER POCKET"
	title.font_size = 48
	title.pixel_size = 0.003
	title.modulate = Color(1.0, 0.85, 0.55)
	title.outline_size = 0
	title.position = Vector3(0.0, 2.42, FRONT_Z + 2.58)
	add_child(title)
	var sub := Label3D.new()
	sub.text = "est. 1979"
	sub.font_size = 28
	sub.pixel_size = 0.003
	sub.modulate = Color(0.85, 0.7, 0.45)
	sub.outline_size = 0
	sub.position = Vector3(0.0, 2.3, FRONT_Z + 2.58)
	add_child(sub)


# --- the van ------------------------------------------------------------------------------------------------------------------------

func _build_van() -> void:
	_van = Node3D.new()
	_van.name = "Van"
	add_child(_van)
	var s := CutsceneKit.Soup.new()
	var paint := Color("2a2c33")
	s.box(Vector3(0.0, 1.15, 0.0), Vector3(0.95, 0.8, 2.1), paint)  # the box
	s.box(Vector3(0.0, 0.7, -2.6), Vector3(0.92, 0.38, 0.5), paint)  # the bonnet
	s.box(Vector3(0.0, 1.45, -2.11), Vector3(0.84, 0.3, 0.03), Color("0b1118"))  # windscreen
	s.box(Vector3(0.0, 0.42, 2.17), Vector3(0.97, 0.1, 0.08), Color("101012"))  # rear bumper
	s.box(Vector3(0.0, 1.15, 2.11), Vector3(0.012, 0.76, 0.012), Color("08080a"))  # the rear doors' seam
	for sx in [-1.0, 1.0]:
		for z in [-2.2, 1.4]:
			s.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(sx * 0.92 - 0.14, 0.4, z))
			s.cyl(Vector3.ZERO, 0.28, Vector2(0.4, 0.4), Vector2(0.4, 0.4), 10, Color("0a0a0b"))
			s.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(sx * 0.92 - 0.15 + (0.01 if sx > 0.0 else 0.0), 0.4, z))
			s.cyl(Vector3.ZERO, 0.3, Vector2(0.2, 0.2), Vector2(0.2, 0.2), 8, Color("55585e"))
			s.xf = Transform3D.IDENTITY
	CutsceneKit.add_mesh(_van, s.mesh())
	_tail_mat = CutsceneKit.glow(Color(1.0, 0.05, 0.03))
	for sx in [-0.78, 0.78]:
		var lamp := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.14, 0.3)
		lamp.mesh = q
		lamp.position = Vector3(sx, 1.0, 2.125)
		lamp.material_override = _tail_mat
		_van.add_child(lamp)
	if _tier < 2:
		_head = CutsceneKit.spot(_van, Vector3(0.0, 0.8, -3.1), Vector3(0.0, 0.1, -16.0), Color(1.0, 0.95, 0.8), 8.0, 25.0, 32.0)
	_tail_glow = CutsceneKit.omni(_van, Vector3(0.0, 1.0, 2.7), Color(1.0, 0.1, 0.05), 0.0, 5.0)


# --- the timeline -------------------------------------------------------------------------------------------------------------------

func _update(time: float, _dt: float) -> void:
	var rem := maxf(STOP_T - time, 0.0)
	var decel := V0 / STOP_T
	var z := STOP_Z + 0.5 * decel * rem * rem
	var dive := 0.045 * smoothstep(0.4, STOP_T, time) * (1.0 - smoothstep(STOP_T, STOP_T + 0.45, time))
	var rebound := CutsceneKit.bump(time, STOP_T, 0.014, 2.2, 5.0)
	var idle := 0.004 * sin(time * 55.0) * (1.0 - smoothstep(2.0, 2.3, time))  # the engine, until it is switched off
	_van.position = Vector3(0.0, idle, z)
	_van.rotation = Vector3(-dive - rebound, 0.0, 0.003 * sin(time * 40.0) * (1.0 - smoothstep(STOP_T, STOP_T + 0.3, time)))
	var brake := 1.0 if (time > 0.35 and time < 2.3) else 0.0
	_tail_mat.albedo_color = Color(1.0, 0.05, 0.03) * (0.35 + 0.65 * brake)
	_tail_glow.light_energy = 1.6 * brake
	if _head != null:
		_head.light_energy = 8.0 * (1.0 - smoothstep(2.1, 2.7, time))
	var flick := 0.88 + 0.12 * sin(time * 41.0 + _ph[0]) * sin(time * 13.0 + _ph[1])
	if fposmod(time * 1.3 + _ph[2], 2.4) < 0.1:
		flick *= 0.3  # the porch light stutters
	var open := smoothstep(DOOR_AT, DOOR_AT + DOOR_SEC, time)
	_porch.light_energy = 2.2 * flick * (1.0 if _door_beam != null else 1.0 + 0.4 * open)  # no door beam: the open door's glow rides on the porch
	_door.rotation.y = open * deg_to_rad(105.0)
	_glow_mat.albedo_color = Color(1.0, 0.62, 0.28) * (0.15 + 0.85 * open)
	if _door_beam != null:
		_door_beam.light_energy = 5.0 * open
	var cam := Vector3(-3.0, 1.15, 5.2 - 1.0 * time)
	var look := Vector3(0.0, 1.2, z - 1.0).lerp(Vector3(0.0, 1.5, FRONT_Z), smoothstep(1.2, 2.7, time))
	camera.transform = CutsceneKit.look_from(cam, look)
	camera.fov = lerpf(60.0, 44.0, smoothstep(0.8, 3.0, time))
