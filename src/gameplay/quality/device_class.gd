class_name DeviceClass
extends RefCounted

## Where a device starts on QualityManager's tiers (07 §7.6, adhoc-1014a V11). "Auto" used to start every device at tier 0 and wait for
## the ladder to notice, one 10 s window per step, on every launch: a low-end phone spent its first 20 s laggy each session.
## Now: a name heuristic (GPU adapter, cores, RAM, renderer) gives the first launch's start tier, and QualityManager measures the
## real frame cost for ~3 s on that first launch and keeps the result (`user://device_class.cfg`): later launches start there, and the
## ladder never recovers past it (a measured tier is a ceiling, the ladder still degrades below it on heat).

const FILE := "user://device_class.cfg"
const VERSION := 1                    ## bump to measure again
const WARMUP_S := 1.5                 ## first-draw hitches (shader compiles) are not the device
const BENCH_S := 3.0
const HEADROOM := 1.1                 ## a tier holds when the frame costs at most its budget / this
const PROMOTE_AT := 0.5               ## ... and the device is faster than a tier up when it costs under budget * this

static var path := FILE
static var enabled := true            ## probes and tools turn the first-run benchmark off


## The GPU names whose first launch should not start at tier 0 (lower-case substrings). 2 = a weak GPU: tier 2, 1 = a middling one.
const WEAK: Array[String] = ["swiftshader", "llvmpipe", "lavapipe", "software", "mali-t", "mali-g31", "mali-g51", "mali-g52", "powervr", "adreno (tm) 3", "adreno (tm) 4", "adreno (tm) 5", "adreno (tm) 60", "adreno (tm) 61", "videocore", "vivante"]
const MIDDLING: Array[String] = ["mali-g57", "mali-g68", "mali-g72", "mali-g76", "adreno (tm) 62", "adreno (tm) 63", "adreno (tm) 64", "intel(r) hd", "intel(r) uhd", "intel hd", "intel uhd", "apple a10", "apple a11"]


## Pure: the tier a device with this adapter name, core count, physical RAM (MB, -1 unknown) and rendering method starts at.
static func heuristic_tier(adapter: String, cores: int, ram_mb: int, method: String) -> int:
	var a := adapter.to_lower()
	var t := 0
	for w in WEAK:
		if a.contains(w):
			t = 2
	if t == 0:
		for m in MIDDLING:
			if a.contains(m):
				t = 1
	if cores > 0 and cores <= 4:
		t = maxi(t, 1)
	if ram_mb > 0 and ram_mb <= 3200:
		t = maxi(t, 1)
	if ram_mb > 0 and ram_mb <= 2200:
		t = maxi(t, 2)
	if method == "gl_compatibility":
		t = maxi(t, 1)   # the fallback renderer (no Vulkan): a phone that lands here is an old one, and its lights all run live
	return t


## Pure: the tier to settle on after measuring `cost_ms` (the slowest of GPU time and CPU render+process time, median over the
## benchmark) at tier `at`. A tier's budget is its fps cap's frame time; one that costs more than budget / HEADROOM is too heavy,
## below budget * PROMOTE_AT a tier up fits.
static func tier_from_cost(at: int, cost_ms: float) -> int:
	var budget := 1000.0 / (30.0 if at >= 2 else 60.0)
	if cost_ms > budget / 0.6:
		return mini(at + 2, 2)
	if cost_ms > budget / HEADROOM:
		return mini(at + 1, 2)
	if at > 0 and cost_ms <= budget * PROMOTE_AT:
		return at - 1
	return at


static func adapter() -> String:
	return RenderingServer.get_video_adapter_name()


static func start_heuristic() -> int:
	if DisplayServer.get_name() == "headless":
		return 0   # no renderer to name: every probe starts where it always did
	return heuristic_tier(adapter(), OS.get_processor_count(), int(int(OS.get_memory_info().get("physical", -1)) / 1048576), RenderingServer.get_current_rendering_method())


## {tier, ms, adapter, version, benchmarked} from the last launch that measured, or {} (none, another GPU, another version).
static func saved() -> Dictionary:
	var cfg := ConfigFile.new()
	if DisplayServer.get_name() == "headless" or cfg.load(path) != OK or int(cfg.get_value("device", "version", 0)) != VERSION or String(cfg.get_value("device", "adapter", "")) != adapter():
		return {}
	return {tier = int(cfg.get_value("device", "tier", 0)), ms = float(cfg.get_value("device", "ms", 0.0)), adapter = adapter(), benchmarked = true}


## The tier Auto starts at: what an earlier launch measured, else the name heuristic.
static func start_tier() -> int:
	var s := saved()
	return int(s.tier) if not s.is_empty() else start_heuristic()


static func needs_benchmark() -> bool:
	return enabled and DisplayServer.get_name() != "headless" and saved().is_empty()


static func save(tier: int, cost_ms: float) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("device", "version", VERSION)
	cfg.set_value("device", "adapter", adapter())
	cfg.set_value("device", "tier", tier)
	cfg.set_value("device", "ms", snappedf(cost_ms, 0.01))
	cfg.save(path)
