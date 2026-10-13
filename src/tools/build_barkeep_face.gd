extends SceneTree

## One-shot (06 P48): cuts the bartender's head out of a CC0 character and writes it as the face asset.
##   godot --path . --headless -s src/tools/build_barkeep_face.gd -- <path to "Old Guy" .glb>
## Source: Polygonal Mind "Old Guy" (100 Avatars), CC0, https://poly.pizza/m/imEy3Tqg80 (sha256 in assets/CREDITS.md). The whole figure is one
## mesh in one flat-colour atlas, so the head is every triangle above the neck. It is rotated to face -Z like a Humanoid, scaled to
## the barkeep's head and moved into the head bone's frame (origin = the neck joint, +Y up). Writes assets/models/barkeep_face/barkeep_face.res
## and its 256 px atlas barkeep_face.png (+ its .import), then run `godot --path . --headless --import`.

const MESH_NODE := "mesh_char_016"
const NODE_SCALE := 100.0   ## the source node carries a 100x scale
const NECK_Y := 3.25        ## source units (the figure is 4.38 tall): below this a triangle is neck, shoulder or arm
const HEAD_H := 0.30        ## metres from the cut to the top of the skull
const HEAD_TOP := 0.30      ## the top of the skull above the head bone's origin (the barkeep's old head reached 0.30)
const OUT_DIR := "res://assets/models/barkeep_face/"
const TEX_PX := 256
## Seeds the atlas' .import (VRAM-compressed, mipmapped, like assets/textures: 07 §8) when there is none; `godot --headless --import` fills in the uid.
const IMPORT := """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="%s"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -s build_barkeep_face.gd -- <Old_Guy.glb>")
		quit(1)
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(args[0], state) != OK:
		push_error("cannot read " + args[0])
		quit(1)
		return
	var scene := doc.generate_scene(state)
	var mi := scene.find_child(MESH_NODE, true, false) as MeshInstance3D
	var arrays := mi.mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var head: Array[int] = []  # triangle numbers
	for t in idx.size() / 3:
		var y := (pos[idx[t * 3]].y + pos[idx[t * 3 + 1]].y + pos[idx[t * 3 + 2]].y) / 3.0 * NODE_SCALE
		if y >= NECK_Y:
			head.append(t)
	var skull := _largest_component(pos, idx, head)

	# source (x forward, y up) -> head frame (-z forward): a quarter turn about Y; then scale and place
	var turn := Basis(Vector3.UP, PI / 2.0)
	var box := AABB()
	var first := true
	var top := -1e9
	for t in skull:
		for k in 3:
			var p := pos[idx[t * 3 + k]] * NODE_SCALE
			box = AABB(p, Vector3.ZERO) if first else box.expand(p)
			first = false
			top = maxf(top, p.y)
	var s := HEAD_H / (top - NECK_Y)
	var centre := box.get_center()
	print("skull (source units) ", box, " scale ", s, " kept ", head.size(), " triangles")

	var remap := {}
	var out_pos := PackedVector3Array()
	var out_nrm := PackedVector3Array()
	var out_uv := PackedVector2Array()
	var out_idx := PackedInt32Array()
	for t in head:
		for k in 3:
			var i := idx[t * 3 + k]
			if not remap.has(i):
				remap[i] = out_pos.size()
				var p := pos[i] * NODE_SCALE
				p = turn * Vector3(p.x - centre.x, p.y, p.z - centre.z) * s
				out_pos.append(Vector3(p.x, p.y - (top * s) + HEAD_TOP, p.z))
				out_nrm.append(turn * nrm[i])
				out_uv.append(uv[i])
			out_idx.append(remap[i])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = out_pos
	out[Mesh.ARRAY_NORMAL] = out_nrm
	out[Mesh.ARRAY_TEX_UV] = out_uv
	out[Mesh.ARRAY_INDEX] = out_idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	mesh.resource_name = "BarkeepFace"
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("mesh: ", out_pos.size(), " vertices, ", out_idx.size() / 3, " triangles, aabb ", mesh.get_aabb(), " save ", ResourceSaver.save(mesh, OUT_DIR + "barkeep_face.res"))

	var img := (mi.mesh.surface_get_material(0) as BaseMaterial3D).albedo_texture.get_image()
	img.decompress()
	img.resize(TEX_PX, TEX_PX, Image.INTERPOLATE_LANCZOS)
	print("atlas save ", img.save_png(OUT_DIR + "barkeep_face.png"))
	if not FileAccess.file_exists(OUT_DIR + "barkeep_face.png.import"):
		var f := FileAccess.open(OUT_DIR + "barkeep_face.png.import", FileAccess.WRITE)
		f.store_string(IMPORT % (OUT_DIR + "barkeep_face.png"))
		f.close()
	quit(0)


## The triangles of `tris` that share vertices (by position) with the biggest connected piece: the skull, not the eyes, brows, nose or mustache.
func _largest_component(pos: PackedVector3Array, idx: PackedInt32Array, tris: Array[int]) -> Array[int]:
	var parent := {}
	for t in tris:
		for k in 3:
			var key := Vector3i((pos[idx[t * 3 + k]] * 100000.0).round())
			parent[key] = key
	for t in tris:
		var a := _root(parent, Vector3i((pos[idx[t * 3]] * 100000.0).round()))
		for k in [1, 2]:
			var b := _root(parent, Vector3i((pos[idx[t * 3 + k]] * 100000.0).round()))
			if a != b:
				parent[b] = a
	var count := {}
	for t in tris:
		var r := _root(parent, Vector3i((pos[idx[t * 3]] * 100000.0).round()))
		count[r] = int(count.get(r, 0)) + 1
	var best: Vector3i
	var most := -1
	for r: Vector3i in count:
		if count[r] > most:
			most = count[r]
			best = r
	var out: Array[int] = []
	for t in tris:
		if _root(parent, Vector3i((pos[idx[t * 3]] * 100000.0).round())) == best:
			out.append(t)
	return out


func _root(parent: Dictionary, key: Vector3i) -> Vector3i:
	while parent[key] != key:
		parent[key] = parent[parent[key]]
		key = parent[key]
	return key
