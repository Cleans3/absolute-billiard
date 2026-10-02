class_name GlitchEffect
extends RichTextEffect
## `[glitch]text[/glitch]` for the Mystery tier (06 P17): at ~12 steps a second a few characters flash cyan or white
## and jump, and now and then a short band of the line slips sideways. Stateless: a pure function of (index, time).

const STEP_HZ := 12.0
const CYAN := Color("19E6FF")
const BAND := 6  # characters that slip together

var bbcode := "glitch"


func _process_custom_fx(c: CharFXTransform) -> bool:
	var step := floori(c.elapsed_time * STEP_HZ)
	var r := _noise(c.relative_index, step)
	if r > 0.95:  # flashes cyan and jumps up
		c.color = CYAN
		c.offset += Vector2((r - 0.975) * 160.0, -2.0)
	elif r > 0.88:  # flashes white and shears sideways
		c.color = Color.WHITE
		c.offset.x += (r - 0.91) * 90.0
	if _noise(floori(c.relative_index / float(BAND)), step + 7919) > 0.94:  # the band slips
		c.offset.x += 4.0
	return true


func _noise(a: int, b: int) -> float:
	return float(hash(Vector2i(a, b)) % 1000) / 1000.0
