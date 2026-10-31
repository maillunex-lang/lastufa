extends RefCounted


func after_each(_t) -> void:
	Scheduler.clear()
	Clock.stop()


func test_calendar(t) -> void:
	Clock.start(6 * 60.0)
	t.eq(Clock.day(), 1, "day 1")
	t.eq(Clock.hour(), 6, "hour 6")
	t.eq(Clock.date_text(), "14 сентября", "start date")
	t.eq(Clock.season(), "autumn", "autumn")
	Clock.advance(1440.0 * 100)
	t.eq(Clock.day(), 101, "day 101")
	t.eq(Clock.season(), "winter", "winter after 100 days")


func test_pause_stack(t) -> void:
	Clock.start(0.0)
	Clock.push_pause("dialog")
	Clock.push_pause("menu")
	t.ok(Clock.is_paused(), "paused")
	Clock.release_pause("dialog")
	t.ok(Clock.is_paused(), "still paused by menu")
	Clock.release_pause("menu")
	t.ok(not Clock.is_paused(), "resumed")


func test_day_hour_signals(t) -> void:
	Clock.start(23 * 60.0)
	var days := []
	var hours := []
	var on_day := func(d): days.append(d)
	var on_hour := func(h, _d): hours.append(h)
	Clock.day_changed.connect(on_day)
	Clock.hour_changed.connect(on_hour)
	Clock.advance(90.0)
	Clock.day_changed.disconnect(on_day)
	Clock.hour_changed.disconnect(on_hour)
	t.eq(days, [2], "day changed once")
	t.eq(hours, [0], "hour changed to 0")


func test_fast_forward_runs_tasks_proportionally(t) -> void:
	Clock.start(0.0)
	var acc := {"local": 0.0, "strategic": 0.0, "n": 0}
	Scheduler.register("a", Scheduler.Tier.LOCAL, 10.0, func(dt): acc["local"] += dt; acc["n"] += 1)
	Scheduler.register("b", Scheduler.Tier.STRATEGIC, 360.0, func(dt): acc["strategic"] += dt, 1440.0)
	Scheduler.fast_forward(1440.0, 30.0)
	# all simulated time is delivered (minus at most one interval still accumulating)
	t.ok(acc["local"] > 1440.0 - 10.0 - 0.01 and acc["local"] <= 1440.0 + 10.0, "local got ~1440 min (%f)" % acc["local"])
	t.ok(acc["strategic"] >= 1440.0 - 360.0 * Settings.p("sim_interval_mult") - 1.0, "strategic got time (%f)" % acc["strategic"])
	t.ok(acc["n"] >= 40, "local ran many times")


func test_tier_filter_and_reset(t) -> void:
	Clock.start(0.0)
	var acc := {"local": 0.0, "regional": 0.0}
	Scheduler.register("l", Scheduler.Tier.LOCAL, 5.0, func(dt): acc["local"] += dt)
	Scheduler.register("r", Scheduler.Tier.REGIONAL, 30.0, func(dt): acc["regional"] += dt)
	Scheduler.fast_forward(600.0, 60.0, [Scheduler.Tier.REGIONAL])
	t.eq(acc["local"], 0.0, "local filtered out")
	t.ok(acc["regional"] > 400.0, "regional ran")
	Scheduler.reset_accumulators([Scheduler.Tier.LOCAL])
	Scheduler.fast_forward(5.0, 5.0)
	t.ok(acc["local"] <= 10.0, "local backlog dropped (%f)" % acc["local"])


func test_frame_budget_time_slices(t) -> void:
	Clock.start(0.0)
	var runs := {"n": 0}
	for i in 50:
		Scheduler.register("slow%d" % i, Scheduler.Tier.LOCAL, 1.0, func(_dt):
			runs["n"] += 1
			var until := Time.get_ticks_usec() + 1500
			while Time.get_ticks_usec() < until:
				pass)
	Clock.advance(5.0)
	Scheduler._process(0.016)
	var budget_ms := float(Settings.p("sim_budget_ms"))
	t.ok(runs["n"] < 50, "budget stopped the frame early (%d runs, budget %.1f ms)" % [runs["n"], budget_ms])
	t.ok(runs["n"] >= 1, "at least one task ran")
