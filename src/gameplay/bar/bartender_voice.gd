class_name BartenderVoice
extends AudioStreamPlayer3D
## The Bartender's gibberish (C4, 06 P24): a blip per syllable of the line, pitched from its letters, a longer breath at
## punctuation, a lift at a question mark. The blips are six little buzzy tones rendered once in code; no audio files.
## Plays on the Master bus, so the Settings volume applies.

const MIX_RATE := 22050
const PITCHES: Array[float] = [118.0, 140.0, 165.0, 190.0, 220.0, 255.0]  ## Hz
const BLIP_SEC := 0.08
const SYLLABLE_SEC := 0.088
const WORD_GAP_SEC := 0.07
const PUNCT_GAP_SEC := 0.28
const VOWELS := "aeiouyAEIOUY"

var pitch_mult := 1.0   ## Moe's phone voice (09 §3.2): 0.6, with `length_mult` 1.4
var length_mult := 1.0  ## stretches every syllable and gap: a slower voice
var blips_played := 0   ## for probes

var _blips: Array[AudioStreamWAV] = []
var _events: Array[Vector2] = []   ## [seconds before this blip, pitch index (+ 0.5 = lifted)]
var _next := 0.0


func _ready() -> void:
	for hz in PITCHES:
		_blips.append(_render(hz))
	max_polyphony = 3
	unit_size = 5.0
	max_distance = 22.0
	volume_db = -7.0
	set_process(false)


## Start talking `text`: one blip per vowel group, so the babble follows the sentence's rhythm.
func speak(text: String) -> void:
	_events.clear()
	var pause := 0.0
	var in_vowel := false
	var word_hash := 0
	for i in text.length():
		var c := text[i]
		if VOWELS.contains(c):
			if not in_vowel:
				var lift := 0.5 if text.substr(i).find("?") >= 0 and text.substr(i).find("?") < 6 else 0.0
				_events.append(Vector2((pause + SYLLABLE_SEC) * length_mult, float((word_hash + c.unicode_at(0)) % PITCHES.size()) + lift))
				pause = 0.0
			in_vowel = true
		else:
			in_vowel = false
			if c == " ":
				pause += WORD_GAP_SEC
				word_hash = 0
			elif c in ".!?,;:":
				pause += PUNCT_GAP_SEC if c in ".!?" else PUNCT_GAP_SEC * 0.5
			else:
				word_hash += c.unicode_at(0)
	_next = _events[0].x if not _events.is_empty() else 0.0
	set_process(not _events.is_empty())


func is_talking() -> bool:
	return not _events.is_empty()


func _process(delta: float) -> void:
	_next -= delta
	if _next > 0.0 or _events.is_empty():
		set_process(not _events.is_empty())
		return
	var e: Vector2 = _events.pop_front()
	_next = _events[0].x if not _events.is_empty() else 0.0
	var idx := int(e.y)
	stream = _blips[idx]
	pitch_scale = (1.18 if e.y - float(idx) > 0.0 else 1.0) * randf_range(0.95, 1.06) * pitch_mult
	play()
	blips_played += 1


## One buzzy blip: fundamental + two harmonics, a quick attack, an exponential decay and a little vibrato.
static func _render(hz: float) -> AudioStreamWAV:
	var n := int(BLIP_SEC * MIX_RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / MIX_RATE
		var f := hz * (1.0 + 0.02 * sin(t * 38.0))
		var wave := sin(TAU * f * t) + 0.55 * sin(TAU * 2.0 * f * t) + 0.3 * sin(TAU * 3.0 * f * t)
		var env := minf(1.0, t / 0.006) * exp(-t * 26.0)
		data.encode_s16(i * 2, int(clampf(wave * env * 0.42, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
