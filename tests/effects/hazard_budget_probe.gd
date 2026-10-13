extends "res://tests/effects/hazard_probe.gd"

## The `budget` section of hazard_probe.gd on its own (events per break with each hazard on against the plain table, fail past 1.5x; the
## client within 5 mm of the host; Double Ball against the plain 12-ball rack). A run is ~3 minutes, so it is its own probe.
##   godot --path . --headless -s tests/effects/hazard_budget_probe.gd [-- --variant=sunken]
## Prints HAZARD OK, or the failing checks and HAZARD FAIL (exit 1).


func _default_sections() -> PackedStringArray:
	return PackedStringArray(["budget"])
