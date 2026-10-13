class_name CeilingCam
extends Node3D
## The fixed ceiling camera (docs/plan/02 §3.2, 06 P33 U5): a small pod under the centre beam, lens straight down on the table.
## A prop and a picture, never a score: it is not in `CameraRigs.rigs`, so `CameraScorer` never sees it and it adds no Camera_Mult
## (F2 recalibrates the money, 02). Its picture is the right half of the wall TV (StreamTv). The origin is the lens: that is the eye.
## The table lamp's rod and shade hang from the same beam over the table's centre and are never moved, so the pod hangs OFFSET_Z south
## of them, clear of the shade's cone; the lamp (shade, cap, rod) is its own render layer, LAMP_LAYER, which only this camera's
## cull mask leaves out (build_bar_room.gd puts it there), so the lamp never blocks the picture.

const LAMP_LAYER := 1 << 12  ## render layer 13: the table lamp; every camera but the ceiling feed draws it
const BEAM_Y := 3.3          ## underside of the centre beam (build_bar_room.gd: CEIL 3.6, beam 0.3 tall)
const HANG := 0.16           ## from the beam down to the lens
const EYE_Y := BEAM_Y - HANG
const OFFSET_Z := 0.36       ## from the table's centre, toward the TV wall: the shade's cone is 0.25 m wide here, the barrel starts at 0.31
const MARGIN := 1.05         ## the table fills the picture with a 5 % border
const FALLBACK_FOV := 90.0

static var _mesh: ArrayMesh  # one model

var table: Table  ## whose outer rails the picture must hold (CameraRigs sets it)


func _ready() -> void:
	var model := MeshInstance3D.new()
	model.name = "Model"
	model.mesh = _model()
	model.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC  # no UV2: lit by the bake's probes, like the tripods
	model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(model)


func eye() -> Vector3:
	return global_position


## Straight down, the picture's top toward -Z (the north wall): a viewer facing the TV reads the table as if standing at its south side.
func look_basis() -> Basis:
	return Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)


## Vertical field of view (degrees) that holds the table's outer rails (top edge, all four corners) in a picture of `aspect`
## (width / height), with MARGIN. Pure geometry from the live table spec, so a table rebuild or a new spec needs no edit here.
func fit_fov(aspect: float) -> float:
	if table == null:
		return FALLBACK_FOV
	var spec := table.spec
	var centre := table.global_position
	var depth := global_position.y - (centre.y + spec.bed_height_m + spec.rail_height_m)
	var reach_x := absf(centre.x - global_position.x) + spec.length_m * 0.5 + spec.rail_width_m
	var reach_z := absf(centre.z - global_position.z) + spec.width_m * 0.5 + spec.rail_width_m
	return rad_to_deg(2.0 * atan(MARGIN * maxf(reach_z, reach_x / aspect) / depth))


## One ArrayMesh, three surfaces (3 draw calls, like a tripod): the mounting plate and body (matte), the lens barrel (metal), the
## glass and a red tally (optic palette). Built with the tripod's own helpers, on its palette.
static func _model() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var metal := CameraRig._surface(CameraRig._material(Color(0.2, 0.21, 0.24), 0.65, 0.15))
	var matte := CameraRig._surface(CameraRig._material(Color(0.06, 0.06, 0.07), 0.92, 0.0))
	var optic := CameraRig._surface(CameraRig._optic_material())
	CameraRig._box(matte, Vector3(0.2, 0.015, 0.26), _at(HANG - 0.0075))        # mounting plate, flush with the beam
	CameraRig._box(matte, Vector3(0.14, 0.09, 0.18), _at(0.10))                 # body
	CameraRig._cyl_xf(metal, 0.05, 0.05, _at(0.03))                             # lens barrel
	CameraRig._cyl_xf(optic, 0.04, 0.008, _at(0.004), CameraRig.UV_GLASS)       # front glass, facing down
	CameraRig._box(optic, Vector3(0.02, 0.02, 0.02), _at(0.10, 0.095), CameraRig.UV_TALLY)  # tally light on the body
	_mesh = ArrayMesh.new()
	for st: SurfaceTool in [metal, matte, optic]:
		st.commit(_mesh)
	return _mesh


static func _at(y: float, z := 0.0) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, y, z))
