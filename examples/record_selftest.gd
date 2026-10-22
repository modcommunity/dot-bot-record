extends Node

## dot-bot-record's suite: the schema, the adaptive rate, the recorder, the batching, the three stores and the off switch.
##
## [codeblock]
## godot --headless --path . res://examples/record_selftest.tscn
## [/codeblock]

const CHECKS := 96

## Of CHECKS, the ones that need dot-sql and the SQLite extension linked into this project.
const SQL_CHECKS := 13

## Sections entered against sections that ran to their last line.
const SECTIONS := 7

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _sql_ran := false
var _entered := 0
var _completed := 0


## A cvar shaped like dot-server's DotConVar.
class FakeCvar:
	extends RefCounted
	signal changed(old_value: String, new_value: String)
	var name := ""
	var value := ""
	var lo := -INF
	var hi := INF
	var validator := Callable()

	func with_range(a: float, b: float) -> FakeCvar:
		lo = a
		hi = b
		return self

	func with_validator(v: Callable) -> FakeCvar:
		validator = v
		return self

	func get_string() -> String:
		return value

	func set_value(text: String) -> DotResult:
		var t := text.strip_edges()
		if t.is_valid_float() and (lo > -INF or hi < INF):
			t = str(clampf(t.to_float(), lo, hi))
		if validator.is_valid():
			var r: DotResult = validator.call(t)
			if not r.ok:
				return r
		force_set(t)
		return DotResult.success(t)

	func force_set(text: String) -> void:
		var old := value
		value = text
		if old != value:
			changed.emit(old, value)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-bot-record self-test")
	print("")

	_test_demo_schema()
	_test_demo_rate()
	await _test_demo_record()
	await _test_demo_batching()
	_test_demo_off_and_privacy()
	await _test_demo_store_json()
	await _test_demo_store_sql()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	print("%d of %d sections ran to their last line" % [_completed, _entered])

	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	var expected := CHECKS - (0 if _sql_ran else SQL_CHECKS)
	if _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, expected])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


class SlowStore:
	extends DotBotDemoStoreMemory
	var cost_usec := 3000

	func append(batch: Array) -> DotResult:
		var t := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t < cost_usec:
			pass
		return super.append(batch)


## A store that is down.
class DownStore:
	extends DotBotDemoStore

	func append(_batch: Array) -> DotResult:
		return DotResult.fail(DotError.CODE_IO, "down")


func _demo_schema() -> DotBotDemoSchema:
	var sc := DotBotDemoSchema.make("ride", 1)
	sc.add_observation("pos", 3, 100.0).add_observation("vel", 3, 20.0)
	sc.add_action("move", 2).add_action("buttons", 1, 1.0, true)
	return sc


## A server recorder with one registered schema, in memory, ticking at 64 Hz.
func _demo_recorder(store: DotBotDemoStore = null) -> DotBotDemoRecorder:
	var rec := DotBotDemoRecorder.new(DotBotDemoConfig.new(), store if store != null else DotBotDemoStoreMemory.new())
	rec.is_server = true
	rec.tick_rate = 64.0
	rec.set_map("surf_toy", "v1")
	var _r := rec.register(_demo_schema())
	return rec


## Feeds [param n] ticks of a toy ride to [param subject].
func _demo_ride(rec: DotBotDemoRecorder, subject: Variant, n: int, buttons: float = 0.0) -> int:
	var kept := 0
	for t in n:
		var obs := PackedFloat32Array([t, 0, 0, 1, 0, 0])
		var act := PackedFloat32Array([1.0, float(t % 2), buttons])
		if rec.sample(subject, obs, act, t):
			kept += 1
	return kept


func _test_demo_schema() -> void:
	_section("demonstration schema: validated, hashed, sized")
	var sc := _demo_schema()
	_check(sc.validate().ok and sc.frame_size() == 9 and sc.observation_size() == 6 and sc.action_size() == 3, "a good schema validates and sizes its frame", str(sc.frame_size()))
	_check(not DotBotDemoSchema.make("", 1).add_observation("a").add_action("b").validate().ok, "an empty kind is refused")
	_check(not DotBotDemoSchema.make("x", 1).add_observation("a").validate().ok, "a schema with no action is refused")
	_check(not DotBotDemoSchema.make("x", 1).add_observation("a").add_action("a").validate().ok, "a repeated field name is refused")
	_check(not DotBotDemoSchema.make("x", 1).add_observation("a", 0).add_action("b").validate().ok, "a field of size 0 is refused")
	_check(not DotBotDemoSchema.make("x", 1).add_observation("a", 1, 0.0).add_action("b").validate().ok, "a scale of 0 is refused")
	var other := _demo_schema().add_action("extra")
	_check(sc.schema_id() == _demo_schema().schema_id() and sc.schema_id() != other.schema_id(), "the id is a hash of the fields")
	var rec := _demo_recorder()
	_check(rec.register(DotBotDemoSchema.make("bad", 1)).code() == DotError.CODE_INVALID, "the recorder refuses to register a bad schema")
	_done()


func _test_demo_rate() -> void:
	_section("demonstration rate: full tick rate at first, base rate at the target")
	var rec := _demo_recorder()
	_check(is_equal_approx(rec.rate_for("ride", "17>9"), 64.0), "an edge with no verified rides is kept at the tick rate")
	rec.note_verified("ride", "17>9", 20)
	_check(is_equal_approx(rec.rate_for("ride", "17>9"), 40.0), "half way to 40 verified is half way down", str(rec.rate_for("ride", "17>9")))
	rec.note_verified("ride", "17>9", 20)
	_check(is_equal_approx(rec.rate_for("ride", "17>9"), 16.0), "40 verified is the base rate")
	rec.note_verified("ride", "17>9", 100)
	_check(is_equal_approx(rec.rate_for("ride", "17>9"), 16.0), "and it never falls below it")
	_check(is_equal_approx(rec.rate_for("ride", "other"), 64.0), "another edge is unaffected")
	_check(rec.stride_for(64.0) == 1 and rec.stride_for(16.0) == 4 and rec.stride_for(40.0) == 2, "a kept sample is every round(tick/rate)th tick")
	var mono := true
	var last := 1000.0
	for n in range(0, 60, 5):
		var fresh := _demo_recorder()
		fresh.note_verified("ride", "e", n)
		var r := fresh.rate_for("ride", "e")
		mono = mono and r <= last
		last = r
	_check(mono, "the rate never rises as the count does")
	var cfg := DotBotDemoConfig.new()
	_check(cfg.rate == 16.0 and cfg.target == 40 and cfg.cap == 200 and cfg.record, "defaults: 16 Hz, 40 per edge, 200 kept, ON")
	cfg.rate_max = 8.0
	_check(not cfg.validate().ok, "a top rate under the base rate is refused")
	_done()


func _test_demo_record() -> void:
	_section("demonstration recording: a fake host records, a bot is refused")
	var store := DotBotDemoStoreMemory.new()
	var rec := _demo_recorder(store)
	rec.include_fn = FakeHost._is_human
	_check(rec.begin(7, "ride", "17>9", {"pos": [1, 2, 3]}).ok, "a human's ride begins")
	var kept := _demo_ride(rec, 7, 64, 2.0)
	_check(kept == 64, "the first ride on an edge keeps every tick", str(kept))
	var res := rec.end(7, "landed", "17>9")
	_check(res.ok and rec.queued() == 1 and rec.recorded == 1, "ending it queues one episode")
	var flushed: DotResult = await rec.flush_all()
	_check(flushed.ok and store.episodes.size() == 1, "and a flush stores it", str(flushed))
	var e := store.episodes[0] as DotBotDemoEpisode
	_check(e.kind == "ride" and e.key == "17>9" and e.outcome == "landed" and e.map_id == "surf_toy" and e.map_version == "v1" and e.day.length() == 10,
		"it names the kind, key, outcome, map, version and a date")
	_check(e.sample_count() == 64 and e.ticks.size() == 64 * 9 and is_equal_approx(e.rate, 64.0), "64 samples of nine floats at 64 Hz", str(e.ticks.size()))
	_check(is_equal_approx(e.ticks[3], 1.0) and is_equal_approx(e.ticks[5 * 9], 5.0) and is_equal_approx(e.ticks[5 * 9 + 6], 1.0), "observation then action, per tick")
	_check(e.start.has("pos") and e.schema_id == _demo_schema().schema_id(), "the start state and schema id ride along")

	# A rate that skips ticks holds the action over the gap.
	rec.note_verified("ride", "slow", 40)
	_check(rec.begin(8, "ride", "slow").ok, "a well-known edge begins")
	kept = _demo_ride(rec, 8, 64, 4.0)
	_check(kept == 16, "at the base rate every 4th tick is kept", str(kept))
	var _end := rec.end(8, "landed")
	var _fl: DotResult = await rec.flush_all()
	var slow := store.episodes[1] as DotBotDemoEpisode
	_check(is_equal_approx(slow.rate, 16.0) and slow.sample_count() == 16, "the episode says its rate")
	_check(is_equal_approx(slow.ticks[6], 1.0) and is_equal_approx(slow.ticks[7], 0.5) and is_equal_approx(slow.ticks[8], 4.0),
		"an analogue action is the mean over the gap and a button the most frequent value", str([slow.ticks[7], slow.ticks[8]]))

	# Refusals.
	var bot := rec.begin(-1, "ride", "17>9")
	_check(not bot.ok and bot.code() == DotError.CODE_FORBIDDEN and rec.refused == 1 and not rec.is_recording(-1), "a bot is refused by include_fn")
	_check(rec.begin(9, "dance", "").code() == DotError.CODE_INVALID, "a kind with no schema is refused")
	_check(not rec.sample(99, PackedFloat32Array([0, 0, 0, 0, 0, 0]), PackedFloat32Array([0, 0, 0])), "a sample for nobody is ignored")
	var _b := rec.begin(10, "ride", "")
	_check(not rec.sample(10, PackedFloat32Array([0.0]), PackedFloat32Array([0, 0, 0])) and rec.bad_samples == 1, "a sample of the wrong size is counted, not stored")
	rec.cancel(10)
	_check(not rec.is_recording(10), "cancel drops the open episode")
	var client := _demo_recorder()
	client.is_server = false
	_check(client.begin(1, "ride", "").code() == DotError.CODE_UNSUPPORTED, "a client never records")
	var picky := _demo_recorder()
	picky.config.kinds = "engage"
	_check(picky.begin(1, "ride", "").code() == DotError.CODE_FORBIDDEN, "bot_record_kinds filters kinds")
	var sc2 := _demo_schema()
	sc2.kind = "short"
	sc2.keep_outcomes = PackedStringArray(["landed"])
	var _r := picky.register(sc2)
	picky.config.kinds = ""
	var _p := picky.begin(1, "short", "k")
	var _n := _demo_ride(picky, 1, 4)
	_check(not picky.end(1, "fell").ok and picky.queued() == 0, "an outcome the kind does not keep is dropped")

	# The cap: past it a key records no more.
	var small := _demo_recorder()
	small.config.cap = 3
	var ok_count := 0
	for i in 5:
		if small.begin(i, "ride", "edge").ok:
			var _k := _demo_ride(small, i, 3)
			if small.end(i, "landed").ok:
				ok_count += 1
	_check(ok_count == 3 and small.capped >= 1, "at most cap episodes are kept per edge", str(ok_count))

	# The queue: full, it drops the oldest.
	var big := _demo_recorder()
	for i in 6:
		var huge := DotBotDemoEpisode.new()
		huge.key = "k%d" % i
		huge.ticks.resize(260000)
		big._enqueue(huge)
	_check(big.dropped >= 1 and big.queued_bytes() <= DotBotDemoRecorder.QUEUE_MAX_BYTES, "a full queue drops the oldest episode", "%d dropped, %d bytes" % [big.dropped, big.queued_bytes()])
	var oldest := big._queue[0] as DotBotDemoEpisode
	_check(oldest.key != "k0", "and it was the oldest that went", oldest.key)
	_done()


class FakeHost:
	extends RefCounted

	static func _is_human(subject: Variant) -> bool:
		return int(subject) >= 0


func _test_demo_batching() -> void:
	_section("demonstration writes: a slow store never holds up a tick")
	var store := SlowStore.new()
	var rec := _demo_recorder(store)
	rec.config.flush = 0.5
	rec.write_budget_usec = 1000
	for i in 40:
		var _b := rec.begin(i, "ride", "k")
		var _k := _demo_ride(rec, i, 4)
		rec.config.cap = 1000
		var _e := rec.end(i, "landed")
	_check(rec.queued() == 40 and store.episodes.is_empty(), "ending an episode writes nothing")
	var worst := 0
	var calls := 0
	var t := 0.0
	while rec.queued() > 0 and calls < 400:
		var t0 := Time.get_ticks_usec()
		rec.process(1.0 / 64.0)
		worst = maxi(worst, Time.get_ticks_usec() - t0)
		calls += 1
		t += 1.0 / 64.0
	_check(store.episodes.size() == 40 and rec.written == 40, "every queued episode is written in the end", str(store.episodes.size()))
	_check(calls > 4, "over several ticks, not one", str(calls))
	_check(worst < 12000, "no tick spent more than a budget and one chunk writing", "%d us" % worst)
	_check(t >= 0.5, "and nothing was written before the flush interval", str(t))

	var down := _demo_recorder(DownStore.new())
	down.config.flush = 0.01
	var _b2 := down.begin(1, "ride", "k")
	var _k2 := _demo_ride(down, 1, 4)
	var _e2 := down.end(1, "landed")
	for i in 5:
		down.process(0.02)
	_check(down.write_errors >= 1 and down.queued() == 1 and down.written == 0, "a store that is down keeps the episode for the next try", str(down.write_errors))
	_done()


func _demo_episode(map_id: String, version: String, kind: String, key: String, score: float = 0.0, verified: bool = false) -> DotBotDemoEpisode:
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
func _store_contract(store: DotBotDemoStore, fresh: Callable, label: String) -> void:
	var a := _demo_episode("surf_toy", "v1", "ride", "1>2", 0.2, true)
	var b := _demo_episode("surf_toy", "v1", "ride", "1>2", 0.9, true)
	var c := _demo_episode("surf_toy", "v1", "ride", "2>3")
	var old := _demo_episode("surf_toy", "v0", "ride", "1>2", 0.5, true)
	var other := _demo_episode("other_map", "v0", "ride", "1>2")
	var put: DotResult = await store.append([a, b, c, old, other])
	_check(put.ok and put.value == 5, label + ": a batch is stored", str(put.error.message if not put.ok else put.value))
	_check(a.id != 0 and a.id != b.id, label + ": every episode gets its own id")

	var again: DotBotDemoStore = fresh.call()
	var opened: DotResult = await again.open()
	var got: DotResult = await again.load("surf_toy", "v1", "ride", "1>2", 10)
	var first: DotBotDemoEpisode = got.value[0] if got.ok and not (got.value as Array).is_empty() else null
	_check(opened.ok and first != null and got.value.size() == 2, label + ": a second store reads both back", str(got.error.message if not got.ok else ""))
	_check(first != null and first.id == b.id and first.score == 0.9 and first.ticks == b.ticks and first.start == b.start and first.frame_size == 3 and first.day == "2026-10-21", label + ": the round trip keeps every field, best score first")
	var one: DotResult = await again.load("surf_toy", "v1", "ride", "1>2", 1)
	_check(one.ok and one.value.size() == 1, label + ": limit cuts the list")

	var cnt: DotResult = await again.counts("surf_toy", "v1", "ride")
	_check(cnt.ok and cnt.value == {"1>2": 2, "2>3": 0}, label + ": counts are verified episodes per key", str(cnt.value))
	var stale: DotResult = await again.counts("surf_toy", "v2", "ride")
	var none: DotResult = await again.load("surf_toy", "v2", "ride", "1>2", 10)
	_check(stale.ok and stale.value.is_empty() and none.ok and none.value.is_empty(), label + ": a different map version is a different, empty set")

	var marked: DotResult = await again.mark([c.id], true, 0.7)
	var cnt2: DotResult = await fresh.call().counts("surf_toy", "v1", "ride")
	_check(marked.ok and marked.value == 1 and cnt2.value == {"1>2": 2, "2>3": 1}, label + ": a verdict is kept for the next store", str(cnt2.value))
	var unmarked: DotResult = await again.mark([c.id], false, 0.0)
	var cnt3: DotResult = await again.counts("surf_toy", "v1", "ride")
	_check(unmarked.ok and cnt3.value == {"1>2": 2, "2>3": 0}, label + ": a verdict can be withdrawn")

	var pruned: DotResult = await again.prune("surf_toy", "v1")
	var gone: DotResult = await fresh.call().counts("surf_toy", "v0", "ride")
	var kept: DotResult = await fresh.call().counts("surf_toy", "v1", "ride")
	var elsewhere: DotResult = await fresh.call().load("other_map", "v0", "ride", "1>2", 10)
	_check(pruned.ok and pruned.value == 1 and gone.value.is_empty(), label + ": prune drops the other versions of that map", str(pruned.value))
	_check(kept.value.size() == 2 and elsewhere.value.size() == 1, label + ": and keeps the kept version and other maps")


func _test_demo_store_json() -> void:
	_section("demonstration JSON store: round trip, versions, prune, corrupt file, the tick budget")
	var dir := "user://dot_bot_test_%d" % randi()
	var make := func() -> DotBotDemoStore: return DotBotDemoStoreJson.new(dir)
	var store: DotBotDemoStoreJson = make.call()
	var _o := await store.open()
	await _store_contract(store, make, "json")
	var file := store.file_for("surf_toy", "v1", "ride")
	_check(file.ends_with("/surf_toy@v1/ride.json") and FileAccess.file_exists(file) and not FileAccess.file_exists(file + ".tmp"), "json: one file per map version and kind, no temp file left", file)

	# A file that will not parse is set aside, not fatal.
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string("{\"format\": 1, \"episodes\": [ {oops")
	f.close()
	var broken := DotBotDemoStoreJson.new(dir)
	var cnt: DotResult = await broken.counts("surf_toy", "v1", "ride")
	_check(cnt.ok and cnt.value.is_empty() and broken.recovered == 1 and FileAccess.file_exists(file + ".corrupt"), "json: a corrupt file is moved aside and counted as empty")
	var fresh_put: DotResult = await broken.append([_demo_episode("surf_toy", "v1", "ride", "9>9", 0.3, true)])
	var back: DotResult = await DotBotDemoStoreJson.new(dir).load("surf_toy", "v1", "ride", "9>9", 5)
	_check(fresh_put.ok and back.ok and back.value.size() == 1, "json: recording carries on after the recovery")
	var newer := DotBotDemoStoreJson.new(dir + "/newer")
	DotPaths.write_text(newer.file_for("m", "v", "ride"), "{\"format\": 99, \"episodes\": []}")
	var refused: DotResult = await newer.counts("m", "v", "ride")
	_check(not refused.ok and refused.error.code == DotError.CODE_VERSION and not FileAccess.file_exists(newer.file_for("m", "v", "ride") + ".corrupt"), "json: a file from a newer build is refused, not overwritten")

	# The recorder writes through the store within its budget.
	var timed := DotBotDemoStoreJson.new(dir + "/timed")
	var rec := _demo_recorder(timed)
	rec.config.flush = 0.2
	rec.config.cap = 1000
	for i in 120:
		var _b := rec.begin(i, "ride", "k%d" % (i % 3))
		var _k := _demo_ride(rec, i, 64)
		var _e := rec.end(i, "landed")
	var worst := 0
	var calls := 0
	while rec.queued() > 0 and calls < 2000:
		var t0 := Time.get_ticks_usec()
		rec.process(1.0 / 64.0)
		worst = maxi(worst, Time.get_ticks_usec() - t0)
		calls += 1
		await get_tree().process_frame
	var cnt_t: DotResult = await DotBotDemoStoreJson.new(dir + "/timed").counts("surf_toy", "v1", "ride")
	_check(rec.written == 120 and cnt_t.ok and cnt_t.value.size() == 3, "json: the recorder's queue reaches the files", "%d written" % rec.written)
	_check(worst < 12000 and calls > 4, "json: no tick spends more than the write budget and one chunk", "%d us over %d ticks" % [worst, calls])

	var cfg := DotBotDemoConfig.new()
	cfg.path = dir + "/cfg"
	var made: DotResult = DotBotDemoStore.from_config(cfg)
	cfg.store = "off"
	var off: DotResult = DotBotDemoStore.from_config(cfg)
	_check(made.ok and made.value is DotBotDemoStoreJson and (made.value as DotBotDemoStoreJson).path == cfg.path and off.ok and off.value == null, "from_config: json by default, null for off")
	DotPaths.remove_tree(dir)
	_done()


func _test_demo_store_sql() -> void:
	_section("demonstration SQL store: the same contract on SQLite through dot-sql, by duck typing")
	var script_path := "res://addons/dot_sql/core/dot_sql.gd"
	if not ResourceLoader.exists(script_path) or not FileAccess.file_exists("res://addons/godot-sqlite/gdsqlite.gdextension"):
		print("  SKIP  dot-sql or godot-sqlite is not linked into this project (addons/dot_sql, addons/godot-sqlite)")
		_done()
		return
	_sql_ran = true
	var db := "user://dot_bot_test_%d.db" % randi()
	var make := func() -> DotBotDemoStore:
		var cfg := DotBotDemoConfig.new()
		cfg.store = "sqlite"
		cfg.path = db
		var res: DotResult = DotBotDemoStore.from_config(cfg, self)
		var s: DotBotDemoStore = res.value
		var _o: DotResult = await s.open()
		return s
	var store: DotBotDemoStore = await make.call()
	_check(store is DotBotDemoStoreSql, "from_config builds the SQL store from the config, dot-sql loaded by path")
	var opened: DotResult = await store.open()
	_check(opened.ok, "the migration creates the table", str(opened.error.message if not opened.ok else ""))
	var again: DotResult = await store.open()
	_check(again.ok, "opening again does not migrate twice")
	await _store_contract(store, make, "sql")
	await store.close()
	DirAccess.remove_absolute(db)
	_done()


func _test_demo_off_and_privacy() -> void:
	_section("demonstration recorder: the off switch, the cvars, and no names or ids")
	var rec := _demo_recorder()
	_check(rec.begin("peer-4711-Alice", "ride", "17>9", {"x": 1}).ok, "it is on by default")
	var _k := _demo_ride(rec, "peer-4711-Alice", 8)
	var _e := rec.end("peer-4711-Alice", "landed")
	var episode := rec._queue[0] as DotBotDemoEpisode
	var text := JSON.stringify(episode.to_dictionary())
	_check(not text.contains("4711") and not text.contains("Alice") and not text.contains("peer"), "no name or id reaches the output")
	var allowed := ["id", "map_id", "map_version", "schema_id", "kind", "key", "start", "rate", "frame_size", "ticks", "outcome", "day", "verified", "score"]
	var extra := 0
	for k: String in episode.to_dictionary():
		if not allowed.has(k):
			extra += 1
	_check(extra == 0 and episode.day.length() == 10, "only the declared fields, with a date and nothing finer", str(extra))
	var back := DotBotDemoEpisode.from_dictionary(JSON.parse_string(text))
	_check(back.ticks == episode.ticks and back.key == "17>9", "an episode survives JSON")

	var made := {}
	var add := func(n: String, value: String, _help: String, _flags: int) -> Object:
		var c := FakeCvar.new()
		c.name = n
		c.value = value
		made[n] = c
		return c
	var list := rec.config.bind_cvars(add)
	_check(made.has("bot_record") and made.has("bot_record_rate") and made.has("bot_record_cap") and made.has("bot_record_flush") and not made.has("bot_record_token"),
		"bot_record* cvars exist, and the token is not one", str(made.keys()))
	_check((made["bot_record"] as FakeCvar).value == "1" and (made["bot_record_rate"] as FakeCvar).value == "16.0", "defaults show in the cvars")
	var _s := (made["bot_record_rate"] as FakeCvar).set_value("8")
	_check(is_equal_approx(rec.config.rate, 8.0), "a cvar sets the config")
	_check(not (made["bot_record_rate"] as FakeCvar).set_value("-3").ok, "a bad number is refused by the validator")
	var _s2 := (made["bot_record_target"] as FakeCvar).set_value("0")
	_check(rec.config.target == 1 and rec.config.validate().ok, "a target of 0 is clamped, never left invalid")

	var _s3 := (made["bot_record"] as FakeCvar).set_value("0")
	_check(not rec.config.record and not rec.is_on(), "bot_record 0 switches it off")
	_check(rec.begin("someone", "ride", "17>9").code() == DotError.CODE_FORBIDDEN, "and no episode begins")
	var _open := rec.config.record
	rec.config.record = true
	var _b := rec.begin("late", "ride", "")
	rec.config.record = false
	rec.process(0.0)
	_check(not rec.is_recording("late"), "switching off drops what is open")
	rec.process(0.0)
	_check(rec.queued() == 0 and rec.written == 1, "and flushes what was queued", "%d queued, %d written" % [rec.queued(), rec.written])
	_check(list.size() >= 9, "one cvar per setting", str(list.size()))

	var cfg := DotBotDemoConfig.new()
	var applied := cfg.apply_dictionary({"rate": 24, "token": "s3cret", "store": "memory", "bogus": 1}, "file", true)
	_check(applied.has("rate") and cfg.rate == 24.0 and cfg.store == "memory", "a config file layers over the defaults")
	var shown := "\n".join(cfg.describe_lines())
	_check(not shown.contains("s3cret") and shown.contains("recording: ON"), "describe_lines redacts the token and says what is on")
	_check(cfg.sensitive_keys().has("token"), "the token is a sensitive key, refused from environment and argv")
	_check(rec.describe_lines().size() >= 5 and rec.describe().begins_with("demo recorder"), "the recorder describes itself")
	_done()


# --- Ride harvest -------------------------------------------------------------------
# The simulator and the host are toys: a point that accelerates along x. DotFpsSimulator lives in
# dot-player-controller, which this suite does not link, so the harvest is tested through the
# duck-typed interface it documents; game-arena's suite runs it on the real motor.


func _section(title: String) -> void:
	_entered += 1
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
