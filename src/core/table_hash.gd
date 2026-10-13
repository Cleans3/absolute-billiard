class_name TableHash
extends RefCounted

## A 32-bit digest of the table (06 P49): FNV-1a over a stream of ints. Host and clients feed it the same things in the same
## order (balls by net_id, Round scalars, pocket stats, motion stats, the hazard parameters), floats rounded to 1e-4, so
## equal tables give equal digests on every platform and a changed type, flag, ball cell or Effect number gives another.

const PRIME := 0x01000193
const FLOAT_SCALE := 10000.0

var value := 0x811C9DC5


func add_int(v: int) -> void:
	for i in 8:
		value = ((value ^ ((v >> (i * 8)) & 0xFF)) * PRIME) & 0xFFFFFFFF


func add_float(v: float) -> void:
	add_int(roundi(v * FLOAT_SCALE))


func add_str(s: String) -> void:
	add_int(s.hash())


## Anything a hazard or an Effect may hand over: scalars, strings, vectors, arrays, dictionaries (keys in sorted order).
func add_variant(v: Variant) -> void:
	match typeof(v):
		TYPE_NIL: add_int(0)
		TYPE_BOOL: add_int(1 if v else 2)
		TYPE_INT: add_int(v)
		TYPE_FLOAT: add_float(v)
		TYPE_STRING, TYPE_STRING_NAME: add_str(String(v))
		TYPE_VECTOR2:
			add_float(v.x)
			add_float(v.y)
		TYPE_VECTOR3:
			add_float(v.x)
			add_float(v.y)
			add_float(v.z)
		TYPE_VECTOR2I:
			add_int(v.x)
			add_int(v.y)
		TYPE_DICTIONARY:
			var keys: Array = v.keys()
			keys.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
			add_int(keys.size())
			for k in keys:
				add_str(String(k))
				add_variant(v[k])
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY:
			add_int(v.size())
			for e in v:
				add_variant(e)
		_: add_str(str(v))


## Never 0: 0 means "no digest" on the wire.
func result() -> int:
	return 1 if value == 0 else value
