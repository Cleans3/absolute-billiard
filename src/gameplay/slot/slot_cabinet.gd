class_name SlotCabinet
extends RefCounted
## Geometry of the bar slot machine, built in code (docs/plan/02 §3.9): one merged body mesh (cabinet, bulbs, buttons), the lever
## and a 24-face drum. Local space: floor at y 0, footprint centred on the origin, front toward +Z. Vertex data feeds
## slot_machine.gdshader: colour = tint, COLOR.a = chasing-bulb mask, UV2 = (bulb phase, steady glow); untextured faces
## sample the atlas's white cell.

const WIDTH := 0.9   ## footprint, x
const DEPTH := 0.8   ## footprint, z
const FACES := 24
const DRUM_R := 0.30
const DRUM_W := 0.16
const DRUM_X: Array[float] = [-0.18, 0.0, 0.18]
const DRUM_Y := 1.15
const WINDOW := Rect2(-0.30, 0.99, 0.60, 0.32)  ## the reel opening: x, y of its low corner, width, height
const FRONT_Z := 0.36
const LEVER_AT := Vector3(0.462, 0.95, 0.0)
const LED_AT := Vector3(0.0, 0.83, FRONT_Z + 0.0105)
const TITLE_AT := Vector3(0.0, 1.71, FRONT_Z + 0.008)
const POP_AT := Vector3(0.0, 2.25, 0.25)
const COIN_AT := Vector3(0.0, 0.34, 0.42)  ## where the coins leave: the tray
const CELLS := 8     ## atlas cells: 7 symbols + the white one
const WHITE_UV := Vector2(0.9375, 0.5)

const BODY := Color("2B3FAE")  # cobalt: the room is red, the machine must not melt into the wall
const BRASS := Color("C9A24B")
const BLACK := Color("14100E")
const STEEL := Color("B9C0C8")
const PINK := Color("FF3D9A")
const CYAN := Color("3DE0FF")
const GOLD := Color("FFC93A")


class Builder:
	extends RefCounted
	var st := SurfaceTool.new()

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

	## One quad from four corners in cycle order; the winding is picked from the normals (Godot: clockwise from outside).
	func quad(p: Array[Vector3], n: Array[Vector3], uv: Array[Vector2], color: Color, uv2: Vector2) -> void:
		var out := Vector3.ZERO
		for v in n:
			out += v
		if (p[1] - p[0]).cross(p[2] - p[0]).dot(out) > 0.0:
			p = [p[3], p[2], p[1], p[0]]
			n = [n[3], n[2], n[1], n[0]]
			uv = [uv[3], uv[2], uv[1], uv[0]]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_color(color)
			st.set_normal(n[i])
			st.set_uv(uv[i])
			st.set_uv2(uv2)
			st.add_vertex(p[i])

	func box(center: Vector3, size: Vector3, color: Color, glow := 0.0, chase := 0.0, phase := 0.0) -> void:
		var h := size * 0.5
		var c := Color(color.r, color.g, color.b, chase)
		for axis in 3:
			for sgn in [-1.0, 1.0]:
				var n := Vector3.ZERO
				n[axis] = sgn
				var u := Vector3.ZERO
				u[(axis + 1) % 3] = h[(axis + 1) % 3]
				var v := Vector3.ZERO
				v[(axis + 2) % 3] = h[(axis + 2) % 3]
				var mid := center + n * h[axis]
				quad([mid - u - v, mid - u + v, mid + u + v, mid + u - v], [n, n, n, n],
						[WHITE_UV, WHITE_UV, WHITE_UV, WHITE_UV], c, Vector2(phase, glow))

	## A low-poly ball for the lever knob: `rings` latitude bands x `segs` around.
	func ball(center: Vector3, radius: float, color: Color, glow := 0.0, rings := 6, segs := 10) -> void:
		for j in rings:
			var a0 := PI * j / rings
			var a1 := PI * (j + 1) / rings
			for i in segs:
				var b0 := TAU * i / segs
				var b1 := TAU * (i + 1) / segs
				var d: Array[Vector3] = [_dir(a0, b0), _dir(a0, b1), _dir(a1, b1), _dir(a1, b0)]
				quad([center + d[0] * radius, center + d[1] * radius, center + d[2] * radius, center + d[3] * radius],
						d, [WHITE_UV, WHITE_UV, WHITE_UV, WHITE_UV], Color(color.r, color.g, color.b, 0.0), Vector2(0.0, glow))

	func _dir(polar: float, azimuth: float) -> Vector3:
		return Vector3(sin(polar) * cos(azimuth), cos(polar), sin(polar) * sin(azimuth))

	func commit() -> ArrayMesh:
		return st.commit()


## Cabinet, deck, header, window frame, buttons and the two bulb loops: one surface, one draw call.
static func body_mesh() -> ArrayMesh:
	var b := Builder.new()
	var hw := WINDOW.size.x * 0.5
	b.box(Vector3(0.0, 0.06, 0.0), Vector3(WIDTH, 0.12, DEPTH), BLACK)  # plinth
	b.box(Vector3(0.0, 0.37, -0.01), Vector3(0.86, 0.50, 0.74), BODY)  # lower body
	b.box(Vector3(0.0, 0.645, 0.0), Vector3(0.88, 0.05, 0.78), BRASS)  # control deck
	b.box(Vector3(0.0, 0.30, 0.38), Vector3(0.50, 0.10, 0.04), BLACK)  # coin tray
	b.box(Vector3(0.0, 0.30, 0.396), Vector3(0.40, 0.012, 0.012), BRASS, 0.6)
	b.box(Vector3(0.0, 0.50, 0.375), Vector3(0.12, 0.14, 0.012), BRASS)  # coin plate
	b.box(Vector3(0.0, 0.50, 0.383), Vector3(0.02, 0.08, 0.006), PINK, 1.0)  # its slot
	for k in 3:  # the three deck buttons
		b.box(Vector3(-0.2 + 0.2 * k, 0.685, 0.27), Vector3(0.08, 0.03, 0.055), [PINK, CYAN, GOLD][k], 0.9)
	# reel housing: back block, two cheeks, the pieces above and below the window
	b.box(Vector3(0.0, 1.135, -0.20), Vector3(0.86, 0.93, 0.36), BODY)
	b.box(Vector3(-0.365, 1.135, 0.17), Vector3(0.13, 0.93, 0.38), BODY)
	b.box(Vector3(0.365, 1.135, 0.17), Vector3(0.13, 0.93, 0.38), BODY)
	b.box(Vector3(0.0, WINDOW.end.y + 0.145, 0.17), Vector3(WINDOW.size.x, 0.29, 0.38), BODY)
	b.box(Vector3(0.0, WINDOW.position.y - 0.16, 0.17), Vector3(WINDOW.size.x, 0.32, 0.38), BODY)
	b.box(Vector3(0.0, DRUM_Y, -0.02), Vector3(WINDOW.size.x, WINDOW.size.y, 0.04), BLACK)  # dark behind the drums
	b.box(Vector3(0.0, DRUM_Y, FRONT_Z - 0.004), Vector3(WINDOW.size.x, 0.008, 0.004), Color("FF2A3C"), 1.0)  # payline
	for side in [-1.0, 1.0]:
		b.box(Vector3(side * (hw + 0.025), DRUM_Y, FRONT_Z), Vector3(0.03, 0.04, 0.02), Color("FF2A3C"), 1.0)
	b.box(Vector3(0.0, 0.83, FRONT_Z + 0.002), Vector3(0.56, 0.16, 0.012), BLACK)  # LED panel
	b.box(Vector3(0.44, LEVER_AT.y, 0.0), Vector3(0.02, 0.16, 0.16), BRASS)  # lever mount on the right cheek
	b.box(Vector3(0.446, LEVER_AT.y, 0.0), Vector3(0.008, 0.03, 0.03), STEEL)
	# header: marquee face and a crown
	b.box(Vector3(0.0, 1.71, 0.0), Vector3(0.86, 0.22, 0.72), BODY)
	b.box(Vector3(0.0, 1.71, FRONT_Z + 0.001), Vector3(0.74, 0.14, 0.006), BLACK, 0.12)
	b.box(Vector3(0.0, 1.84, 0.0), Vector3(0.74, 0.04, 0.62), BRASS)
	# the bulb loops, phase running round each loop so the shader chases them
	_bulb_loop(b, Rect2(WINDOW.position.x - 0.03, WINDOW.position.y - 0.03, WINDOW.size.x + 0.06, WINDOW.size.y + 0.06), FRONT_Z + 0.004, 0.065, [GOLD, PINK])
	_bulb_loop(b, Rect2(-0.40, 1.625, 0.80, 0.17), FRONT_Z + 0.004, 0.065, [CYAN, PINK])
	return b.commit()


static func _bulb_loop(b: Builder, r: Rect2, z: float, spacing: float, colors: Array[Color]) -> void:
	var corners := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	var perimeter := 2.0 * (r.size.x + r.size.y)
	var count := int(perimeter / spacing)
	for i in count:
		var d := perimeter * i / count
		var p := Vector2.ZERO
		for e in 4:  # walk the rectangle's four edges
			var a: Vector2 = corners[e]
			var c: Vector2 = corners[(e + 1) % 4]
			var edge := a.distance_to(c)
			if d <= edge:
				p = a.lerp(c, d / edge)
				break
			d -= edge
		b.box(Vector3(p.x, p.y, z), Vector3(0.026, 0.026, 0.014), colors[i % colors.size()], 0.0, 1.0, float(i) / count)


## Arm and knob, pivot at the origin (the arm points up; pull = rotation.x toward +Z).
static func lever_mesh() -> ArrayMesh:
	var b := Builder.new()
	b.box(Vector3(0.0, 0.17, 0.0), Vector3(0.024, 0.34, 0.024), STEEL)
	b.ball(Vector3(0.0, 0.37, 0.0), 0.05, Color("E8283C"), 0.5)
	return b.commit()


## A flat gold coin for the win burst; white so the particle colour tints it.
static func coin_mesh() -> ArrayMesh:
	var b := Builder.new()
	b.box(Vector3.ZERO, Vector3(0.05, 0.05, 0.012), Color.WHITE, 0.55)
	return b.commit()


## One drum: FACES flat-shaded-by-cell, smooth-lit quads round the X axis. Face i is centred at angle i * 360/FACES and shows
## the symbol SlotMath.STRIP[i]; rotation.x = i * TAU/FACES brings it to the front.
static func drum_mesh() -> ArrayMesh:
	var b := Builder.new()
	var step := TAU / FACES
	var hw := DRUM_W * 0.5
	var pad := 0.0015
	for i in FACES:
		var sym: int = SlotMath.STRIP[i]
		var u0 := float(sym) / CELLS + pad
		var u1 := float(sym + 1) / CELLS - pad
		var lo := (i - 0.5) * step
		var hi := (i + 0.5) * step
		var d0 := Vector3(0.0, sin(lo), cos(lo))
		var d1 := Vector3(0.0, sin(hi), cos(hi))
		b.quad([Vector3(-hw, 0.0, 0.0) + d0 * DRUM_R, Vector3(-hw, 0.0, 0.0) + d1 * DRUM_R, Vector3(hw, 0.0, 0.0) + d1 * DRUM_R, Vector3(hw, 0.0, 0.0) + d0 * DRUM_R],
				[d0, d1, d1, d0], [Vector2(u0, 0.97), Vector2(u0, 0.03), Vector2(u1, 0.03), Vector2(u1, 0.97)], Color(1.0, 1.0, 1.0, 0.0), Vector2(0.0, 0.42))
	return b.commit()
