extends RefCounted


func before_each(_t) -> void:
	Session.new_game()


func after_each(_t) -> void:
	Session.end_session()


func test_graph_and_intel(t) -> void:
	var wm := Session.world_map
	t.eq(wm.current_region, "core:ufa", "start in Ufa")
	t.eq(wm.intel("core:ufa"), 3, "Ufa visited")
	var ns := wm.neighbors("core:ufa")
	t.ok(ns.has("core:sterlitamak") and ns.has("core:chishmy"), "Ufa neighbours via roads")
	t.eq(wm.intel("core:sterlitamak"), 1, "neighbour rumoured")
	t.eq(wm.intel("core:sibay"), 0, "far region unknown")
	var km := wm.distance_km("core:ufa", "core:sterlitamak")
	t.ok(km > 110.0 and km < 135.0, "Ufa-Sterlitamak straight distance ~123 km (%f)" % km)


func test_travel_takes_time_and_reveals(t) -> void:
	var wm := Session.world_map
	var p := Session.player
	p.inventory.add("water_bottle", 4, 1.0, 1.0, true)
	p.inventory.add("canned_meat", 4, 1.0, 1.0, true)
	var t0 := Clock.total_minutes
	var report := wm.travel("core:chishmy")
	t.ok(Clock.total_minutes - t0 >= 60.0 * 8, "travel took hours (%f min)" % (Clock.total_minutes - t0))
	if not p.survival.dead:
		t.eq(wm.current_region, "core:chishmy", "arrived")
		t.eq(wm.intel("core:chishmy"), 3, "visited")
		t.ok(report.size() >= 1, "report")
	t.eq(wm.travel("core:sibay")[0], "Нет дороги в этот район.", "no road to non-neighbour")


func test_search_area_diminishes(t) -> void:
	var wm := Session.world_map
	Session.player.inventory.max_weight = 1000.0
	var first := 0
	var later := 0
	for i in 3:
		Session.player.survival.health = 100.0
		var r := wm.search_area()
		first += Array(r).filter(func(l): return l.begins_with("Найдено")).size() if i == 0 else 0
	for i in 3:
		Session.player.survival.health = 100.0
		later += Array(wm.search_area()).filter(func(l): return l.begins_with("Найдено")).size()
	t.eq(int(wm.regions["core:ufa"]["searched"]), 6, "search count")
	t.ok(later <= first * 3 + 1, "searches yield less over time (%d vs %d)" % [later, first])


func test_migration_flows_from_dense_to_sparse(t) -> void:
	var wm := Session.world_map
	for id in wm.regions:
		wm.regions[id]["density"] = 0.2
	wm.regions["core:ufa"]["density"] = 0.9
	var before := wm.density("core:chishmy")
	Clock.start(Clock.total_minutes - fmod(Clock.total_minutes, 1440.0) + 1440.0 * 280) # summer-ish
	wm.simulate(1440.0 * 5)
	t.ok(wm.density("core:chishmy") > before, "neighbour density increased")
	t.ok(wm.density("core:ufa") < 0.9, "source decreased")


func test_weather_changes_over_time(t) -> void:
	var w := Session.weather
	var seen := {}
	for i in 24 * 10:
		w.simulate(60.0)
		seen[w.current] = true
	t.ok(seen.size() >= 3, "several weather states over 10 days: %s" % str(seen.keys()))
	t.ok(w.temperature > -40.0 and w.temperature < 45.0, "plausible temperature")


func test_city_walk_and_districts(t) -> void:
	var wm := Session.world_map
	t.eq(wm.current_place, AfWorldMap.START_PLACE, "starts in the Chernikovka yard")
	t.ok(wm.in_city("ufa"), "in Ufa")
	t.eq(wm.district_of("core:ufa"), "core:go_ufa", "Ufa is its own city okrug")
	var target := ""
	for p in Registry.all("place"):
		if p["type"] == "hospital":
			target = str(p["id"])
			break
	var minutes := wm.walk_minutes(target)
	t.ok(minutes > 1.0 and minutes < 600.0, "walking time plausible (%f)" % minutes)
	var t0 := Clock.total_minutes
	Session.player.survival.health = 100.0
	wm.walk_to_place(target)
	if not Session.player.survival.dead:
		t.eq(wm.current_place, target, "arrived")
		t.ok(Clock.total_minutes - t0 >= minutes - 1.0, "time passed")
	t.ok(wm.neighbors("core:iglino").size() >= 3, "proximity links connect villages")
	t.ok(wm.district_regions("core:r_iglinskiy").size() >= 5, "district has settlements")


func test_leaving_city_clears_place(t) -> void:
	var wm := Session.world_map
	Session.player.inventory.add("water_bottle", 4, 1.0, 1.0, true)
	Session.player.inventory.add("canned_meat", 4, 1.0, 1.0, true)
	wm.travel("core:chishmy")
	if not Session.player.survival.dead:
		t.eq(wm.current_place, "", "no city place outside the city")
