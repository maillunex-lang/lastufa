extends Node
## Tiered, time-sliced simulation scheduler.
##
## Every subsystem registers a task with a tier and an interval in GAME minutes.
## Game time accumulates per task; due tasks run round-robin within a per-frame
## CPU budget from the performance profile, so updates never pile up into one
## synchronous spike. Initial phases are staggered. Intervals of the regional
## and strategic tiers are multiplied on weaker devices.
##
## Tiers:
##   LOCAL     - full simulation near the player (needs, injuries, location state)
##   REGIONAL  - simplified simulation of the surrounding region
##   STRATEGIC - coarse simulation of remote territories / factions

enum Tier { LOCAL, REGIONAL, STRATEGIC }

class Task:
	var name: String
	var tier: int
	var interval: float
	var max_step: float
	var fn: Callable
	var acc := 0.0
	var runs := 0
	var total_usec := 0
	var enabled := true

var _tasks: Array[Task] = []
var _cursor := 0
var _fast_forwarding := false
var frame_budget_overruns := 0


func _ready() -> void:
	Clock.advanced.connect(_on_clock_advanced)


func register(task_name: String, tier: int, interval_minutes: float, fn: Callable, max_step: float = -1.0) -> void:
	unregister(task_name)
	var t := Task.new()
	t.name = task_name
	t.tier = tier
	t.interval = interval_minutes
	t.max_step = max_step if max_step > 0.0 else interval_minutes * 6.0
	t.fn = fn
	# stagger: spread first runs over the interval to avoid synchronous spikes
	t.acc = randf() * interval_minutes * 0.9
	_tasks.append(t)


func unregister(task_name: String) -> void:
	for idx in range(_tasks.size() - 1, -1, -1):
		if _tasks[idx].name == task_name:
			_tasks.remove_at(idx)


func clear() -> void:
	_tasks.clear()
	_cursor = 0


func has_task(task_name: String) -> bool:
	for t in _tasks:
		if t.name == task_name:
			return true
	return false


func _effective_interval(t: Task) -> float:
	if t.tier == Tier.LOCAL:
		return t.interval
	return t.interval * float(Settings.p("sim_interval_mult"))


func _on_clock_advanced(dt: float) -> void:
	for t in _tasks:
		if t.enabled:
			t.acc += dt


func _process(_delta: float) -> void:
	if _fast_forwarding or _tasks.is_empty():
		return
	var budget_usec := int(float(Settings.p("sim_budget_ms")) * 1000.0)
	_run_due(budget_usec, [])


## Runs due tasks. budget_usec <= 0 means unlimited. Returns number of runs.
func _run_due(budget_usec: int, tier_filter: Array) -> int:
	var start := Time.get_ticks_usec()
	var n := _tasks.size()
	var runs := 0
	var checked := 0
	var guard := 0
	while checked < n and guard < 10000:
		guard += 1
		if _cursor >= _tasks.size():
			_cursor = 0
		var t := _tasks[_cursor]
		var interval := _effective_interval(t)
		if t.enabled and t.acc >= interval and (tier_filter.is_empty() or tier_filter.has(t.tier)):
			var step := minf(t.acc, t.max_step)
			t.acc -= step
			var t0 := Time.get_ticks_usec()
			t.fn.call(step)
			t.total_usec += Time.get_ticks_usec() - t0
			t.runs += 1
			runs += 1
			if budget_usec > 0 and Time.get_ticks_usec() - start > budget_usec:
				frame_budget_overruns += 1 if t.acc >= interval else 0
				_cursor += 1
				return runs
			# a task with a large backlog stays on the cursor until drained
			if t.acc >= interval:
				continue
		_cursor += 1
		checked += 1
	return runs


## Advances game time by `minutes` in chunks, running every due task
## synchronously. Used for sleeping, travel and offline progress.
func fast_forward(minutes: float, chunk: float = 30.0, tier_filter: Array = []) -> void:
	_fast_forwarding = true
	var left := minutes
	while left > 0.0001:
		var step := minf(chunk, left)
		Clock.advance(step)
		_run_due(0, tier_filter)
		left -= step
	_fast_forwarding = false


## Drops accumulated time of the given tiers (used after offline progress so
## local tasks don't re-simulate the skipped span).
func reset_accumulators(tiers: Array) -> void:
	for t in _tasks:
		if tiers.has(t.tier):
			t.acc = 0.0


func stats() -> Array:
	var out := []
	for t in _tasks:
		out.append({"name": t.name, "tier": t.tier, "interval": t.interval, "runs": t.runs,
			"avg_ms": (t.total_usec / 1000.0 / t.runs) if t.runs > 0 else 0.0})
	return out
