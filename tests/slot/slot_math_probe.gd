extends SceneTree
## SlotMath (docs/plan/02 §3.8): the house keeps an edge, every win id is reachable and priced, the tiers scale with the
## Quota, the timings hold. `godot --path . --headless -s tests/slot/slot_math_probe.gd`

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		push_error("FAIL: " + what)
		print("FAIL: ", what)


func _init() -> void:
	var n := SlotMath.STRIP.size()
	var counts := {}
	for s in SlotMath.STRIP:
		counts[s] = int(counts.get(s, 0)) + 1
	_check(n == 24 and counts.size() == SlotMath.Sym.size(), "24 faces, every symbol on the drum: %s" % [counts])
	_check(SlotMath.TRIPLE.size() == SlotMath.Sym.size(), "a triple win per symbol")
	for id: StringName in SlotMath.TRIPLE:
		_check(SlotMath.WINS.has(id), "triple '%s' is priced" % id)

	# every stop triple: RTP, hit rate and which wins occur (a win id nothing can reach is dead data)
	var seen := {}
	var hits := 0
	for a in n:
		for b in n:
			for c in n:
				var win := SlotMath.evaluate(PackedInt32Array([a, b, c]))
				seen[win] = int(seen.get(win, 0)) + 1
				if int(SlotMath.WINS[win].mult) > 0:
					hits += 1
	for id: StringName in SlotMath.WINS:
		_check(seen.has(id), "win '%s' is reachable" % id)
	var rtp := SlotMath.rtp()
	var hit_rate := float(hits) / float(n * n * n)
	_check(rtp >= 0.85 and rtp <= 0.95, "house edge 5-15%% (RTP %.4f)" % rtp)
	_check(hit_rate >= 0.4 and hit_rate <= 0.65, "something pays about every other spin (%.3f)" % hit_rate)
	_check(is_equal_approx(float(seen[&"jackpot"]) / float(n * n * n), 1.0 / 1728.0), "the jackpot is 1 in 1728")

	# a seeded roll is reproducible, in range, and the Monte Carlo agrees with the enumeration
	var r1 := RandomNumberGenerator.new()
	var r2 := RandomNumberGenerator.new()
	r1.seed = 42
	r2.seed = 42
	var paid := 0.0
	var spins := 200000
	for i in spins:
		var s1 := SlotMath.roll(r1)
		_check(s1 == SlotMath.roll(r2) and s1.size() == SlotMath.REELS, "same seed, same stops")
		for stop in s1:
			if stop < 0 or stop >= n:
				_check(false, "stop %d out of range" % stop)
		paid += SlotMath.payout(SlotMath.evaluate(s1), 1)
	_check(absf(paid / spins - rtp) < 0.06, "Monte Carlo %.3f within noise of the exact %.3f" % [paid / spins, rtp])

	# evaluation rules by example (stop = first index of a symbol on the strip)
	var at := {}
	for i in range(n - 1, -1, -1):
		at[SlotMath.STRIP[i]] = i
	var S := SlotMath.Sym
	_check(SlotMath.evaluate(PackedInt32Array([at[S.EIGHT], at[S.EIGHT], at[S.EIGHT]])) == &"jackpot", "888 is the jackpot")
	_check(SlotMath.evaluate(PackedInt32Array([at[S.EIGHT], at[S.EIGHT], at[S.LEMON]])) == &"wild", "88x is wild")
	_check(SlotMath.evaluate(PackedInt32Array([at[S.SKULL], at[S.CHERRY], at[S.SKULL]])) == &"zap", "two skulls zap, even with a cherry")
	_check(SlotMath.evaluate(PackedInt32Array([at[S.SKULL], at[S.SKULL], at[S.SKULL]])) == &"cursed", "three skulls are cursed")
	_check(SlotMath.evaluate(PackedInt32Array([at[S.CHERRY], at[S.LEMON], at[S.CHERRY]])) == &"cherry2", "two cherries")
	_check(SlotMath.evaluate(PackedInt32Array([at[S.LEMON], at[S.BELL], at[S.CHERRY]])) == &"cherry1", "one cherry is the bet back")
	_check(SlotMath.evaluate(PackedInt32Array([at[S.LEMON], at[S.BELL], at[S.BAR]])) == &"miss", "a mix misses")
	_check(SlotMath.payout(&"cherry1", 30) == 30 and SlotMath.payout(&"sevens", 30) == 1200 and SlotMath.payout(&"miss", 30) == 0, "payout = mult x bet")

	# bet tiers follow the Night's Quota (N1 600 ... N5 3000), ascending, snapped to $5
	for quota in [600, 900, 1350, 2000, 3000]:
		var bets := SlotMath.bets(quota)
		_check(bets.size() == 3 and bets[0] < bets[1] and bets[1] < bets[2], "three ascending tiers at quota %d: %s" % [quota, bets])
		for b in bets:
			_check(b % SlotMath.BET_STEP == 0 and b >= SlotMath.BET_MIN, "tier $%d is a $5 step, not under the floor" % b)
	_check(Array(SlotMath.bets(600)) == [10, 30, 60], "Night 1 stakes $10 / $30 / $60: %s" % [SlotMath.bets(600)])
	_check(SlotMath.bets(40)[0] == SlotMath.BET_MIN, "a tiny Quota still stakes the floor")

	# timings: the drums stop in order, a tease keeps the last one going, the reveal waits for it
	var plain := PackedInt32Array([at[S.LEMON], at[S.BELL], at[S.BAR]])
	var tease := PackedInt32Array([at[S.LEMON], at[S.LEMON], at[S.BAR]])
	var triple := PackedInt32Array([at[S.LEMON], at[S.LEMON], at[S.LEMON]])
	_check(not SlotMath.teases(plain) and SlotMath.teases(tease) and not SlotMath.teases(triple), "tease = first two match, third does not")
	_check(SlotMath.reel_stop_at(0, tease) < SlotMath.reel_stop_at(1, tease) and SlotMath.reel_stop_at(1, tease) < SlotMath.reel_stop_at(2, plain), "drums stop left to right")
	_check(is_equal_approx(SlotMath.spin_sec(tease) - SlotMath.spin_sec(plain), SlotMath.TEASE_EXTRA), "the tease costs TEASE_EXTRA seconds")
	_check(SlotMath.spin_sec(tease) < 5.0, "a spin never takes 5 s (%.1f)" % SlotMath.spin_sec(tease))

	print("SLOT MATH %s (RTP %.4f, hit rate %.3f, jackpot 1/%d)" % ["OK" if _fails == 0 else "FAILED", rtp, hit_rate, n * n * n / int(seen[&"jackpot"])])
	quit(0 if _fails == 0 else 1)
