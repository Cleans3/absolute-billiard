class_name HazardView
extends Node3D

## The picture of a live hazard on the table (adhoc-1014a G, 06 P50-P53). Presentation only: no collider (the pins' are
## PhysicsSim's), nothing the physics reads. Built by EffectManager on every peer from the same HazardModel, freed with the Round.
##   Vacation    water on one side of the shoreline, sand on the other, one sheet over the cloth (hazard_surface.gdshader)
##   Sunken Ship the table is NOT rotated (a ball would float or clip); the corner shows it instead: a pool on the floor round that
##               leg with the leg sunk in it, a wreck (planks, anchor, barnacles), a wet current of chevrons on the cloth toward
##               the pocket, and the pocket's rim lit
##   Pinball     four chrome posts with a red rubber bumper and a lit cap
## All of it sits in table-local space: the node follows the Table's transform and the meshes are built in metres.

const SURFACE := preload("res://src/gameplay/hazards/hazard_surface.gdshader")
const LIFT_M := 0.005        ## the sheet's height over the cloth: clear of it on a 16-bit depth buffer, below a resting ball's equator
const RIM_WIDTH_M := 0.055
const POOL_RADIUS_M := 1.05
const POOL_HEIGHT_M := 0.2
const WOOD := Color(0.22, 0.15, 0.09)
const WET_WOOD := Color(0.12, 0.1, 0.07)
const IRON := Color(0.17, 0.19, 0.2)
const RUST := Color(0.32, 0.17, 0.09)
const BARNACLE := Color(0.8, 0.78, 0.7)
const SLIME := Color(0.05, 0.22, 0.14)
const CHROME := Color(0.78, 0.8, 0.84)
const BUMPER := Color(0.85, 0.1, 0.12)

var _tween: Tween


## Builds the picture for `m` on `table` (the node follows the table's transform and is freed with this view).
func show_model(m: HazardModel, table: Table) -> void:
	top_level = true
	global_transform = table.global_transform
	match m.kind:
		HazardModel.VACATION:
			_add_sheet(table, 0, m)
		HazardModel.SUNKEN_SHIP:
			_add_sheet(table, 1, m)
			_add_pool_and_wreck(table, m)
			_add_rim(table, m)
		HazardModel.PINBALL:
			_add_pins(m)


# ---------------------------------------------------------------- the sheet over the cloth

func _add_sheet(table: Table, mode: int, m: HazardModel) -> void:
	var spec := table.spec
	var plane := PlaneMesh.new()
	plane.size = Vector2(spec.length_m, spec.width_m)
	var mat := ShaderMaterial.new()
	mat.shader = SURFACE
	mat.render_priority = -1
	mat.set_shader_parameter(&"mode", mode)
	mat.set_shader_parameter(&"shore_z", m.shore_local_z)
	mat.set_shader_parameter(&"water_sign", m.water_sign)
	mat.set_shader_parameter(&"corner", m.corner_local)
	var holes := PackedVector4Array()
	for p in table.layout.pockets:
		var hole: TableLayout.Hole = table.layout.holes[p.id]
		holes.append(Vector4(hole.center.x, hole.center.y, hole.cup_radius, 0.0))
	mat.set_shader_parameter(&"holes", holes)
	mat.set_shader_parameter(&"hole_count", holes.size())
	var mi := MeshInstance3D.new()
	mi.name = "Sheet"
	mi.mesh = plane
	mi.material_override = mat
	mi.position = Vector3(0.0, spec.bed_height_m + LIFT_M, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# ---------------------------------------------------------------- Sunken Ship: the corner

func _corner_sign(m: HazardModel) -> Vector2:
	return Vector2(signf(m.corner_local.x), signf(m.corner_local.y))


## The pool at the foot of the sunk corner's leg, the leg's slime and barnacles, the planks and the anchor in the water.
func _add_pool_and_wreck(table: Table, m: HazardModel) -> void:
	var spec := table.spec
	var sg := _corner_sign(m)
	var leg := Vector3(sg.x * (spec.length_m * 0.5 + spec.rail_width_m * 0.6), 0.0, sg.y * (spec.width_m * 0.5 + spec.rail_width_m * 0.6))
	var leg_size := spec.rail_width_m * 0.3
	var centre := leg + Vector3(sg.x, 0.0, sg.y) * 0.3
	var pool := CylinderMesh.new()
	pool.top_radius = POOL_RADIUS_M
	pool.bottom_radius = POOL_RADIUS_M
	pool.height = POOL_HEIGHT_M
	pool.radial_segments = 28
	pool.rings = 1
	var mat := ShaderMaterial.new()
	mat.shader = SURFACE
	mat.set_shader_parameter(&"mode", 2)
	mat.set_shader_parameter(&"hole_count", 0)
	var mi := MeshInstance3D.new()
	mi.name = "Pool"
	mi.mesh = pool
	mi.material_override = mat
	mi.position = centre + Vector3(0.0, POOL_HEIGHT_M * 0.5 + 0.004, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([m.corner, &"wreck"])  # the same wreck on every peer
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var water_y := POOL_HEIGHT_M
	# the leg's lower half in slime, barnacles on it
	var slime := BoxMesh.new()
	slime.size = Vector3(leg_size * 1.22, 0.36, leg_size * 1.22)
	_append(st, slime, Transform3D(Basis(), leg + Vector3(0.0, 0.18, 0.0)), SLIME)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.022
	cone.height = 0.04
	cone.radial_segments = 6
	cone.rings = 1
	for i in 18:
		var face := rng.randi() % 4
		var h := rng.randf_range(0.04, 0.46)
		var side := rng.randf_range(-0.45, 0.45) * leg_size * 1.22
		var off := leg_size * 0.61
		var pos: Vector3 = leg + [Vector3(off, h, side), Vector3(-off, h, side), Vector3(side, h, off), Vector3(side, h, -off)][face]
		var basis: Basis = [Basis(Vector3.BACK, deg_to_rad(-90.0)), Basis(Vector3.BACK, deg_to_rad(90.0)), Basis(Vector3.RIGHT, deg_to_rad(90.0)), Basis(Vector3.RIGHT, deg_to_rad(-90.0))][face]  # +Y out of the face
		_append(st, cone, Transform3D(basis, pos), BARNACLE)
	# planks floating and wedged round the pool
	var plank := BoxMesh.new()
	plank.size = Vector3(1.0, 0.04, 0.17)
	for i in 7:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.25, POOL_RADIUS_M - 0.2)
		var len_k := rng.randf_range(0.55, 1.25)
		var xf := Transform3D(Basis(Vector3.UP, rng.randf() * PI) * Basis.from_scale(Vector3(len_k, 1.0, 1.0)), centre + Vector3(cos(a) * r, water_y + rng.randf_range(-0.01, 0.05), sin(a) * r))
		xf.basis = xf.basis * Basis(Vector3.RIGHT, rng.randf_range(-0.2, 0.2))
		_append(st, plank, xf, WET_WOOD if i % 2 == 0 else WOOD)
	# broken ribs of the hull standing out of the water
	var rib := BoxMesh.new()
	rib.size = Vector3(0.06, 0.7, 0.05)
	for i in 3:
		var a2 := (float(i) - 1.0) * 0.5 + atan2(sg.y, sg.x) + PI
		var rp := centre + Vector3(cos(a2), 0.0, sin(a2)) * 0.62 + Vector3(0.0, 0.3, 0.0)
		_append(st, rib, Transform3D(Basis(Vector3.RIGHT, rng.randf_range(-0.25, 0.25)).rotated(Vector3.UP, rng.randf() * PI), rp), WOOD)
	# the anchor: a shank leaning on the leg, a crown ring, a stock, two flukes
	var anc := centre + Vector3(-sg.x * 0.35, 0.0, sg.y * 0.15)
	var tilt := Basis(Vector3.FORWARD, deg_to_rad(18.0)).rotated(Vector3.UP, atan2(sg.y, sg.x))
	var shank := CylinderMesh.new()
	shank.top_radius = 0.026
	shank.bottom_radius = 0.03
	shank.height = 0.95
	shank.radial_segments = 8
	shank.rings = 1
	_append(st, shank, Transform3D(tilt, anc + tilt * Vector3(0.0, 0.42, 0.0)), IRON)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.035
	ring.outer_radius = 0.075
	ring.rings = 10
	ring.ring_segments = 6
	_append(st, ring, Transform3D(tilt * Basis(Vector3.RIGHT, deg_to_rad(90.0)), anc + tilt * Vector3(0.0, 0.93, 0.0)), RUST)
	var stock := CylinderMesh.new()
	stock.top_radius = 0.018
	stock.bottom_radius = 0.018
	stock.height = 0.46
	stock.radial_segments = 6
	stock.rings = 1
	_append(st, stock, Transform3D(tilt * Basis(Vector3.RIGHT, deg_to_rad(90.0)), anc + tilt * Vector3(0.0, 0.8, 0.0)), IRON)
	var fluke := BoxMesh.new()
	fluke.size = Vector3(0.3, 0.035, 0.07)
	for k in [-1.0, 1.0]:
		_append(st, fluke, Transform3D(tilt * Basis(Vector3.FORWARD, deg_to_rad(28.0 * k)), anc + tilt * Vector3(0.14 * k, 0.04, 0.0)), RUST)
	# seaweed from the leg
	var weed := BoxMesh.new()
	weed.size = Vector3(0.025, 0.28, 0.01)
	for i in 5:
		var wp := leg + Vector3(rng.randf_range(-0.5, 0.5) * leg_size, 0.45, rng.randf_range(-0.5, 0.5) * leg_size) + Vector3(sg.x, 0.0, sg.y) * leg_size * 0.62
		_append(st, weed, Transform3D(Basis(Vector3.UP, rng.randf() * PI), wp), SLIME.lightened(0.15))
	var wreck := MeshInstance3D.new()
	wreck.name = "Wreck"
	wreck.mesh = st.commit()
	var wm := StandardMaterial3D.new()
	wm.vertex_color_use_as_albedo = true
	wm.vertex_color_is_srgb = true
	wm.roughness = 0.85
	wreck.material_override = wm
	add_child(wreck)


## The pocket's rim on the cloth side, lit and pulsing: the inner arc of its hole as a ribbon.
func _add_rim(table: Table, m: HazardModel) -> void:
	var hole: TableLayout.Hole = table.layout.holes[m.corner]
	var y := table.spec.bed_height_m + LIFT_M + 0.003
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var arc := hole.inner
	for i in arc.size() - 1:
		var a := arc[i]
		var b := arc[i + 1]
		var a2 := a + (a - hole.center).normalized() * RIM_WIDTH_M
		var b2 := b + (b - hole.center).normalized() * RIM_WIDTH_M
		for v in [a, b, b2, a, b2, a2]:
			st.add_vertex(Vector3(v.x, y, v.y))
	var mi := MeshInstance3D.new()
	mi.name = "Rim"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.3, 1.0, 0.95, 0.9)
	mat.render_priority = 1
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_tween = create_tween().set_loops()
	_tween.tween_property(mat, "albedo_color", Color(1.0, 0.85, 0.3, 0.9), 0.7)
	_tween.tween_property(mat, "albedo_color", Color(0.3, 1.0, 0.95, 0.9), 0.7)


# ---------------------------------------------------------------- Pinball

func _add_pins(m: HazardModel) -> void:
	var h := HazardModel.PIN_H_RADII * m.ball_r
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var caps := SurfaceTool.new()
	caps.begin(Mesh.PRIMITIVE_TRIANGLES)
	var post := CylinderMesh.new()
	post.top_radius = m.pin_r * 0.62
	post.bottom_radius = m.pin_r * 0.62
	post.height = h
	post.radial_segments = 14
	post.rings = 1
	var band := CylinderMesh.new()
	band.top_radius = m.pin_r
	band.bottom_radius = m.pin_r
	band.height = h * 0.34
	band.radial_segments = 18
	band.rings = 1
	var foot := CylinderMesh.new()
	foot.top_radius = m.pin_r * 0.9
	foot.bottom_radius = m.pin_r * 1.05
	foot.height = h * 0.14
	foot.radial_segments = 14
	foot.rings = 1
	var cap := SphereMesh.new()
	cap.radius = m.pin_r * 0.72
	cap.height = m.pin_r * 1.44
	cap.radial_segments = 14
	cap.rings = 7
	for q in m.pins_local:
		var base := Vector3(q.x, m.cloth_y, q.y)
		_append(body, post, Transform3D(Basis(), base + Vector3(0.0, h * 0.5, 0.0)), CHROME)
		_append(body, foot, Transform3D(Basis(), base + Vector3(0.0, h * 0.07, 0.0)), CHROME.darkened(0.3))
		_append(body, band, Transform3D(Basis(), base + Vector3(0.0, h * 0.5, 0.0)), BUMPER)
		_append(caps, cap, Transform3D(Basis(), base + Vector3(0.0, h * 0.96, 0.0)), Color(1.0, 0.92, 0.5))
	var mi := MeshInstance3D.new()
	mi.name = "Pins"
	mi.mesh = body.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.metallic = 0.55
	mat.roughness = 0.3
	mi.material_override = mat
	add_child(mi)
	var cm := MeshInstance3D.new()
	cm.name = "PinCaps"
	cm.mesh = caps.commit()
	var cmat := StandardMaterial3D.new()
	cmat.vertex_color_use_as_albedo = true
	cmat.vertex_color_is_srgb = true
	cmat.emission_enabled = true
	cmat.emission = Color(1.0, 0.7, 0.2)
	cmat.emission_energy_multiplier = 1.6
	cm.material_override = cmat
	cm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cm)
	_tween = create_tween().set_loops()
	_tween.tween_property(cmat, "emission_energy_multiplier", 0.5, 0.45)
	_tween.tween_property(cmat, "emission_energy_multiplier", 1.8, 0.45)


# ---------------------------------------------------------------- helpers

## Appends `mesh` (any primitive, surface 0) to `st` at `xf` with one vertex colour.
static func _append(st: SurfaceTool, mesh: Mesh, xf: Transform3D, col: Color) -> void:
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var nb := xf.basis.inverse().transposed()
	st.set_color(col)
	for i in idx:
		st.set_normal((nb * norms[i]).normalized())
		st.add_vertex(xf * verts[i])
