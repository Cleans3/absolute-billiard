class_name StagingPlan
extends RefCounted
## The schedule of a Round's set-up (06 P33 U16) and clean-up (U15): pure functions of the clock and the ball count, no nodes. Every peer
## computes the same picture from data it already has (the pushed rack, ordered by net_id, and the moment its staging started), and a probe
## can ask any instant without waiting for it. Budgets (A4): set-up <= SETUP_MAX_SEC, clean-up <= CLEANUP_MAX_SEC, any ball count.

const SETUP_MAX_SEC := 5.0
const CLEANUP_MAX_SEC := 3.0

# --- set-up: the vent opens, the saucer flies out, the vent shuts behind it, the saucer beams the balls in one by one, then dematerialises
const VENT_OPEN_SEC := 0.55
const UFO_SHOW_AT := 0.30       ## the saucer is on show once the louvres have started to part
const UFO_OUT_FROM := 0.50      ## it starts down through the mouth once the louvres are (all but) fully apart ...
const UFO_OUT_TO := 1.55        ## ... and has reached its hover over the table
const VENT_CLOSE_AT := 1.10     ## the louvres slide shut once it is clear of the mouth
const VENT_CLOSE_SEC := 0.45
const BEAM_FROM := 1.55
const BEAM_WINDOW := 2.20       ## every reveal starts inside [BEAM_FROM, BEAM_FROM + BEAM_WINDOW)
const BEAM_STEP_MAX := 0.30     ## a small rack is not rushed: at most this long per ball
const MATERIALISE_SEC := 0.40
const FAREWELL_SEC := 0.60      ## the beam goes dark and the saucer dematerialises

# --- clean-up: the bed splits into FLAPS hinged flaps that drop open from the middle outward, the balls fall into the pit, the flaps close
const FLAPS := 8                ## across the table's width; each flap hangs inside the 0.34 m the apron leaves under the bed
const RANKS := 4                ## FLAPS / 2: flap pairs counted from the middle outward
const OPEN_AT := 0.25
const OPEN_SEC := 0.40
const RIPPLE_SEC := 0.05        ## per flap rank, middle flaps first (opening) / outer flaps first (closing)
const OPEN_DEG := 92.0
const RELEASE_DEG := 14.0       ## a ball leaves its flap once the flap has tilted this far
const JITTER_SEC := 0.05        ## a ball's own release lag, from its net_id (the balls do not drop in lockstep)
const SHUT_AT := 1.40
const SHUT_SEC := 0.50
const TAIL_SEC := 0.25
const CLEANUP_SEC := SHUT_AT + SHUT_SEC + RIPPLE_SEC * (RANKS - 1) + TAIL_SEC
const FALL_G := 8.0             ## m/s²: how hard the pit pulls a ball (a little slower than gravity so the fall reads)


# ---------------------------------------------------------------- set-up

static func beam_step(n: int) -> float:
	return minf(BEAM_STEP_MAX, BEAM_WINDOW / maxf(float(n), 1.0))


## Second at which ball `i` (of `n`, in net_id order) starts to materialise.
static func reveal_start(i: int, n: int) -> float:
	return BEAM_FROM + float(i) * beam_step(n)


## 0 = not there, 1 = solid, for ball `i` at set-up time `t`.
static func ball_progress(i: int, n: int, t: float) -> float:
	return clampf((t - reveal_start(i, n)) / MATERIALISE_SEC, 0.0, 1.0)


## Second at which the last ball is solid.
static func last_in(n: int) -> float:
	return reveal_start(maxi(n, 1) - 1, maxi(n, 1)) + MATERIALISE_SEC


static func setup_duration(n: int) -> float:
	return last_in(n) + FAREWELL_SEC


static func louvre_ease(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


## 0 closed .. 1 open: the louvres slide apart, stay, and slide shut once the saucer is out.
static func vent_openness(t: float) -> float:
	return louvre_ease(t / VENT_OPEN_SEC) * (1.0 - louvre_ease((t - VENT_CLOSE_AT) / VENT_CLOSE_SEC))


## 0..1 along the saucer's flight from inside the vent to its hover (eased out).
static func ufo_flight(t: float) -> float:
	var u := clampf((t - UFO_OUT_FROM) / (UFO_OUT_TO - UFO_OUT_FROM), 0.0, 1.0)
	return 1.0 - pow(1.0 - u, 3.0)


## 1 = solid, falling to 0 as the saucer dematerialises after the last ball is in.
static func ufo_solid(t: float, n: int) -> float:
	return 1.0 - louvre_ease((t - last_in(n)) / FAREWELL_SEC)


static func ufo_visible(t: float, n: int) -> bool:
	return t >= UFO_SHOW_AT and t < setup_duration(n)


## 0..1: how strongly the beam shines (fades in just before the first ball, out as the last one lands).
static func beam_strength(t: float, n: int) -> float:
	var on := clampf((t - (BEAM_FROM - 0.25)) / 0.25, 0.0, 1.0)
	var off := clampf((t - last_in(n)) / 0.2, 0.0, 1.0)
	return on * (1.0 - off)


## The beam's aim as a fractional ball index: it rests on ball i while i materialises and glides to i+1 for the next.
static func beam_focus(t: float, n: int) -> float:
	var f := clampf((t - BEAM_FROM) / beam_step(n), 0.0, maxf(float(n) - 1.0, 0.0))
	var i := floorf(f)
	return i + louvre_ease(f - i) if i < float(n) - 1.0 else f


# ---------------------------------------------------------------- clean-up

## Flap `k` (0 = the lowest table-local z) counted from the middle: 0 for the two middle flaps, RANKS - 1 for the outermost two.
static func flap_rank(k: int) -> int:
	return int(absf(float(k) - (float(FLAPS) - 1.0) * 0.5) - 0.5)


static func flap_open_start(k: int) -> float:
	return OPEN_AT + RIPPLE_SEC * float(flap_rank(k))


static func flap_shut_start(k: int) -> float:
	return SHUT_AT + RIPPLE_SEC * float(RANKS - 1 - flap_rank(k))


## Flap `k`'s tilt in radians at clean-up time `t`: 0 flat, OPEN_DEG hanging. It drops like a trapdoor (u²) and closes eased out.
static func flap_angle(k: int, t: float) -> float:
	var open_u := clampf((t - flap_open_start(k)) / OPEN_SEC, 0.0, 1.0)
	var a := deg_to_rad(OPEN_DEG) * open_u * open_u
	var shut_u := clampf((t - flap_shut_start(k)) / SHUT_SEC, 0.0, 1.0)
	if shut_u > 0.0:
		a = deg_to_rad(OPEN_DEG) * pow(1.0 - shut_u, 2.0)
	return a


## Second at which a ball on flap `k` leaves it. `net_id` spreads the releases over JITTER_SEC without a random number.
static func release_time(k: int, net_id: int) -> float:
	var tilt_u := sqrt(RELEASE_DEG / OPEN_DEG)
	return flap_open_start(k) + OPEN_SEC * tilt_u + JITTER_SEC * float(posmod(net_id * 7, 6)) / 5.0
