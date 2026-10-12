class_name SlotMath
extends RefCounted
## The bar slot's rules, pure and static (docs/plan/02 §3.9): reels, paytable, bet tiers, timings. The host rolls with
## it, every peer replays the stops from the payload, `tests/slot/slot_probe.gd` enumerates it for the exact RTP.

enum Sym { CHERRY, LEMON, BELL, BAR, SEVEN, EIGHT, SKULL }

const REELS := 3
## One virtual strip shared by the three reels (24 faces on each drum). A stop is an index into it.
const STRIP: Array[int] = [
	Sym.CHERRY, Sym.LEMON, Sym.BELL, Sym.SKULL, Sym.CHERRY, Sym.LEMON, Sym.BAR, Sym.EIGHT,
	Sym.CHERRY, Sym.LEMON, Sym.BELL, Sym.SEVEN, Sym.CHERRY, Sym.LEMON, Sym.SKULL, Sym.BELL,
	Sym.BAR, Sym.CHERRY, Sym.EIGHT, Sym.SEVEN, Sym.LEMON, Sym.BELL, Sym.BAR, Sym.SKULL,
]
const SYMBOL_NAMES: Array[String] = ["Cherry", "Lemon", "Bell", "Bar", "Seven", "8-Ball", "Skull"]
const TRIPLE: Array[StringName] = [&"cherries", &"lemons", &"bells", &"open_bar", &"sevens", &"jackpot", &"cursed"]

## Win id -> title, payout (x bet) and the chaos that fires with it (SlotHouse names what each one does).
const WINS := {
	&"jackpot": {title = "8-BALL JACKPOT", mult = 120, chaos = [&"crew_round", &"hype", &"event"]},
	&"sevens": {title = "TRIPLE SEVEN", mult = 40, chaos = [&"hype"]},
	&"cursed": {title = "CURSED PAYOUT", mult = 15, chaos = [&"zap", &"mystery"]},
	&"open_bar": {title = "OPEN BAR", mult = 14, chaos = [&"drink"]},
	&"bells": {title = "BELLS", mult = 7, chaos = []},
	&"cherries": {title = "CHERRY PIE", mult = 4, chaos = []},
	&"lemons": {title = "LEMONADE", mult = 4, chaos = []},
	&"wild": {title = "WILD 8-BALLS", mult = 3, chaos = [&"drink"]},
	&"cherry2": {title = "TWO CHERRIES", mult = 2, chaos = [&"hype"]},
	&"cherry1": {title = "CHERRY BACK", mult = 1, chaos = []},
	&"zap": {title = "SHORT CIRCUIT", mult = 0, chaos = [&"zap"]},
	&"miss": {title = "NO LUCK", mult = 0, chaos = []},
}

## Bet tiers as a share of the Night's Quota, so the stake scales with the Night (snapped to $5, never under $10).
const BET_RATES: Array[float] = [0.02, 0.05, 0.10]
const BET_STEP := 5
const BET_MIN := 10

## Seconds from the spin to each reel's stop; a near-miss (first two reels match) keeps the third drum going longer.
const STOP_AT: Array[float] = [0.9, 1.4, 1.9]
const TEASE_EXTRA := 0.7
const SETTLE_SEC := 0.4  ## the drum's last bounce, then the readout
const MAX_SPIN_SEC := 1.9 + 0.7 + 0.4  ## the longest spin: a tease (STOP_AT[2] + TEASE_EXTRA + SETTLE_SEC; the probe checks it); 3.0 s, the playtest's target


## Win id of three stops.
static func evaluate(stops: PackedInt32Array) -> StringName:
	var a: int = STRIP[stops[0]]
	var b: int = STRIP[stops[1]]
	var c: int = STRIP[stops[2]]
	if a == b and b == c:
		return TRIPLE[a]
	var syms := [a, b, c]
	if syms.count(Sym.EIGHT) == 2:
		return &"wild"
	if syms.count(Sym.SKULL) == 2:
		return &"zap"
	match syms.count(Sym.CHERRY):
		2:
			return &"cherry2"
		1:
			return &"cherry1"
	return &"miss"


static func roll(rng: RandomNumberGenerator) -> PackedInt32Array:
	var stops := PackedInt32Array()
	for i in REELS:
		stops.append(rng.randi_range(0, STRIP.size() - 1))
	return stops


static func payout(win: StringName, bet: int) -> int:
	return int(WINS[win].mult) * bet


## The three stakes for a Night with this Quota.
static func bets(quota: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for rate in BET_RATES:
		out.append(maxi(BET_MIN, roundi(quota * rate / BET_STEP) * BET_STEP))
	return out


## First two reels agree and the third is not a win yet: the last drum crawls.
static func teases(stops: PackedInt32Array) -> bool:
	return STRIP[stops[0]] == STRIP[stops[1]] and STRIP[stops[1]] != STRIP[stops[2]]


## Seconds the reels run for these stops: the host reveals the payout when the last drum lands (`reveal_sec`).
static func reel_stop_at(reel: int, stops: PackedInt32Array) -> float:
	return STOP_AT[reel] + (TEASE_EXTRA if reel == REELS - 1 and teases(stops) else 0.0)


static func reveal_sec(stops: PackedInt32Array) -> float:
	return reel_stop_at(REELS - 1, stops)


static func spin_sec(stops: PackedInt32Array) -> float:
	return reveal_sec(stops) + SETTLE_SEC


## Expected return of one unit of bet over every stop triple (the drums are independent and uniform).
static func rtp() -> float:
	var n := STRIP.size()
	var total := 0.0
	for a in n:
		for b in n:
			for c in n:
				total += payout(evaluate(PackedInt32Array([a, b, c])), 1)
	return total / float(n * n * n)
