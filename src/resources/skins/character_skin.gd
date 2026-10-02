class_name CharacterSkin
extends Resource
## One character look (06 P18). Applied by the humanoid body (`apply_skin`); free in test mode.

@export var id: StringName
@export var display_name := ""
@export var body_color := Color("e0534a")    # torso + upper arms
@export var accent_color := Color("2b2b33")  # legs
@export var skin_color := Color("e8b48a")    # head + hands
@export var hat: StringName = &"none"         # none | cap | tophat | beanie | crown
