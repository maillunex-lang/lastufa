class_name AfBase
extends RefCounted
## The settlement: one main base at a map place (city) or a settlement.
## Modules are built from materials in the shared storage by builders, wear
## out, need power and staff, and produce. Survivors eat and drink from the
## storage, work autonomously, defend against raids and go scavenging.
## Simulated hourly on the REGIONAL tier (also while the game is closed,
## with offline protection: nobody dies or leaves, damage is capped).

signal changed

const STORAGE_BASE_KG := 60.0
const SCAVENGE_HOURS := 8.0

var exists := false
var name := "Убежище"
var place_id := ""      # city place (Ufa) or ""
var region_id := ""     # settlement where the base is
var founded_day := 0
var modules := {}       # module id -> {level, condition}
var queue: Array = []   # [{module, level, done, need}]
var storage := AfInventory.new()
var recipe_targets := {}  # recipe id -> target stock
var recipe_progress := {} # module id -> {recipe, hours}
var food_bank := 0.0      # satiety points ready to eat
var water_bank := 0.0     # hydration points
var fuel_hours := 0.0     # generator running time already paid for
var auto_assign := true
var stats := {"raids": 0, "repelled": 0, "deaths": 0}
var last_report: Array = []
var _hour_acc := 0.0
var _day_acc := 0.0
var _rng := RandomNumberGenerator.new()

var people: AfSurvivors:
	get:
		return Session.survivors


func clear() -> void:
	exists = false
	name = "Убежище"
	place_id = ""
	region_id = ""
	modules = {}
	queue = []
	storage = AfInventory.new()
	storage.max_weight = STORAGE_BASE_KG
	recipe_targets = {}
	recipe_progress = {}
	food_bank = 0.0
	water_bank = 0.0
	fuel_hours = 0.0
	auto_assign = true
	stats = {"raids": 0, "repelled": 0, "deaths": 0}
	_rng.randomize()
	for r in Registry.all("recipe"):
		recipe_targets[str(r["id"])] = int(r.get("target", 0))


# --- founding / location -------------------------------------------------------

func found(p_place: String, p_region: String) -> void:
	exists = true
	place_id = p_place
	region_id = p_region
	founded_day = Clock.day()
	var where := Registry.display_name("place", p_place) if p_place != "" else Registry.display_name("region", p_region)
	name = "Убежище: " + where
	Session.journal.add("base", "Основано убежище — %s. Теперь у нас есть дом." % where)
	Session.events.on_base_founded()
	changed.emit()


func hero_here() -> bool:
	if not exists:
		return false
	var wm := Session.world_map
	if place_id != "":
		return wm.current_place == place_id
	return wm.current_region == region_id and wm.current_place == ""


func location_name() -> String:
	return Registry.display_name("place", place_id) if place_id != "" else Registry.display_name("region", region_id)


# --- modules -------------------------------------------------------------------

func level(id: String) -> int:
	return int(modules.get(Registry.resolve("base_module", id), {}).get("level", 0))


func level_def(id: String, lvl: int = -1) -> Dictionary:
	var d := Registry.get_def("base_module", id)
	var l := level(id) if lvl < 0 else lvl
	if d.is_empty() or l < 1 or l > d["levels"].size():
		return {}
	return d["levels"][l - 1]


func effect(id: String, key: String, default_value: float = 0.0) -> float:
	var ld := level_def(id)
	return float(ld.get(key, default_value)) if not ld.is_empty() else default_value


func condition(id: String) -> float:
	return float(modules.get(Registry.resolve("base_module", id), {}).get("condition", 1.0))


func max_level(id: String) -> int:
	return Registry.get_def("base_module", id).get("levels", []).size()


func in_queue(id: String) -> bool:
	var full := Registry.resolve("base_module", id)
	return queue.any(func(q): return q["module"] == full)


## Why a module can't be built/upgraded now ("" = can).
func build_problem(id: String) -> String:
	if not exists:
		return "нет убежища"
	if in_queue(id):
		return "уже строится"
	if level(id) >= max_level(id):
		return "максимальный уровень"
	if Session.config.god_mode:
		return ""
	var ld := level_def(id, level(id) + 1)
	for item in ld.get("cost", {}):
		if storage.count(item) < int(ld["cost"][item]):
			return "не хватает: %s (%d/%d)" % [Registry.display_name("item", item), storage.count(item), int(ld["cost"][item])]
	return ""


func order_build(id: String) -> String:
	var why := build_problem(id)
	if why != "":
		return why
	var full := Registry.resolve("base_module", id)
	var lvl := level(full) + 1
	var ld := level_def(full, lvl)
	if Session.config.god_mode:
		# god game: no materials, no builders, done at once
		_finish_build({"module": full, "level": lvl, "done": 0.0, "need": 0.0}, false)
		changed.emit()
		return ""
	for item in ld.get("cost", {}):
		storage.remove_item(item, int(ld["cost"][item]))
	queue.append({"module": full, "level": lvl, "done": 0.0, "need": float(ld.get("build_hours", 6))})
	changed.emit()
	return ""


func repair_cost(id: String) -> Dictionary:
	var ld := level_def(id)
	var out := {}
	for item in ld.get("cost", {}):
		out[item] = maxi(1, int(ceil(int(ld["cost"][item]) * 0.25 * (1.0 - condition(id)) * 2.0)))
	return out


func repair(id: String) -> String:
	var cost := {} if Session.config.god_mode else repair_cost(id)
	for item in cost:
		if storage.count(item) < int(cost[item]):
			return "не хватает: " + Registry.display_name("item", item)
	for item in cost:
		storage.remove_item(item, int(cost[item]))
	modules[Registry.resolve("base_module", id)]["condition"] = 1.0
	changed.emit()
	return ""


func demolish(id: String) -> void:
	var full := Registry.resolve("base_module", id)
	var ld := level_def(full)
	for item in ld.get("cost", {}):
		storage.add(item, int(int(ld["cost"][item]) / 2), 1.0, 1.0, true)
	var lvl := level(full) - 1
	if lvl <= 0:
		modules.erase(full)
	else:
		modules[full]["level"] = lvl
	for p in people.living():
		if p["job"] == full.get_slice(":", 1) and lvl <= 0:
			p["job"] = "idle"
	changed.emit()


# --- derived numbers ------------------------------------------------------------------

func beds() -> int:
	return int(effect("shelter", "beds", 0))


func storage_capacity() -> float:
	return STORAGE_BASE_KG + effect("storage", "capacity", 0.0)


func power_output() -> float:
	return effect("generator", "power_output", 0.0) if fuel_hours > 0.0 or storage.count("fuel_can") > 0 else 0.0


func power_demand() -> float:
	var d := 0.0
	for id in modules:
		d += float(level_def(id).get("power", 0))
	return d


func power_ratio() -> float:
	var dem := power_demand()
	return 1.0 if dem <= 0.0 else clampf(power_output() / dem, 0.0, 1.0)


func defense() -> float:
	var d := effect("defenses", "defense", 0.0) * (0.4 + 0.6 * condition("defenses"))
	for p in people.at_base():
		if p["job"] == "guard" and people.can_work(p):
			d += 6.0 + people.skill(p, "combat") * 2.0
	if hero_here():
		d += 15.0
	if storage.count("ammo_9x18") + storage.count("ammo_12g") >= 10:
		d += 8.0
	return d


func staff_of(id: String) -> Array:
	var job := id.get_slice(":", 1) if id.contains(":") else id
	return people.at_base().filter(func(p): return p["job"] == job and people.can_work(p))


func staff_slots(id: String) -> int:
	return int(level_def(id).get("staff", 0))


func food_days() -> float:
	if Session.config.disabled_needs().has("satiety"):
		return 99.0
	var need := 0.0
	for p in people.at_base():
		need += 100.0 * people.trait_value(p, "appetite", 1.0)
	if need <= 0.0:
		return 99.0
	var have := food_bank
	for s in storage.stacks:
		var d := storage.def_of(s)
		if d.get("category") == "food":
			have += float(d.get("use", {}).get("hunger", 0)) * int(s["qty"])
	return have / need


func water_days() -> float:
	if Session.config.disabled_needs().has("hydration"):
		return 99.0
	var need := float(people.at_base().size()) * 150.0
	if need <= 0.0:
		return 99.0
	var have := water_bank
	for s in storage.stacks:
		var d := storage.def_of(s)
		if d.get("category") == "drink" and not str(d["id"]).ends_with("dirty_water"):
			have += float(d.get("use", {}).get("thirst", 0)) * int(s["qty"])
	return have / need


# --- simulation -----------------------------------------------------------------------

func simulate(dt: float) -> void:
	if not exists:
		return
	storage.max_weight = storage_capacity()
	_hour_acc += dt
	while _hour_acc >= 60.0:
		_hour_acc -= 60.0
		_hour()
	_day_acc += dt
	while _day_acc >= 1440.0:
		_day_acc -= 1440.0
		_day()
	changed.emit()


func _hour() -> void:
	var offline := Session.offline_mode
	var pr := power_ratio()
	# generator fuel
	if level("generator") > 0 and power_demand() > 0.0:
		if fuel_hours <= 0.0 and storage.remove_item("fuel_can", 1) > 0:
			fuel_hours = 24.0 / maxf(0.1, effect("generator", "fuel_per_day", 1.0))
		fuel_hours = maxf(0.0, fuel_hours - 1.0)
	if auto_assign:
		_auto_assign()
	_returns()
	# construction
	if not queue.is_empty():
		var q: Dictionary = queue[0]
		var work := 0.0
		for p in people.at_base():
			if p["job"] == "build" and people.can_work(p):
				work += (0.5 + people.skill(p, "building") / 10.0) * people.trait_value(p, "work", 1.0)
		q["done"] = float(q["done"]) + work
		if float(q["done"]) >= float(q["need"]):
			_finish_build(q)
	# production
	_produce("garden", pr)
	_produce("water", pr)
	_craft("workshop", pr)
	_craft("kitchen", pr)
	# medicine + survivors' needs
	var heal := effect("infirmary", "heal", 0.0) * (0.5 + 0.5 * pr) * minf(1.0, staff_of("infirmary").size())
	var need_rate := Session.config.p("need_rate")
	var disabled := Session.config.disabled_needs()
	var food_mult := 1.0 + effect("kitchen", "food_bonus", 0.0) * minf(1.0, staff_of("kitchen").size())
	for p in people.at_base():
		var appetite := people.trait_value(p, "appetite", 1.0)
		if not disabled.has("satiety"):
			p["satiety"] = maxf(0.0, float(p["satiety"]) - 4.0 * need_rate * appetite)
			if float(p["satiety"]) < 70.0:
				var want := 100.0 - float(p["satiety"])
				_fill_bank("food", want, food_mult)
				var got := minf(want, food_bank)
				food_bank -= got
				p["satiety"] = float(p["satiety"]) + got
		else:
			p["satiety"] = 100.0
		if not disabled.has("hydration"):
			p["hydration"] = maxf(0.0, float(p["hydration"]) - 6.0 * need_rate)
			if float(p["hydration"]) < 70.0:
				var want2 := 100.0 - float(p["hydration"])
				_fill_bank("water", want2, 1.0)
				var got2 := minf(want2, water_bank)
				water_bank -= got2
				p["hydration"] = float(p["hydration"]) + got2
		else:
			p["hydration"] = 100.0
		if float(p["satiety"]) <= 0.0 or float(p["hydration"]) <= 0.0:
			p["health"] = float(p["health"]) - (1.0 if offline else 3.0)
		if float(p["injury_hours"]) > 0.0:
			p["injury_hours"] = maxf(0.0, float(p["injury_hours"]) - 1.0 - heal * 2.0)
			p["health"] = minf(100.0, float(p["health"]) + 0.5 + heal)
		elif float(p["satiety"]) > 30.0 and float(p["hydration"]) > 30.0:
			p["health"] = minf(100.0, float(p["health"]) + 0.4)
		if float(p["infected_hours"]) >= 0.0:
			p["infected_hours"] = float(p["infected_hours"]) + 1.0
			p["health"] = float(p["health"]) - 0.8
			if float(p["infected_hours"]) >= 48.0 and not offline:
				_kill(p, "пепельной лихорадки — обращение")
				continue
		if offline:
			p["health"] = maxf(20.0, float(p["health"]))
		if float(p["health"]) <= 0.0:
			_kill(p, "истощения" if float(p["satiety"]) <= 0.0 or float(p["hydration"]) <= 0.0 else "ран")


func _fill_bank(kind: String, want: float, mult: float) -> void:
	var guard := 0
	while (food_bank if kind == "food" else water_bank) < want and guard < 20:
		guard += 1
		var best := {}
		var best_spoil := INF
		for s in storage.stacks:
			var d := storage.def_of(s)
			if kind == "food" and d.get("category") != "food":
				continue
			if kind == "water" and (d.get("category") != "drink" or str(d["id"]).ends_with("dirty_water")):
				continue
			var spoil := float(s["condition"]) if d.has("spoil_hours") else 2.0
			if spoil < best_spoil:
				best_spoil = spoil
				best = s
		if best.is_empty():
			return
		var use: Dictionary = storage.def_of(best).get("use", {})
		storage.remove_uid(int(best["uid"]), 1)
		if kind == "food":
			food_bank += float(use.get("hunger", 10)) * mult
			water_bank += maxf(0.0, float(use.get("thirst", 0)))
		else:
			water_bank += float(use.get("thirst", 20))


func _produce(id: String, pr: float) -> void:
	if level(id) == 0:
		return
	var staff := staff_of(id)
	if staff.is_empty():
		return
	var ld := level_def(id)
	var factor := condition(id) * (1.0 if float(ld.get("power", 0)) <= 0.0 else (0.25 + 0.75 * pr))
	var amount := 0.0
	for p in staff.slice(0, staff_slots(id)):
		var sk := people.skill(p, str(Registry.get_def("base_module", id).get("skill", "farming")))
		amount += float(ld.get("yield", 0.1)) * (0.5 + sk / 10.0) * people.trait_value(p, "work", 1.0)
	amount *= factor
	if id == "garden":
		var season := Clock.season()
		var s_mult: float = {"spring": 0.6, "summer": 1.0, "autumn": 0.7, "winter": 0.0}[season]
		if bool(ld.get("greenhouse", false)):
			s_mult = maxf(s_mult, 0.8 * pr)
		amount *= s_mult
		_add_fraction("vegetables", amount)
	elif id == "water":
		if Session.weather.current in ["rain", "storm"]:
			amount *= 1.8
		if storage.count("dirty_water") > 0 and _rng.randf() < 0.5:
			storage.remove_item("dirty_water", 1)
			amount += 1.0
		_add_fraction("water_bottle", amount)


var _fractions := {}


func _add_fraction(item: String, amount: float) -> void:
	var v := float(_fractions.get(item, 0.0)) + amount
	var whole := int(floor(v))
	if whole > 0:
		storage.add(item, whole, 0.9, 1.0, true)
	_fractions[item] = v - whole


func _craft(id: String, pr: float) -> void:
	if level(id) == 0:
		return
	if Session.config.god_mode:
		# god game: recipes fill up to their target stock without inputs or workers
		for r in Registry.all("recipe"):
			if Registry.resolve("base_module", str(r["module"])) == Registry.resolve("base_module", id) and level(id) >= int(r.get("min_level", 1)):
				var missing := int(recipe_targets.get(str(r["id"]), 0)) - storage.count(str(r["output"]))
				if missing > 0:
					storage.add(str(r["output"]), missing, 1.0, 1.0, true)
		return
	var staff := staff_of(id)
	if staff.is_empty():
		return
	var ld := level_def(id)
	var factor := condition(id) * (1.0 if float(ld.get("power", 0)) <= 0.0 else (0.4 + 0.6 * pr))
	var work := 0.0
	for p in staff.slice(0, staff_slots(id)):
		work += (0.5 + people.skill(p, str(Registry.get_def("base_module", id).get("skill", "engineering"))) / 10.0) * people.trait_value(p, "work", 1.0)
	work *= factor
	var full := Registry.resolve("base_module", id)
	var prog: Dictionary = recipe_progress.get(full, {})
	if prog.is_empty() or not Registry.has_def("recipe", str(prog.get("recipe", ""))):
		prog = _next_recipe(full)
		if prog.is_empty():
			_maintain(full, work)
			return
		recipe_progress[full] = prog
	prog["hours"] = float(prog["hours"]) + work
	var r := Registry.get_def("recipe", str(prog["recipe"]))
	if float(prog["hours"]) >= float(r.get("hours", 1)):
		storage.add(str(r["output"]), int(r.get("qty", 1)), 0.85, 1.0, true)
		recipe_progress.erase(full)


func _next_recipe(module_full: String) -> Dictionary:
	for r in Registry.all("recipe"):
		if Registry.resolve("base_module", str(r["module"])) != module_full:
			continue
		if level(module_full) < int(r.get("min_level", 1)):
			continue
		if storage.count(str(r["output"])) >= int(recipe_targets.get(str(r["id"]), 0)):
			continue
		var ok := true
		for item in r["inputs"]:
			if storage.count(item) < int(r["inputs"][item]):
				ok = false
		if not ok:
			continue
		for item in r["inputs"]:
			storage.remove_item(item, int(r["inputs"][item]))
		return {"recipe": str(r["id"]), "hours": 0.0}
	return {}


## Idle workshop crews maintain the other buildings.
func _maintain(module_full: String, work: float) -> void:
	if module_full.ends_with("workshop"):
		for id in modules:
			if float(modules[id]["condition"]) < 1.0:
				modules[id]["condition"] = minf(1.0, float(modules[id]["condition"]) + 0.01 * work)
				return


func _finish_build(q: Dictionary, from_queue: bool = true) -> void:
	if from_queue:
		queue.pop_front()
	var id := str(q["module"])
	modules[id] = {"level": int(q["level"]), "condition": 1.0}
	var txt := "Достроено: %s (уровень %d)." % [Registry.display_name("base_module", id), int(q["level"])]
	Session.journal.add("base", txt)
	EventBus.toast(txt, "good")
	for p in people.at_base():
		if p["job"] == "build":
			people.remember(p, "Мы достроили %s." % Registry.display_name("base_module", id), 2.0)


func _auto_assign() -> void:
	var idle := people.at_base().filter(func(p): return p["job"] == "idle" and people.can_work(p))
	if idle.is_empty():
		return
	var wanted := []  # [job, skill, priority]
	if not queue.is_empty():
		wanted.append(["build", "building", 9.0])
	if food_days() < 3.0 and level("garden") > 0:
		wanted.append(["garden", "farming", 8.0])
	if water_days() < 3.0 and level("water") > 0:
		wanted.append(["water", "engineering", 8.5])
	for id in ["infirmary", "kitchen", "garden", "water", "workshop", "radio"]:
		if level(id) > 0 and staff_of(id).size() < staff_slots(id):
			wanted.append([id, str(Registry.get_def("base_module", id).get("skill", "")), 5.0])
	if people.at_base().filter(func(p): return p["job"] == "guard").size() < 1 + int(Session.world_map.density(region_id) > 0.5):
		wanted.append(["guard", "combat", 6.0])
	if food_days() < 2.0 or water_days() < 2.0:
		wanted.append(["scavenge", "scavenging", 7.0])
	wanted.sort_custom(func(a, b): return a[2] > b[2])
	for w in wanted:
		if idle.is_empty():
			break
		var best: Dictionary = {}
		var best_skill := -1.0
		for p in idle:
			var sk := people.skill(p, str(w[1])) if str(w[1]) != "" else 0.0
			if sk > best_skill:
				best_skill = sk
				best = p
		best["job"] = w[0]
		idle.erase(best)
		if w[0] == "scavenge":
			_start_scavenge(best)


func set_job(p: Dictionary, job: String) -> void:
	if p["status"] != "base":
		return
	p["job"] = job
	if job == "scavenge":
		_start_scavenge(p)
	changed.emit()


func _start_scavenge(p: Dictionary) -> void:
	if not people.can_work(p):
		p["job"] = "idle"
		return
	var options := [region_id] + Session.world_map.neighbors(region_id)
	var target: String = options[_rng.randi() % options.size()]
	p["status"] = "away"
	p["away_target"] = target
	p["away_until"] = Clock.total_minutes + SCAVENGE_HOURS * 60.0 * (1.0 if target == region_id else 1.5)


func _returns() -> void:
	for p in people.people:
		if p["status"] != "away" or Clock.total_minutes < float(p["away_until"]):
			continue
		var target := str(p["away_target"])
		var dens := Session.world_map.density(target)
		var region := Registry.get_def("region", target)
		var lines := PackedStringArray()
		var risk := dens * 0.35 * Session.config.p("zombie_count") * (1.0 - people.skill(p, "combat") / 15.0)
		if _rng.randf() < risk:
			if _rng.randf() < 0.18 * Session.config.p("zombie_damage") and not Session.offline_mode:
				p["status"] = "base"
				_kill(p, "заражённых на вылазке в «%s»" % region.get("name", "?"))
				continue
			p["injury_hours"] = float(p["injury_hours"]) + _rng.randf_range(12.0, 48.0)
			p["health"] = maxf(25.0, float(p["health"]) - _rng.randf_range(15.0, 40.0))
			lines.append("ранен(а)")
			if _rng.randf() < 0.15 * Session.config.p("infection"):
				p["infected_hidden"] = true
		var scar := maxf(0.2, 1.0 - float(Session.world_map.regions.get(target, {}).get("searched", 0)) * 0.2)
		var found := 0
		for i in 1 + int(people.skill(p, "scavenging") / 4.0):
			for it in AfInventory.roll_loot(str(region.get("loot_table", "region_town")), _rng, scar):
				found += int(it["qty"]) - storage.add(it["item"], int(it["qty"]), float(it["quality"]), float(it["condition"]), true)
		p["status"] = "base"
		p["job"] = "idle"
		var txt := "%s вернулся(ась) с вылазки в «%s»: %d предметов%s." % [p["name"], region.get("name", "?"), found, (", " + ", ".join(lines)) if not lines.is_empty() else ""]
		Session.journal.add("base", AfSurvivors.g(txt, bool(p["female"])))
		people.remember(p, "Ходил(а) на вылазку в «%s»." % region.get("name", "?"), 1.0 if lines.is_empty() else -3.0)


func _day() -> void:
	var offline := Session.offline_mode
	# wear
	for id in modules:
		modules[id]["condition"] = maxf(0.1, float(modules[id]["condition"]) - 0.01)
	# morale & loyalty
	var living_count := people.at_base().size()
	var comfort := effect("shelter", "comfort", 0.0) + effect("kitchen", "comfort", 0.0)
	var teacher_aura := 0.0
	for p in people.at_base():
		teacher_aura += float(Registry.get_def("profession", str(p["profession"])).get("morale_aura", 0))
	for p in people.at_base():
		var target := 45.0 + comfort + minf(teacher_aura, 8.0)
		target += -20.0 if living_count > beds() else 5.0
		target += -20.0 if float(p["satiety"]) < 25.0 else 5.0
		target += -20.0 if float(p["hydration"]) < 25.0 else 0.0
		target += -10.0 if float(p["injury_hours"]) > 0.0 else 0.0
		target += clampf((defense() - Session.world_map.density(region_id) * 40.0) * 0.2, -10.0, 8.0)
		target += people.trait_value(p, "morale", 0.0) + people.memory_mood(p)
		p["morale"] = clampf(lerpf(float(p["morale"]), clampf(target, 0.0, 100.0), 0.35), 0.0, 100.0)
		var dl := 0.6 if float(p["morale"]) > 60.0 else (-1.2 if float(p["morale"]) < 30.0 else 0.1)
		p["loyalty"] = clampf(float(p["loyalty"]) + dl, 0.0, 100.0)
		if not offline and float(p["loyalty"]) < 10.0 and float(p["morale"]) < 25.0 and _rng.randf() < 0.5:
			_leave(p)
	# relationships: working side by side brings people together; hotheads clash
	var at := people.at_base()
	for i in at.size():
		for j in range(i + 1, at.size()):
			var a: Dictionary = at[i]
			var b: Dictionary = at[j]
			var delta := 1.0 if a["job"] == b["job"] and a["job"] != "idle" else 0.3
			delta *= people.trait_value(a, "relation_bonus", 1.0) * people.trait_value(b, "relation_bonus", 1.0)
			var quarrel := 0.04 * people.trait_value(a, "quarrel", 1.0) * people.trait_value(b, "quarrel", 1.0)
			if float(a["satiety"]) < 30.0 or float(b["satiety"]) < 30.0:
				quarrel *= 3.0
			if _rng.randf() < quarrel:
				delta = -12.0
				people.remember(a, "Поссорился(ась) с %s." % b["name"], -2.0)
				people.remember(b, "Поссорился(ась) с %s." % a["name"], -2.0)
				Session.journal.add("base", "%s и %s поссорились." % [a["name"], b["name"]])
			var v := clampf(float(a["relations"].get(str(b["id"]), 0.0)) + delta, -100.0, 100.0)
			a["relations"][str(b["id"])] = v
			b["relations"][str(a["id"])] = v
	# hidden infection reveals itself
	for p in people.at_base():
		if bool(p.get("infected_hidden", false)) and float(p["infected_hours"]) < 0.0 and _rng.randf() < 0.5:
			p["infected_hidden"] = false
			p["infected_hours"] = 0.0
			Session.events.queue_bitten(p)
	_raid_check()
	_fire_check()
	Session.events.daily()


func _raid_check() -> void:
	var dens := Session.world_map.density(region_id)
	var noise := effect("generator", "noise", 0.0) if power_output() > 0.0 else 0.0
	var chance := dens * 0.22 * Session.config.p("zombie_count") * (1.0 + noise * 3.0)
	if _rng.randf() >= chance:
		return
	stats["raids"] = int(stats["raids"]) + 1
	var strength := _rng.randf_range(10.0, 45.0) * (0.5 + dens) * Session.config.p("zombie_count")
	var def := defense()
	var used := mini(storage.count("ammo_9x18"), _rng.randi_range(3, 10))
	storage.remove_item("ammo_9x18", used)
	if def >= strength:
		stats["repelled"] = int(stats["repelled"]) + 1
		Session.journal.add("base", "Ночью заражённые подошли к убежищу (%d). Охрана отбилась." % int(strength))
		for p in people.at_base():
			if p["job"] == "guard":
				people.remember(p, "Отбили нападение.", 3.0)
				if _rng.randf() < 0.1:
					p["injury_hours"] = float(p["injury_hours"]) + 12.0
		return
	var lines := PackedStringArray(["Заражённые прорвались в убежище!"])
	var dmg := clampf((strength - def) / 60.0, 0.05, 0.5)
	if Session.offline_mode:
		dmg = minf(dmg, 0.1)
	for id in modules:
		if _rng.randf() < 0.5:
			modules[id]["condition"] = maxf(0.1, float(modules[id]["condition"]) - dmg)
	for p in people.at_base():
		if _rng.randf() < 0.3:
			if not Session.offline_mode and _rng.randf() < 0.25 * Session.config.p("zombie_damage"):
				_kill(p, "нападения заражённых на убежище")
				continue
			p["injury_hours"] = float(p["injury_hours"]) + _rng.randf_range(12.0, 60.0)
			p["health"] = maxf(20.0, float(p["health"]) - 30.0)
			if _rng.randf() < 0.2 * Session.config.p("infection"):
				p["infected_hidden"] = true
		people.remember(p, "Пережил(а) прорыв заражённых.", -6.0)
	Session.journal.add("base", " ".join(lines) + " Повреждены постройки, есть раненые.")
	EventBus.toast("Нападение на убежище! Есть раненые.", "danger")


func _fire_check() -> void:
	for id in modules.keys():
		var ld := level_def(id)
		if float(ld.get("power", 0)) <= 0.0 and not str(id).ends_with("kitchen") and not str(id).ends_with("generator"):
			continue
		if _rng.randf() < 0.02 * (1.0 - condition(id)) * 2.0:
			var staffed := not staff_of(id).is_empty()
			modules[id]["condition"] = maxf(0.1, condition(id) - (0.15 if staffed else 0.4))
			var txt := "Пожар: %s. %s" % [Registry.display_name("base_module", id), "Потушили быстро." if staffed else "Пока заметили — выгорело полпомещения."]
			Session.journal.add("base", txt)
			EventBus.toast(txt, "danger")


func _kill(p: Dictionary, cause: String) -> void:
	p["status"] = "dead"
	p["job"] = "idle"
	stats["deaths"] = int(stats["deaths"]) + 1
	var txt := "%s погиб(ла) от %s." % [p["name"], cause]
	txt = txt.replace("погиб(ла)", "погибла" if bool(p["female"]) else "погиб")
	Session.journal.add("death", txt)
	EventBus.toast(txt, "danger")
	for o in people.living():
		var rel := float(o["relations"].get(str(p["id"]), 0.0))
		people.remember(o, "Гибель: %s." % p["name"], -4.0 - maxf(0.0, rel) / 15.0)


func _leave(p: Dictionary) -> void:
	p["status"] = "left"
	p["job"] = "idle"
	var took := ""
	if _rng.randf() < 0.5:
		for s in storage.stacks.duplicate():
			if storage.def_of(s).get("category") in ["food", "drink"]:
				storage.remove_uid(int(s["uid"]), mini(2, int(s["qty"])))
				took = " и забрал(а) часть припасов"
				break
	var txt := AfSurvivors.g("%s ушёл(ла) из убежища%s." % [p["name"], took], bool(p["female"])).replace("ушёл(ла)", "ушла" if bool(p["female"]) else "ушёл")
	Session.journal.add("base", txt)
	EventBus.toast(txt, "warn")
	for o in people.living():
		people.remember(o, "%s ушёл(ла) от нас." % p["name"], -2.0)


# --- persistence ------------------------------------------------------------------------

func save_key() -> String:
	return "base"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS base_state (key TEXT PRIMARY KEY, value TEXT)"]


func save_to_db(db: AfDatabase) -> void:
	var st := {"exists": exists, "name": name, "place_id": place_id, "region_id": region_id, "founded_day": founded_day,
		"modules": modules, "queue": queue, "recipe_targets": recipe_targets, "recipe_progress": recipe_progress,
		"food_bank": food_bank, "water_bank": water_bank, "fuel_hours": fuel_hours, "auto_assign": auto_assign,
		"stats": stats, "hour_acc": _hour_acc, "day_acc": _day_acc, "fractions": _fractions}
	db.exec("INSERT OR REPLACE INTO base_state VALUES ('state', ?)", [JSON.stringify(st)])
	db.exec("DELETE FROM inventory_items WHERE owner = 'base'")
	for s in storage.stacks:
		db.exec("INSERT INTO inventory_items VALUES ('base', ?, ?, ?, ?, ?, ?)", [s["uid"], s["item"], s["qty"], s["quality"], s["condition"], s.get("ammo", 0)])


func load_from_db(db: AfDatabase) -> void:
	clear()
	if not db.table_exists("base_state"):
		return
	var v: Variant = JSON.parse_string(str(db.scalar("SELECT value FROM base_state WHERE key = 'state'", [], "{}")))
	if typeof(v) != TYPE_DICTIONARY or v.is_empty():
		return
	exists = bool(v.get("exists", false))
	name = str(v.get("name", "Убежище"))
	place_id = str(v.get("place_id", ""))
	region_id = str(v.get("region_id", ""))
	founded_day = int(v.get("founded_day", 0))
	modules = v.get("modules", {})
	for id in modules:
		modules[id]["level"] = int(modules[id]["level"])
	queue = v.get("queue", [])
	for k in v.get("recipe_targets", {}):
		recipe_targets[k] = int(v["recipe_targets"][k])
	recipe_progress = v.get("recipe_progress", {})
	food_bank = float(v.get("food_bank", 0.0))
	water_bank = float(v.get("water_bank", 0.0))
	fuel_hours = float(v.get("fuel_hours", 0.0))
	auto_assign = bool(v.get("auto_assign", true))
	stats = v.get("stats", stats)
	_hour_acc = float(v.get("hour_acc", 0.0))
	_day_acc = float(v.get("day_acc", 0.0))
	_fractions = v.get("fractions", {})
	storage.load_rows(db.select("SELECT * FROM inventory_items WHERE owner = 'base' ORDER BY uid"))
	storage.max_weight = storage_capacity()
