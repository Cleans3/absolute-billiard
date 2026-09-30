class_name BallTypeOverride
extends RefCounted
## A shop-bought replacement for one BallType field; RULES applies it when it builds the rack.

var id: StringName
var base_value := 0


static func make(p_id: StringName, p_value: int) -> BallTypeOverride:
	var o := BallTypeOverride.new()
	o.id = p_id
	o.base_value = p_value
	return o
