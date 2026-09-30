class_name Effect
extends Resource
## Docs/plan/03 §2.3. `owner_peer_id` and `target_id` are per-instance, so they live on the live
## instance in EffectManager, never on this shared resource.

enum SourceKind { DRINK, EVENT, WORLD }
enum Target { PLAYER, CUE, TABLE, BALL, POCKET, VIEW, STREAM }
enum Stacking { REFRESH, IGNORE }

@export var id: StringName
@export var source_kind: SourceKind = SourceKind.DRINK
@export var target: Target = Target.PLAYER
@export var stat_modifiers: Array[StatMod] = []
@export var duration_sec := 0.0  # 0 instant, -1 until Round end, -2 until the live Shot resolves
@export var stacking_rule: Stacking = Stacking.REFRESH
@export var exclusive_group := &""  # one live per group per subject; a new one replaces the old
@export var tag := &""  # classification only (`booze`); never exclusive
@export var clears_tag := &""  # instant: ends every live Effect carrying this tag on the subject
@export var visual_hook := &""


func requires_host() -> bool:
	return target != Target.VIEW
