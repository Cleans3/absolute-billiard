class_name BallEventCodec
extends RefCounted

## Hand-packed ball-state frames for `push_contact_events` / `push_heartbeat` (04 §2.4).
## Frame: `shot_id u16 | base_tick u32 | count u8` then `count` × 21-byte events:
## `id_flags u8 | tick_offset u16 | pos 3×s16 | lin 3×s16 | ang 3×s16`, all little-endian.
## id_flags = ball_id (6 bits, < 64) | flag << 6. Fixed-point: pos 0.1 mm (±3.27 m about `origin`),
## lin 1 mm/s (±32.7 m/s: the 24 m/s speed ceiling fits), ang 1/32 rad/s (±1023 rad/s). tick_offset counts LIVE_TICK ticks.

enum Flag { NONE, POCKETED, RETIRED, RESTORED }

const HEADER_SIZE := 7
const EVENT_SIZE := 21
const MAX_BALLS := 64
const POS_SCALE := 10000.0
const LIN_SCALE := 1000.0
const ANG_SCALE := 32.0


static func begin(buf: PackedByteArray, shot_id: int, base_tick: int) -> void:
	buf.resize(HEADER_SIZE)
	buf.encode_u16(0, shot_id)
	buf.encode_u32(2, base_tick)
	buf[6] = 0


static func count(buf: PackedByteArray) -> int:
	return buf[6]


static func shot_id(buf: PackedByteArray) -> int:
	return buf.decode_u16(0)


static func base_tick(buf: PackedByteArray) -> int:
	return buf.decode_u32(2)


## Returns false when the frame is full (255 events) — caller flushes and begins a new one.
static func append(buf: PackedByteArray, ball_id: int, flag: int, tick_offset: int, s: BallMotion.State, origin: Vector3) -> bool:
	var n := buf[6]
	if n == 255:
		return false
	var o := HEADER_SIZE + n * EVENT_SIZE
	buf.resize(o + EVENT_SIZE)
	buf[o] = ball_id | (flag << 6)
	buf.encode_u16(o + 1, tick_offset)
	var q := s.pos - origin
	buf.encode_s16(o + 3, _q(q.x, POS_SCALE))
	buf.encode_s16(o + 5, _q(q.y, POS_SCALE))
	buf.encode_s16(o + 7, _q(q.z, POS_SCALE))
	buf.encode_s16(o + 9, _q(s.lin.x, LIN_SCALE))
	buf.encode_s16(o + 11, _q(s.lin.y, LIN_SCALE))
	buf.encode_s16(o + 13, _q(s.lin.z, LIN_SCALE))
	buf.encode_s16(o + 15, _q(s.ang.x, ANG_SCALE))
	buf.encode_s16(o + 17, _q(s.ang.y, ANG_SCALE))
	buf.encode_s16(o + 19, _q(s.ang.z, ANG_SCALE))
	buf[6] = n + 1
	return true


static func ball_id(buf: PackedByteArray, i: int) -> int:
	return buf[HEADER_SIZE + i * EVENT_SIZE] & 0x3F


static func flag(buf: PackedByteArray, i: int) -> int:
	return buf[HEADER_SIZE + i * EVENT_SIZE] >> 6


static func tick_offset(buf: PackedByteArray, i: int) -> int:
	return buf.decode_u16(HEADER_SIZE + i * EVENT_SIZE + 1)


static func read_state(buf: PackedByteArray, i: int, origin: Vector3, out: BallMotion.State) -> void:
	var o := HEADER_SIZE + i * EVENT_SIZE
	out.pos = origin + Vector3(buf.decode_s16(o + 3), buf.decode_s16(o + 5), buf.decode_s16(o + 7)) / POS_SCALE
	out.lin = Vector3(buf.decode_s16(o + 9), buf.decode_s16(o + 11), buf.decode_s16(o + 13)) / LIN_SCALE
	out.ang = Vector3(buf.decode_s16(o + 15), buf.decode_s16(o + 17), buf.decode_s16(o + 19)) / ANG_SCALE


## Rounds `s` in place to exactly what a client decodes, so the host predicts from the same state.
static func quantize(s: BallMotion.State, origin: Vector3) -> void:
	var q := s.pos - origin
	s.pos = origin + Vector3(_q(q.x, POS_SCALE), _q(q.y, POS_SCALE), _q(q.z, POS_SCALE)) / POS_SCALE
	s.lin = Vector3(_q(s.lin.x, LIN_SCALE), _q(s.lin.y, LIN_SCALE), _q(s.lin.z, LIN_SCALE)) / LIN_SCALE
	s.ang = Vector3(_q(s.ang.x, ANG_SCALE), _q(s.ang.y, ANG_SCALE), _q(s.ang.z, ANG_SCALE)) / ANG_SCALE


static func _q(v: float, scale: float) -> int:
	return clampi(roundi(v * scale), -32767, 32767)
