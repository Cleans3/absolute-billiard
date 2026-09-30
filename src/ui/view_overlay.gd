class_name ViewOverlay
extends ColorRect
## The shooter's difficulty screen (docs/plan/03 §3.8): one ColorRect, one shader, uniforms only, and
## hidden (no pass at all) while nothing is active. Client-local: it reads EffectManager, never writes it.

@export var effects: EffectManager


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	if effects != null:
		effects.effect_applied.connect(_on_change.unbind(4))
		effects.effect_expired.connect(_on_change.unbind(3))
		effects.shooter_changed.connect(_on_change.unbind(1))


func _on_change() -> void:
	var local := multiplayer.get_unique_id()
	var crew := effects.current_shooter() == local  # crew-wide view Effects (lights_out) hit the shooter only
	var light := effects.get_stat(&"player_view_light_level", local, 1.0, crew)
	var fog := effects.get_stat(&"player_view_fog_density", local, 0.0, crew)
	var shake := effects.get_stat(&"player_view_shake_amp", local, 0.0, crew)
	visible = light != 1.0 or fog != 0.0 or shake != 0.0
	if visible:
		var mat := material as ShaderMaterial
		mat.set_shader_parameter(&"light_level", clampf(light, 0.0, 1.0))
		mat.set_shader_parameter(&"fog_density", clampf(fog, 0.0, 1.0))
		mat.set_shader_parameter(&"shake_amp", shake)
