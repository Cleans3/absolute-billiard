class_name StoryNight
extends Resource
## One Night's story text (docs/plan/09 §2.3, script in Appendix A). `night` 1..3 (the Campaign); 0 = the shared Endless resource.
## No money amounts in any text: the numbers live on the NightConfig and the blackboard, and get recalibrated (story_data_probe checks).
## An empty field means "nothing this Night": no cards, no call, no extra Gus lines, the plain Reckoning / Game over text.

@export var night := 1
@export var intro_cards: Array[String] = []  ## shown at NIGHT_START, before the Intermission: at most 4, 140 characters each
@export var call: Array[String] = []  ## Moe on the phone, one subtitle per line
@export var gus_lines: Array[String] = []  ## extra ambient lines for Gus, unlocked from this Night on
@export var paid_line := ""  ## the Reckoning line when the Quota is met (Night 3 reads it in Endless; the Campaign's Night 3 plays the ending instead)
@export var short_line := ""  ## the Game over line (Moe collects)
@export var chat_line := ""  ## the one stream-chat message from the viewer "velvet"
@export var ending_cards: Array[String] = []  ## the finale's (Night 3) three ending cards after the Buyout: StoryDirector shows them over the Campaign won screen; F3b plays them as the truck ride's captions
