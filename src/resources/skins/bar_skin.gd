class_name BarSkin
extends Resource
## One bar-room palette (06 P18). Applied by `BarRoom.apply_skin`; albedo only, the lightmap bake is kept.

@export var id: StringName
@export var display_name := ""
@export var wall_color := Color("5a2a2a")
@export var wainscot_color := Color("3a2418")
@export var floor_color := Color("2e2620")
@export var wood_color := Color("6b3f22")   # counter, tables, trim
@export var seat_color := Color("b8241c")   # stools
@export var felt_color := Color(0.05, 0.35, 0.15)
@export var neon_a := Color(1.0, 0.15, 0.55)  # the pink neon slot
@export var neon_b := Color(0.1, 0.85, 1.0)   # the cyan neon slot
