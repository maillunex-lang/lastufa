extends RefCounted


func _fresh() -> AfSurvival:
	var s := AfSurvival.new()
	s.reset()
	s.ambient_temp = 18.0
	return s


func test_needs_decay_and_starvation(t) -> void:
	var s := _fresh()
	var start := s.need("satiety")
	s.simulate(600.0)
	t.near(s.need("satiety"), start - 40.0, 1.0, "satiety -4/h")
	t.near(s.need("hydration"), 80.0 - 60.0, 1.0, "hydration -6/h")
	for i in 72:
		s.simulate(60.0)
	t.ok(s.dead, "dies without food and water")
	t.ok(s.death_cause != "", "death cause recorded")


func test_sleep_restores_energy(t) -> void:
	var s := _fresh()
	s.needs["energy"] = 20.0
	s.sleeping = true
	s.simulate(240.0)
	t.ok(s.need("energy") > 60.0, "energy restored while sleeping")


func test_bleeding_and_bandage(t) -> void:
	var s := _fresh()
	s.add_injury("bleeding", 0.8, "left_arm")
	s.simulate(30.0)
	var hp := s.health
	t.ok(hp < 95.0, "bleeding hurts (%f)" % hp)
	var msg := s.apply_use({"cures": ["bleeding"]})
	t.ok(msg.contains("Кровотечение"), "bandage message")
	s.simulate(30.0)
	t.ok(s.health >= hp - 0.5, "bleeding stopped")


func test_fracture_slows(t) -> void:
	var s := _fresh()
	s.add_injury("fracture", 0.7, "left_leg")
	t.ok(s.move_multiplier() < 0.6, "fracture slows")
	s.apply_use({"cures": ["fracture"]})
	t.ok(s.move_multiplier() >= 0.8 - 0.001, "splint helps")


func test_cold_causes_hypothermia(t) -> void:
	var s := _fresh()
	s.ambient_temp = -20.0
	s.wet = 1.0
	for i in 12:
		s.simulate(60.0)
	t.ok(s.body_temp < 35.5, "body cools (%f)" % s.body_temp)
	var w := _fresh()
	w.ambient_temp = -20.0
	w.insulation = 25.0
	w.exertion = 1.0
	for i in 12:
		w.simulate(60.0)
	t.ok(w.body_temp > s.body_temp + 0.5, "insulation keeps warmer")


func test_infection_progresses_and_can_be_delayed(t) -> void:
	var s := _fresh()
	t.ok(s.expose_to_infection(1.0), "guaranteed infection")
	t.eq(s.infection["stage"], "incubation", "incubation")
	t.eq(s.symptoms().size(), 0, "no symptoms during incubation")
	var inc := float(s.infection["incubation_hours"])
	s.simulate(inc * 60.0 + 5.0)
	t.eq(s.infection["stage"], "fever", "fever after incubation")
	s.apply_use({"infection_delay_hours": 48})
	s.simulate(47.0 * 60.0)
	t.eq(s.infection["stage"], "fever", "inhibitor halts progression")
	var guard := 0
	while not s.dead and guard < 200:
		s.needs["satiety"] = 100.0
		s.needs["hydration"] = 100.0
		s.simulate(60.0)
		guard += 1
	t.ok(s.dead, "untreated infection is fatal")


func test_offline_protection_floor(t) -> void:
	var s := _fresh()
	s.protected_floor = 25.0
	for i in 48:
		s.simulate(60.0)
	t.ok(not s.dead, "protected hero survives")
	t.ok(s.need("hydration") >= 25.0, "needs floored")


func test_inventory_weight_and_spoilage(t) -> void:
	var inv := AfInventory.new()
	inv.max_weight = 5.0
	var left := inv.add("water_bottle", 8)
	t.eq(left, 3, "weight limit (5 kg of 1 kg bottles)")
	t.eq(inv.count("water_bottle"), 5, "count")
	t.near(inv.total_weight(), 5.0, 0.001, "weight")
	inv.add("bread", 1, 1.0, 1.0, true)
	inv.simulate(96.0 * 60.0 * 0.8)
	var bread := {}
	for s in inv.stacks:
		if s["item"] == "core:bread":
			bread = s
	t.ok(float(bread["condition"]) < 0.25, "bread spoils in ~4 days")
	t.eq(inv.remove_item("water_bottle", 2), 2, "removed")
	t.eq(inv.count("water_bottle"), 3, "count after removal")


func test_loot_roll(t) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var total := 0
	for i in 50:
		for it in AfInventory.roll_loot("pharmacy", rng):
			t.ok(Registry.has_def("item", it["item"]), "valid item")
			total += int(it["qty"])
	t.ok(total > 50, "pharmacy yields items (%d)" % total)
	t.eq(AfInventory.roll_loot("no_such_table", rng).size(), 0, "unknown table -> nothing")
