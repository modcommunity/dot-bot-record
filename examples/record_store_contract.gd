extends RefCounted

## What every demonstration store has to do the same way, run by the offline suite (SQLite) and by `record_live.tscn` (PostgreSQL and MariaDB through the gateway).

## Checks [method run] makes.
const CHECKS := 11


static func episode(map_id: String, version: String, kind: String, key: String, score: float = 0.0, verified: bool = false) -> DotBotDemoEpisode:
	var e := DotBotDemoEpisode.new()
	e.map_id = map_id
	e.map_version = version
	e.schema_id = "abc123"
	e.kind = kind
	e.key = key
	e.start = {"pos": [1.5, 2.0, -3.0], "air": true}
	e.rate = 16.0
	e.frame_size = 3
	e.ticks = PackedFloat32Array([0.5, -1.25, 100.0, 0.75, 2.0, -8.5])
	e.outcome = "landed"
	e.day = "2026-10-21"
	e.verified = verified
	e.score = score
	return e


## What every store has to do the same way; [param fresh] opens another store on the same data.
static func run(store: DotBotDemoStore, fresh: Callable, label: String, check: Callable) -> void:
	var a := episode("surf_toy", "v1", "ride", "1>2", 0.2, true)
	var b := episode("surf_toy", "v1", "ride", "1>2", 0.9, true)
	var c := episode("surf_toy", "v1", "ride", "2>3")
	var old := episode("surf_toy", "v0", "ride", "1>2", 0.5, true)
	var other := episode("other_map", "v0", "ride", "1>2")
	var put: DotResult = await store.append([a, b, c, old, other])
	check.call(put.ok and put.value == 5, label + ": a batch is stored", str(put.error.message if not put.ok else put.value))
	check.call(a.id != 0 and a.id != b.id, label + ": every episode gets its own id")

	var again: DotBotDemoStore = await fresh.call()
	var opened: DotResult = await again.open()
	var got: DotResult = await again.load("surf_toy", "v1", "ride", "1>2", 10)
	var first: DotBotDemoEpisode = got.value[0] if got.ok and not (got.value as Array).is_empty() else null
	check.call(opened.ok and first != null and got.value.size() == 2, label + ": a second store reads both back", str(got.error.message if not got.ok else ""))
	check.call(first != null and first.id == b.id and first.score == 0.9 and first.ticks == b.ticks and first.start == b.start and first.frame_size == 3 and first.day == "2026-10-21", label + ": the round trip keeps every field, best score first")
	var one: DotResult = await again.load("surf_toy", "v1", "ride", "1>2", 1)
	check.call(one.ok and one.value.size() == 1, label + ": limit cuts the list")

	var cnt: DotResult = await again.counts("surf_toy", "v1", "ride")
	check.call(cnt.ok and cnt.value == {"1>2": 2, "2>3": 0}, label + ": counts are verified episodes per key", str(cnt.value))
	var stale: DotResult = await again.counts("surf_toy", "v2", "ride")
	var none: DotResult = await again.load("surf_toy", "v2", "ride", "1>2", 10)
	check.call(stale.ok and stale.value.is_empty() and none.ok and none.value.is_empty(), label + ": a different map version is a different, empty set")

	var marked: DotResult = await again.mark([c.id], true, 0.7)
	var cnt2: DotResult = await (await fresh.call()).counts("surf_toy", "v1", "ride")
	check.call(marked.ok and marked.value == 1 and cnt2.value == {"1>2": 2, "2>3": 1}, label + ": a verdict is kept for the next store", str(cnt2.value))
	var unmarked: DotResult = await again.mark([c.id], false, 0.0)
	var cnt3: DotResult = await again.counts("surf_toy", "v1", "ride")
	check.call(unmarked.ok and cnt3.value == {"1>2": 2, "2>3": 0}, label + ": a verdict can be withdrawn")

	var pruned: DotResult = await again.prune("surf_toy", "v1")
	var gone: DotResult = await (await fresh.call()).counts("surf_toy", "v0", "ride")
	var kept: DotResult = await (await fresh.call()).counts("surf_toy", "v1", "ride")
	var elsewhere: DotResult = await (await fresh.call()).load("other_map", "v0", "ride", "1>2", 10)
	check.call(pruned.ok and pruned.value == 1 and gone.value.is_empty(), label + ": prune drops the other versions of that map", str(pruned.value))
	check.call(kept.value.size() == 2 and elsewhere.value.size() == 1, label + ": and keeps the kept version and other maps")
