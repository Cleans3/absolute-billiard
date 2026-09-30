extends SceneTree

## BallEventCodec round-trip: size, position error ≤ 0.1 mm, flags, ids, tick offsets, full frame.
##   godot --path . --headless -s tests/sync/codec_probe.gd

func _init() -> void:
	var origin := Vector3(0.3, 0.9, -0.2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var buf := PackedByteArray()
	BallEventCodec.begin(buf, 513, 4_000_000_000)
	assert(buf.size() == BallEventCodec.HEADER_SIZE)
	var src: Array[BallMotion.State] = []
	for i in 40:
		var s := BallMotion.State.new()
		s.pos = origin + Vector3(rng.randf_range(-2.6, 2.6), rng.randf_range(0.0, 0.3), rng.randf_range(-1.4, 1.4))
		s.lin = Vector3(rng.randf_range(-10, 10), rng.randf_range(-2, 2), rng.randf_range(-10, 10))
		s.ang = Vector3(rng.randf_range(-170, 170), rng.randf_range(-60, 60), rng.randf_range(-170, 170))
		src.append(s)
		assert(BallEventCodec.append(buf, i, i % 4, i * 1000, s, origin))
	assert(buf.size() == BallEventCodec.HEADER_SIZE + 40 * BallEventCodec.EVENT_SIZE and BallEventCodec.EVENT_SIZE == 21)
	assert(BallEventCodec.shot_id(buf) == 513 and BallEventCodec.base_tick(buf) == 4_000_000_000 and BallEventCodec.count(buf) == 40)
	var out := BallMotion.State.new()
	var worst := 0.0
	for i in 40:
		assert(BallEventCodec.ball_id(buf, i) == i and BallEventCodec.flag(buf, i) == i % 4 and BallEventCodec.tick_offset(buf, i) == i * 1000)
		BallEventCodec.read_state(buf, i, origin, out)
		worst = maxf(worst, out.pos.distance_to(src[i].pos))
		assert(out.lin.distance_to(src[i].lin) < 0.001 and out.ang.distance_to(src[i].ang) < 0.03)
		var q := BallMotion.State.new()
		q.copy_from(src[i])
		BallEventCodec.quantize(q, origin)
		assert(q.pos.is_equal_approx(out.pos) and q.lin.is_equal_approx(out.lin) and q.ang.is_equal_approx(out.ang), "quantize != decode")
	print("codec: max pos err %.4f mm, %d B for 40 events" % [worst * 1000.0, buf.size()])
	assert(worst <= 0.0001, "position error > 0.1 mm")
	for i in 215:
		assert(BallEventCodec.append(buf, 1, 0, 0, src[0], origin))
	assert(not BallEventCodec.append(buf, 1, 0, 0, src[0], origin), "frame must refuse the 256th event")
	print("CODEC OK")
	quit()
