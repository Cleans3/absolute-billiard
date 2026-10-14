class_name CutsceneSfx
extends RefCounted
## The in-room cutscenes' sounds (docs/plan/09 §3.8): a door slam, the bolt's clunk, a body landing, the alert siren, the gas. Rendered once
## in code like the Bartender's blips, so there are no audio files and nothing to import. They play on the Master bus (Settings volume applies).

enum Kind { SLAM, CLUNK, THUD, ALARM, HISS }

const MIX_RATE := 22050
const SECONDS: Array[float] = [0.55, 0.35, 0.3, 0.9, 1.2]  ## per Kind
const LOOPING: Array[int] = [Kind.ALARM, Kind.HISS]  ## these wrap: stop() them

static var _cache := {}


static func stream(kind: int) -> AudioStreamWAV:
	if not _cache.has(kind):
		_cache[kind] = _render(kind)
	return _cache[kind]


## Renders every Kind now (adhoc-1014b C9): the synthesis is ~35 ms of GDScript on a desktop, so it runs once when the level loads, behind the
## LoadingScreen, and no cutscene beat pays for it on a shown frame. A second call costs nothing.
static func prerender() -> void:
	for kind in SECONDS.size():
		stream(kind)


## Starts `kind` on a new AudioStreamPlayer under `parent` (it goes with it). A one-shot frees its player when it ends; stop() a loop.
static func play(parent: Node, kind: int, volume_db := -4.0) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream(kind)
	p.volume_db = volume_db
	parent.add_child(p)
	if not LOOPING.has(kind):
		p.finished.connect(p.queue_free)
	p.play()
	return p


static func _render(kind: int) -> AudioStreamWAV:
	var sec: float = SECONDS[kind]
	var n := int(sec * MIX_RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1013 + kind
	var low := 0.0  # one-pole low-passed noise
	var phase := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var v := 0.0
		match kind:
			Kind.SLAM:
				low += 0.18 * (rng.randf_range(-1.0, 1.0) - low)
				v = (0.8 * low * exp(-t * 14.0) + 0.9 * sin(TAU * 62.0 * t) * exp(-t * 8.0)) * minf(1.0, t / 0.002)
			Kind.CLUNK:
				var click := rng.randf_range(-1.0, 1.0) * exp(-t * 700.0)
				v = 0.55 * sin(TAU * 210.0 * t) * exp(-t * 36.0) + 0.35 * sin(TAU * 483.0 * t) * exp(-t * 55.0) + 0.5 * click
			Kind.THUD:
				low += 0.12 * (rng.randf_range(-1.0, 1.0) - low)
				v = 0.9 * sin(TAU * 74.0 * t) * exp(-t * 16.0) + 0.5 * low * exp(-t * 30.0)
			Kind.ALARM:  # a two-tone siren that sweeps once per loop
				phase += TAU * (640.0 + 330.0 * (0.5 + 0.5 * sin(TAU * t / sec))) / MIX_RATE
				v = 0.34 * (sin(phase) + 0.3 * sin(3.0 * phase))
			_:  # HISS: the gas
				low += 0.4 * (rng.randf_range(-1.0, 1.0) - low)
				v = 0.45 * low * (0.75 + 0.25 * sin(TAU * 2.0 * t / sec))
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	if LOOPING.has(kind):
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n
	return wav
