extends RefCounted


func before_each(_t) -> void:
	Session.new_game()


func after_each(_t) -> void:
	Session.end_session()


func _found(t) -> AfBase:
	var b := Session.base
	b.found(AfWorldMap.START_PLACE, "core:ufa")
	t.ok(b.exists and b.hero_here(), "base founded where the hero stands")
	return b


func _person(over: Dictionary = {}) -> Dictionary:
	var p := Session.survivors.generate(over)
	p["infected_hidden"] = false
	return Session.survivors.add(p)


func test_generation(t) -> void:
	var s := Session.survivors
	for i in 20:
		var p := s.generate()
		t.ok(str(p["name"]).contains(" "), "first and last name")
		t.ok(Registry.has_def("profession", str(p["profession"])), "profession exists")
		t.eq(p["traits"].size(), 2, "two traits")
		t.ok(not (p["traits"].has("core:optimist") and p["traits"].has("core:pessimist")), "no contradictory traits")
		t.ok(str(p["bio"]) != "" and str(p["fear"]) != "" and str(p["secret"]) != "", "bio, fear, secret")
	t.eq(AfSurvivors.g("Выбрался(ась) и прожил(а)", true), "Выбралась и прожила", "female forms")
	t.eq(AfSurvivors.g("Выбрался(ась) и прожил(а)", false), "Выбрался и прожил", "male forms")


func test_found_base_brings_first_survivor(t) -> void:
	var b := _found(t)
	t.eq(Session.events.pending.size(), 1, "the neighbour knocks")
	var e: Dictionary = Session.events.pending[0]
	t.eq(e["data"]["candidate"]["name"], "Зульфия Галимова", "scripted first survivor")
	Session.events.resolve(e, 0)
	t.eq(Session.survivors.at_base().size(), 1, "joined")
	t.eq(b.location_name(), Registry.display_name("place", AfWorldMap.START_PLACE), "location name")


func test_construction_by_builders(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	t.ok(b.build_problem("shelter").begins_with("не хватает"), "needs materials")
	b.storage.add("wood_planks", 20, 1.0, 1.0, true)
	b.storage.add("scrap_metal", 10, 1.0, 1.0, true)
	t.eq(b.order_build("shelter"), "", "ordered")
	t.eq(b.storage.count("wood_planks"), 14, "materials spent")
	var p := _person({"skills": {"building": 8}})
	b.set_job(p, "build")
	Scheduler.fast_forward(10.0 * 60.0, 60.0)
	t.eq(b.level("shelter"), 1, "built by the builder")
	t.eq(b.beds(), 4, "beds available")


func test_survivors_eat_from_storage_and_starve_without(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	b.auto_assign = false
	var p := _person()
	b.storage.add("canned_meat", 6, 1.0, 1.0, true)
	b.storage.add("water_bottle", 6, 1.0, 1.0, true)
	Scheduler.fast_forward(24.0 * 60.0, 60.0)
	t.ok(b.storage.count("canned_meat") < 6, "food consumed")
	t.ok(float(p["satiety"]) > 40.0, "fed")
	b.storage.clear()
	b.food_bank = 0.0
	b.water_bank = 0.0
	var m0 := float(p["morale"])
	Scheduler.fast_forward(3.0 * 1440.0, 60.0)
	t.ok(float(p["health"]) < 100.0 or p["status"] != "base", "starving hurts")
	t.ok(float(p["morale"]) < m0 or p["status"] != "base", "starving lowers morale")


func test_hunger_disabled_by_config(t) -> void:
	Session.new_game({"hunger": false, "thirst": false})
	var b := _found(t)
	Session.events.pending.clear()
	var p := _person()
	Scheduler.fast_forward(3.0 * 1440.0, 60.0)
	t.eq(float(p["satiety"]), 100.0, "no hunger at the base either")
	t.eq(p["status"], "base", "nobody leaves or dies of hunger")


func test_garden_produces_in_summer_not_winter(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	b.modules["core:garden"] = {"level": 1, "condition": 1.0}
	b.auto_assign = false
	for i in 2:
		var p := _person({"skills": {"farming": 8}})
		p["job"] = "garden"
	b.storage.add("canned_meat", 30, 1.0, 1.0, true)
	b.storage.add("water_bottle", 30, 1.0, 1.0, true)
	Clock.start(1440.0 * 280 + 600.0)  # summer
	Scheduler.clear()
	Session._register_tasks()
	Scheduler.fast_forward(24.0 * 60.0, 60.0)
	var summer := b.storage.count("vegetables")
	t.ok(summer >= 2, "vegetables grow in summer (%d)" % summer)
	b.storage.remove_item("vegetables", summer)
	Clock.start(1440.0 * 120 + 600.0)  # winter
	Scheduler.fast_forward(24.0 * 60.0, 60.0)
	t.eq(b.storage.count("vegetables"), 0, "no harvest in winter without a greenhouse")


func test_workshop_crafts_to_target(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	b.modules["core:workshop"] = {"level": 1, "condition": 1.0}
	b.auto_assign = false
	var p := _person({"skills": {"engineering": 6}})
	p["job"] = "workshop"
	b.storage.add("cloth", 20, 1.0, 1.0, true)
	b.storage.add("canned_meat", 10, 1.0, 1.0, true)
	b.storage.add("water_bottle", 10, 1.0, 1.0, true)
	b.recipe_targets["core:bandage"] = 4
	Scheduler.fast_forward(12.0 * 60.0, 60.0)
	t.ok(b.storage.count("bandage") >= 4, "bandages up to the target (%d)" % b.storage.count("bandage"))
	t.ok(b.storage.count("bandage") <= 6, "stops near target")


func test_decisions_react_by_traits(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	var prag := _person({"traits": ["core:pragmatic", "core:lazy"]})
	var kind := _person({"traits": ["core:compassionate", "core:optimist"]})
	var l1 := float(prag["loyalty"])
	var l2 := float(kind["loyalty"])
	prag["infected_hours"] = 0.0
	Session.events.queue_bitten(prag)
	var e: Dictionary = Session.events.pending[0]
	var res := Session.events.resolve(e, 2)  # exile
	t.ok(res != "", "result text")
	t.eq(prag["status"], "left", "exiled")
	t.ok(float(kind["loyalty"]) < l2, "the compassionate one disapproves")
	t.ok(kind["memory"].any(func(m): return str(m["text"]).begins_with("Не одобряет")), "and remembers it")


func test_scavenging_trip(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	b.auto_assign = false
	var p := _person({"skills": {"scavenging": 9, "combat": 9}})
	b.storage.add("canned_meat", 10, 1.0, 1.0, true)
	b.storage.add("water_bottle", 10, 1.0, 1.0, true)
	b.set_job(p, "scavenge")
	t.eq(p["status"], "away", "left on a trip")
	Scheduler.fast_forward(14.0 * 60.0, 60.0)
	t.ok(p["status"] in ["base", "dead"], "came back (or not)")


func test_raids_and_offline_protection(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	for i in 4:
		_person()
	b.storage.add("canned_meat", 40, 1.0, 1.0, true)
	b.storage.add("water_bottle", 60, 1.0, 1.0, true)
	Session.world_map.regions["core:ufa"]["density"] = 1.0
	Session.offline_mode = true
	Scheduler.fast_forward(10.0 * 1440.0, 60.0, [Scheduler.Tier.REGIONAL])
	Session.offline_mode = false
	t.ok(int(b.stats["raids"]) > 0, "raids happen in a dense city (%d)" % int(b.stats["raids"]))
	t.eq(Session.survivors.living().size(), 4, "offline: nobody dies or leaves")


func test_save_load_base(t) -> void:
	var b := _found(t)
	var e: Dictionary = Session.events.pending[0]
	Session.events.resolve(e, 0)
	b.modules["core:defenses"] = {"level": 2, "condition": 0.7}
	b.storage.add("scrap_metal", 7, 1.0, 1.0, true)
	b.recipe_targets["core:bandage"] = 9
	var z: Dictionary = Session.survivors.at_base()[0]
	Session.survivors.remember(z, "тестовая память", 3.0)
	Session.events.recruit_event(Session.survivors.generate(), "У ворот кто-то есть.")
	t.ok(Saves.save("slot_5"), "saved")
	Session.new_game()
	t.ok(Saves.load_slot("slot_5", false)["ok"], "loaded")
	b = Session.base
	t.ok(b.exists, "base restored")
	t.eq(b.level("defenses"), 2, "modules")
	t.near(b.condition("defenses"), 0.7, 0.001, "condition")
	t.eq(b.storage.count("scrap_metal"), 7, "storage")
	t.eq(int(b.recipe_targets["core:bandage"]), 9, "recipe targets")
	t.eq(Session.survivors.at_base().size(), 1, "survivors")
	t.ok(Session.survivors.at_base()[0]["memory"].any(func(m): return m["text"] == "тестовая память"), "memory")
	t.eq(Session.events.pending.size(), 1, "pending decision kept")
	t.ok(Session.events.zulfiya_done, "story flag kept")


func test_auto_assign(t) -> void:
	var b := _found(t)
	Session.events.pending.clear()
	b.storage.add("wood_planks", 20, 1.0, 1.0, true)
	b.storage.add("scrap_metal", 10, 1.0, 1.0, true)
	b.storage.add("canned_meat", 30, 1.0, 1.0, true)
	b.storage.add("water_bottle", 30, 1.0, 1.0, true)
	b.order_build("shelter")
	var builder := _person({"skills": {"building": 9, "combat": 0}})
	var fighter := _person({"skills": {"building": 0, "combat": 9}})
	Scheduler.fast_forward(60.0, 60.0)
	t.eq(builder["job"], "build", "the builder goes to the construction site")
	t.eq(fighter["job"], "guard", "the fighter guards")
