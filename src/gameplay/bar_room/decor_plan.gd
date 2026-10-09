class_name DecorPlan
extends RefCounted
## What dresses the bar (adhoc-1010a C10/C18) and where it must NOT go. Data only: build_bar_room.gd turns it into the
## baked `Decor` mesh and tests/world/bar_room_probe.gd checks the result against `keep_clear`.
##
## Sources (CC0, licences beside the models in assets/third_party/<pack>/): Kenney Furniture / Survival / Food kits.
## Posters + dartboard are our own art (src/tools/make_posters.py). Models are authored small, `SCALE` brings each pack to
## bar size. Every model faces +Z; a prop against a wall turns its front into the room (AGAINST_*).

const PACKS := {
	&"furniture": {dir = "kenney_furniture-kit", subdir = "", scale = 2.0},
	&"survival": {dir = "kenney_survival-kit", subdir = "", scale = 2.5},
	&"food": {dir = "kenney_food-kit", subdir = "", scale = 0.35},
}

## Kenney's palettes are daylight-bright; the bar is lit by dim neon, so untextured props are pulled down to wall-ish albedo
## (posters keep their own art). [tune]
const PROP_TINT := Color(0.56, 0.52, 0.50)

const AGAINST_SOUTH := 180.0  # wall z=+7, front faces -z
const AGAINST_NORTH := 0.0    # wall z=-7, front faces +z
const AGAINST_WEST := 90.0    # wall x=-7, front faces +x
const AGAINST_EAST := -90.0   # wall x=+7, front faces -x

const HALF := 7.0
const CEIL := 3.6
const TABLE_TOP_Y := 1.01   # round bar tables (build_bar_room.gd: top at 0.98, 0.06 thick)

## [id, pack, model, Vector3(x, y, z), yaw_deg, kind, scale multiplier = 1.0] — x,z = footprint centre, y = bottom of the model.
## kind: &"floor" collides + keep-clear checked; &"flat" (rug: no collision, keep-clear only vs the door and the table band);
## &"on_table" / &"top" sit on another prop (no collision, no keep-clear); &"hang" y = TOP of the model (ceiling mount).
const ITEMS: Array = [
	# lounge corners flanking the table's north end (the table band stops at |x| 4.6)
	[&"sofa_ne", &"furniture", "loungeSofa", Vector3(5.6, 0.0, -6.55), AGAINST_NORTH, &"floor"],
	[&"sofa_nw", &"furniture", "loungeSofa", Vector3(-5.6, 0.0, -6.55), AGAINST_NORTH, &"floor"],
	[&"lamp_ne", &"furniture", "lampRoundFloor", Vector3(6.8, 0.0, -6.7), 0.0, &"floor"],
	[&"lamp_nw", &"furniture", "lampSquareFloor", Vector3(-6.8, 0.0, -6.7), 0.0, &"floor"],
	[&"rug_ne", &"furniture", "rugRectangle", Vector3(5.6, 0.004, -5.6), 0.0, &"flat", 0.6],
	[&"rug_nw", &"furniture", "rugRound", Vector3(-5.7, 0.004, -5.55), 0.0, &"flat", 0.7],
	[&"plant_e", &"furniture", "pottedPlant", Vector3(6.7, 0.0, -5.8), 0.0, &"floor"],
	# south wall: TV wall with speakers, shelving, a bar fridge
	[&"speaker_l", &"furniture", "speaker", Vector3(-1.9, 0.0, 6.78), AGAINST_SOUTH, &"floor"],
	[&"speaker_r", &"furniture", "speaker", Vector3(1.9, 0.0, 6.78), AGAINST_SOUTH, &"floor"],
	[&"shelf_a", &"furniture", "bookcaseOpen", Vector3(2.8, 0.0, 6.72), AGAINST_SOUTH, &"floor"],
	[&"shelf_b", &"furniture", "bookcaseOpen", Vector3(3.7, 0.0, 6.72), AGAINST_SOUTH, &"floor"],
	[&"books_a", &"furniture", "books", Vector3(2.8, 1.76, 6.72), AGAINST_SOUTH, &"top"],
	[&"fridge", &"furniture", "kitchenFridge", Vector3(4.6, 0.0, 6.66), AGAINST_SOUTH, &"floor"],
	[&"lamp_s", &"furniture", "lampSquareFloor", Vector3(-4.0, 0.0, 6.78), 0.0, &"floor"],
	# west wall
	[&"coatrack", &"furniture", "coatRackStanding", Vector3(-6.62, 0.0, -0.85), 0.0, &"floor"],
	[&"sidetable", &"furniture", "sideTable", Vector3(-6.7, 0.0, 0.95), AGAINST_WEST, &"floor"],
	[&"radio", &"furniture", "radio", Vector3(-6.7, 0.76, 0.95), AGAINST_WEST, &"top"],
	# east wall, north of the counter aisle
	[&"barrel_a", &"survival", "barrel", Vector3(6.55, 0.0, -1.1), 0.0, &"floor"],
	[&"barrel_b", &"survival", "barrel", Vector3(6.6, 0.0, -0.5), 0.0, &"floor"],
	[&"crate", &"survival", "box-large", Vector3(5.9, 0.0, -0.95), 0.0, &"floor"],
	# ceiling fans over the open bar floor
	[&"fan_a", &"furniture", "ceilingFan", Vector3(-2.0, CEIL, 3.0), 0.0, &"hang"],
	[&"fan_b", &"furniture", "ceilingFan", Vector3(2.0, CEIL, 3.0), 0.0, &"hang"],
	# round table tops
	[&"tt_plant1", &"furniture", "plantSmall1", Vector3(-5.2, TABLE_TOP_Y, 2.6), 0.0, &"on_table"],
	[&"tt_plant2", &"furniture", "plantSmall2", Vector3(-5.2, TABLE_TOP_Y, 4.4), 0.0, &"on_table"],
	[&"tt_plant3", &"furniture", "plantSmall3", Vector3(-2.8, TABLE_TOP_Y, 5.6), 0.0, &"on_table"],
	[&"tt_cocktail", &"food", "cocktail", Vector3(-5.0, TABLE_TOP_Y, 2.8), 0.0, &"on_table"],
	[&"tt_mug", &"food", "mug", Vector3(-4.95, TABLE_TOP_Y, 4.55), 0.0, &"on_table"],
]

## Posters. [id, atlas col, atlas row, cols wide, wall, along (x for N/S, z for E/W), y centre, width m]. Cell = 256x300 px,
## so height = width * 300/256 (portrait) — the 2-wide banner is 512x300.
const POSTERS: Array = [
	[&"p_eightball", 0, 0, 1, &"S", -5.6, 1.95, 1.0],
	[&"p_beer", 1, 0, 1, &"S", -4.1, 1.95, 1.0],
	[&"p_shark", 2, 0, 1, &"S", -2.6, 1.95, 1.0],
	[&"p_tournament", 3, 0, 1, &"S", 3.3, 2.75, 1.0],
	[&"p_happyhour", 0, 1, 1, &"W", 3.55, 1.95, 1.0],
	[&"p_band", 1, 1, 1, &"W", 4.95, 1.95, 1.0],
	[&"p_chalk", 2, 1, 1, &"W", -0.6, 1.95, 1.0],
	[&"p_billiards", 3, 1, 1, &"E", -5.95, 1.95, 1.0],
	[&"p_noscratch", 3, 2, 1, &"E", -0.8, 1.95, 1.0],
	[&"p_open_late", 0, 2, 2, &"N", -3.4, 1.85, 1.9],
]

## The dartboard: a disc using the atlas square at col 2, row 2 (256x256 inside a 256x300 cell).
const DARTBOARD := {wall = &"N", along = 5.2, y = 1.8, diameter = 0.9, cell = Vector2(2, 2)}

const ATLAS_PATH := "res://assets/decor/poster_atlas.png"
const ATLAS_SIZE := Vector2(1024, 1024)
const CELL := Vector2(256, 300)
const WHITE_UV := Vector2(0.5, 0.95)  # the untouched white strip: untextured props take their colour from the vertex colour
const POSTER_OFFSET := 0.04           # frame depth; the poster sits on its front face


## Floor rects (x0, z0, x1, z1) no decor may stand in; wall rects per wall: Rect2(along, y, w, h) no poster may touch.
## Owners' contract in .feat/plan.md: blackboard (hud), mirror (player), GO LIVE pedestal (flow), Bar.PROPS spots, the
## 1.6 m band around the table outline, door, counter + aisle + back bar, jukebox, tables + stools, TV, neon, fuse box.
static func floor_keep_clear() -> Array[Rect2]:
	var r: Array[Rect2] = []
	r.append(_rect(-4.6, -7.2, 4.6, 0.2))          # table outline (x ±3.0, z -5.6..-1.4) + 1.6 m walking band
	r.append(_rect(-1.6, -7.0, 1.6, -5.4))         # door and its swing
	r.append(_rect(4.6, 0.3, 7.0, 4.7))            # counter, aisle, back bar
	r.append(_rect(3.9, 0.6, 4.7, 4.4))            # counter stools
	r.append(_rect(6.0, 5.0, 7.0, 6.5))            # jukebox
	r.append(_rect(5.5, -5.4, 7.0, -1.6))          # in front of the blackboard (east wall, 3.2 w x 1.75 h at z -3.5: z -5.1..-1.9 + 0.3)
	r.append(_rect(-7.0, -5.9, -5.2, -1.7))        # in front of the mirror (west wall, z -5.6..-2.0 + 0.3)
	for t: Vector2 in [Vector2(-5.2, 2.6), Vector2(-5.2, 4.4), Vector2(-2.8, 5.6)]:
		r.append(_rect(t.x - 1.0, t.y - 1.0, t.x + 1.0, t.y + 1.0))  # table + its two stools
	r.append(_circle_rect(Vector3(-3.7, 0.0, -1.0), 1.2))  # GO LIVE pedestal (flow)
	for p: Array in Bar.PROPS:
		r.append(_circle_rect(p[1], Bar.REACH_ZONE_RADIUS))
	return r


## Wall rects keyed by wall letter; Rect2 position = (along, y), size = (width, height).
static func wall_keep_clear() -> Dictionary:
	return {
		&"S": [Rect2(-1.6, 1.25, 3.2, 1.7)],                # TV
		&"N": [Rect2(-1.2, 0.0, 2.4, 2.6),                  # door + frame
				Rect2(-4.3, 2.6, 2.6, 0.5), Rect2(2.1, 2.5, 1.8, 0.7)],  # neon signs
		&"E": [Rect2(-5.4, 0.77, 3.8, 2.36), Rect2(0.3, 0.0, 4.4, 3.6)],   # blackboard y 1.07..2.83 (+0.3) ; counter + back bar panel
		&"W": [Rect2(-5.9, 0.2, 4.2, 2.4),                  # mirror (+0.3)
				Rect2(0.3, 1.8, 2.4, 0.8), Rect2(5.5, 1.1, 0.7, 0.6)],  # neon bars, fuse box
	}


static func _rect(x0: float, z0: float, x1: float, z1: float) -> Rect2:
	return Rect2(x0, z0, x1 - x0, z1 - z0)


static func _circle_rect(c: Vector3, r: float) -> Rect2:
	return Rect2(c.x - r, c.z - r, 2.0 * r, 2.0 * r)
