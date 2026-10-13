class_name GlareFlags
extends RefCounted

## The glare hypotheses as live switches (adhoc-1014a V3, 07 §7.7). The glare ("black areas with bright white outlines, a texture problem
## where objects overlap, around the edges") only ever showed on the phone, so one phone APK carries every candidate cause as a flag:
## Settings > Debug mode > DEBUG > View > "Glare hypotheses" flips them live (debug builds, which the phone APK is), or `AB_GLARE=a,b:c`
## in the environment on a desktop. A flag is the FIX applied (glow_off = the glow turned off), so the flags that ship on are `DEFAULTS`;
## the panel's "Baseline" turns all of them off to see the glare, then each flag back on one by one. QualityManager owns the
## application (`apply`, on change and when the viewport's camera changes). Nothing here touches the wire or the scene files.
## `apply` also carries the tier's cheap-mode switches (glow, reflection probes, the lamp's shadow, QualityManager.TIERS): they
## override the same nodes the flags do, so one pass decides each value and one meta slot restores the scene's own.
##
## AB_GLARE=none           every flag off (and the persisted set ignored)
## AB_GLARE=default        the shipped set (DEFAULTS)
## AB_GLARE=all            every boolean flag on
## AB_GLARE=glow_off,aa:fxaa,msaa:off   those flags (a choice flag takes `name:value`)

const ENV := "AB_GLARE"
const GROUP := &"glare_flags"
## Boolean flags: name -> what is switched, for the panel.
const BOOLS := {
	&"glow_off": "Environment glow off (bloom bleed round bright pixels)",
	&"probes_off": "Reflection probes off (grazing-angle sheen on dark surfaces)",
	&"baked_spec_off": "Baked neon / room lights: no specular on dynamic meshes (the table rail's cyan streak)",
	&"lamp_spec_off": "Table lamp: no specular",
	&"mat_spec_off": "Every material metallic_specular 0 (matte)",
	&"lamp_shadow_off": "Table lamp shadow off",
	&"shadow_bias_hi": "Shadow bias x5 + normal bias 2.5 (acne / leaks at contact edges)",
	&"lightmap_off": "Baked lightmap off",
	&"depth_range": "Camera near 0.1 (depth precision, z-fighting)",
	&"normalmap_off": "Normal maps off (tangent / UV-seam shading)",
	&"fog_off": "Depth fog off",
	&"mirror_off": "Wall mirror hidden (its SubViewport passes)",
	&"tv_off": "Wall TV hidden (its SubViewport feeds)",
	&"hdr2d_off": "Root viewport hdr_2d off (RGB10_A2 target)",
	&"scale_full": "3D render scale 1.0 (no bilinear upscale)",
	&"rough_limiter_off": "Screen-space roughness limiter off",
}
## Choice flags: name -> [what, options]. The first option is the tier's own setting.
const CHOICES := {
	&"aa": ["Screen-space AA", ["tier", "none", "fxaa", "smaa"]],
	&"msaa": ["MSAA", ["tier", "off", "2x", "4x"]],
}
## What ships: the fixes whose cost is nothing and that no desktop view shows harm from. Set after the desktop evidence (07 §7.7).
const DEFAULTS: Dictionary = {&"baked_spec_off": "1", &"depth_range": "1"}

static var _flags: Dictionary = {}   ## name -> "1" for a boolean, the option for a choice
static var _loaded := false
static var path := "user://glare_flags.cfg"
static var persist := true             ## probes and tools turn it off
static var _mats_touched := false      ## a material flag was applied: the next pass must walk the meshes to put the originals back


static func get_flags() -> Dictionary:
	_ensure()
	return _flags


static func on(flag: StringName) -> bool:
	_ensure()
	return _flags.has(flag)


## "tier" when the tier's own AA / MSAA stands.
static func choice(flag: StringName) -> String:
	_ensure()
	return _flags.get(flag, "tier")


static func set_flag(flag: StringName, value: String = "1") -> void:
	_ensure()
	if value == "" or value == "0" or (CHOICES.has(flag) and value == "tier"):
		_flags.erase(flag)
	else:
		_flags[flag] = value
	_changed()


static func set_all(flags: Dictionary) -> void:
	_ensure()
	_flags = flags.duplicate()
	_changed()


static func everything() -> Dictionary:
	var d := {}
	for f: StringName in BOOLS:
		d[f] = "1"
	return d


## Parses "a,b:c" (the AB_GLARE syntax). Unknown names are skipped and returned in `bad`.
static func parse(text: String, bad: Array[String] = []) -> Dictionary:
	var out := {}
	for part in text.split(",", false):
		var p := part.strip_edges()
		match p:
			"none", "":
				out = {}
			"default":
				out = DEFAULTS.duplicate()
			"all":
				out = everything()
			_:
				var kv := p.split(":", true, 1)
				var name := StringName(kv[0])
				if BOOLS.has(name):
					out[name] = "1"
				elif CHOICES.has(name) and kv.size() == 2 and (CHOICES[name][1] as Array).has(kv[1]) and kv[1] != "tier":
					out[name] = kv[1]
				else:
					bad.append(p)
	return out


static func describe() -> String:
	_ensure()
	if _flags.is_empty():
		return "none"
	var parts: Array[String] = []
	for k: StringName in _flags:
		parts.append(String(k) if _flags[k] == "1" else "%s:%s" % [k, _flags[k]])
	parts.sort()
	return ",".join(parts)


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_flags = DEFAULTS.duplicate()
	if not OS.is_debug_build():
		return  # a release build runs the shipped set and nothing else
	var env := OS.get_environment(ENV)
	if env == "" and DisplayServer.get_name() == "headless":
		return  # probes run the shipped set unless a probe says otherwise
	if env != "":
		var bad: Array[String] = []
		_flags = parse(env, bad)
		for b in bad:
			push_warning("%s: unknown flag '%s'" % [ENV, b])
		return
	if persist:
		var cfg := ConfigFile.new()
		if cfg.load(path) == OK and cfg.has_section_key("glare", "flags"):
			_flags = parse(String(cfg.get_value("glare", "flags")))


static func _changed() -> void:
	if persist and OS.is_debug_build():
		var cfg := ConfigFile.new()
		cfg.set_value("glare", "flags", describe() if not _flags.is_empty() else "none")
		cfg.save(path)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group(GROUP, &"_on_glare_changed")


# --- applying ------------------------------------------------------------------------------------------------------------------
# Each handler switches one hypothesis on or off over the whole tree and puts back what it found when it is turned off: the first
# value a node showed is kept in its meta (`glare_was_<property>`), so turning a flag off restores exactly it, never a guess.

const _PFX := "glare_was_"
const NEAR_FIX := 0.1   ## a 24-bit buffer's resolution at distance z is z^2 / (near * 2^24): only the near plane buys any (the far plane, 4000, hardly costs)


static func apply(tree: SceneTree) -> void:
	_ensure()
	var root := tree.root
	var tier: Dictionary = QualityManager.TIERS[clampi(QualityManager.current_tier, 0, QualityManager.TIERS.size() - 1)]
	var glow_off: bool = on(&"glow_off") or not tier.glow
	var probes_off: bool = on(&"probes_off") or not tier.probes
	var shadow_off: bool = on(&"lamp_shadow_off") or not tier.shadow
	_each(root, "WorldEnvironment", func(n: WorldEnvironment) -> void:
		_force(n.environment, "glow_enabled", false, glow_off)
		_force(n.environment, "fog_enabled", false, on(&"fog_off")))
	_each(root, "ReflectionProbe", func(n: ReflectionProbe) -> void: _force(n, "visible", false, probes_off))
	_each(root, "LightmapGI", func(n: LightmapGI) -> void: _force(n, "visible", false, on(&"lightmap_off")))
	_each(root, "Light3D", func(n: Light3D) -> void:
		var baked := n.light_bake_mode == Light3D.BAKE_STATIC
		_force(n, "light_specular", 0.0, (baked and on(&"baked_spec_off")) or (not baked and on(&"lamp_spec_off")))
		if n.shadow_enabled or n.has_meta(_PFX + "shadow_enabled"):
			_force(n, "shadow_bias", 0.05, on(&"shadow_bias_hi"))
			_force(n, "shadow_normal_bias", 2.5, on(&"shadow_bias_hi"))
			_force(n, "shadow_enabled", false, shadow_off))
	_materials(root)
	_cameras(root)
	for name in [&"Mirror", &"Tv"]:
		var n := root.find_child(String(name), true, false) as Node3D
		if n != null:
			_force(n, "visible", false, on(&"mirror_off" if name == &"Mirror" else &"tv_off"))
	_force(root, "use_hdr_2d", false, on(&"hdr2d_off"))
	RenderingServer.screen_space_roughness_limiter_set_active(not on(&"rough_limiter_off"), 0.25, 0.18)


## The viewport settings a tier asks for, after the AA / MSAA / scale flags (QualityManager._apply_tier).
static func viewport_for(tier: Dictionary) -> Dictionary:
	var out := {scale = tier.scale, msaa = tier.msaa, aa = tier.aa}
	match choice(&"aa"):
		"none": out.aa = Viewport.SCREEN_SPACE_AA_DISABLED
		"fxaa": out.aa = Viewport.SCREEN_SPACE_AA_FXAA
		"smaa": out.aa = Viewport.SCREEN_SPACE_AA_SMAA
	match choice(&"msaa"):
		"off": out.msaa = Viewport.MSAA_DISABLED
		"2x": out.msaa = Viewport.MSAA_2X
		"4x": out.msaa = Viewport.MSAA_4X
	if on(&"scale_full"):
		out.scale = 1.0
	return out


static func _materials(root: Node) -> void:
	var spec := on(&"mat_spec_off")
	var nm := on(&"normalmap_off")
	if not spec and not nm and not _mats_touched:
		return  # nothing to switch and nothing of ours to put back: skip the walk over every mesh
	_mats_touched = spec or nm
	var seen := {}
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var mats: Array[Material] = [mi.material_override, mi.material_overlay]
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				mats.append(mi.get_surface_override_material(s))
				mats.append(mi.mesh.surface_get_material(s))
		for m in mats:
			if m is BaseMaterial3D and not seen.has(m.get_instance_id()):
				seen[m.get_instance_id()] = true
				_force(m, "metallic_specular", 0.0, spec)
				_force(m, "normal_enabled", false, nm)


## Cameras (the player's, the cutscenes', the skin preview's): near. The mirror's window camera (a frustum whose near plane IS the glass) and
## the TV feeds / the room capture (their own 0.05 / 40) are left to their owners.
static func _cameras(root: Node) -> void:
	for c: Camera3D in root.find_children("*", "Camera3D", true, false):
		if c.projection != Camera3D.PROJECTION_FRUSTUM and c.far >= 100.0:
			_force(c, "near", NEAR_FIX, on(&"depth_range"))


static func _each(root: Node, cls: String, f: Callable) -> void:
	for n in root.find_children("*", cls, true, false):
		f.call(n)


## `value` while `active`, the original (kept in meta) otherwise.
static func _force(obj: Object, prop: String, value: Variant, active: bool) -> void:
	if obj == null:
		return
	var key := _PFX + prop
	if active:
		if not obj.has_meta(key):
			obj.set_meta(key, obj.get(prop))
		obj.set(prop, value)
	elif obj.has_meta(key):
		obj.set(prop, obj.get_meta(key))
		obj.remove_meta(key)
