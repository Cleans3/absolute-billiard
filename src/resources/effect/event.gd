class_name Event
extends Resource
## Docs/plan/03 §2.5.

enum Opportunity { NONE, NEXT_POT, RANDOM_POCKET }

@export var id: StringName
@export var display_name := ""
@export var story_line := ""  ## 09 §3.4: who sent it, shown under the name on the vote card and the blackboard; no mechanical effect
@export var tier := 1
@export var effects: Array[Effect] = []
@export var reward_mult := 1.0
@export var min_night := 1
@export var scripted_first := false
@export var round_time_add_sec := 0.0
@export var warning_lead_time_sec := 3.0
@export var opportunity: Opportunity = Opportunity.NONE
@export var opportunity_mult := 1.0
