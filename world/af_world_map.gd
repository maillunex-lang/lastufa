class_name AfWorldMap
extends RefCounted
## Strategic layer: Bashkortostan as a graph of regions connected by roads.
## Tracks intel (fog of war), strategic zombie density with migration, the
## hero's current region, overland travel and area searches.

const INTEL_NAMES := ["Неизвестно", "Слухи", "Разведано", "Посещено"]
const WALK_KMH := 4.5
const ROAD_FACTOR := 1.2

var regions := {}       # region id -> {intel, density, searched, visits}
var current_region := "core:ufa"
## Inside a city (e.g. Ufa): the place the hero stands at ("" = city entrance / not in a city).
var current_place := ""
const START_PLACE := "core:ufa_chernikovka_yard"
const CITY_WALK_KMH := 4.0
const CITY_ROUTE_FACTOR := 1.35
var _edges := {}        # region id -> {neighbor id: km}
var _rng := RandomNumberGenerator.new()


func build_graph() -> void:
	_edges.clear()
	for road in Registry.all("road"):
		var nodes: Array = road.get("nodes", [])
		for i in range(nodes.size() - 1):
			var a := Registry.resolve("region", str(nodes[i]))
			var b := Registry.resolve("region", str(nodes[i + 1]))
			if a == "" or b == "":
				continue
			var km := distance_km(a, b) * ROAD_FACTOR
			if not _edges.has(a):
				_edges[a] = {}
			if not _edges.has(b):
				_edges[b] = {}
			_edges[a][b] = km
			_edges[b][a] = km
	# generated proximity links between neighbouring settlements (local roads)
	for r in Registry.all("region"):
		var a := str(r["id"])
		for l in r.get("links", []):
			var b := Registry.resolve("region", str(l))
			if b == "" or b == a:
				continue
			var km := distance_km(a, b) * 1.25
			if not _edges.has(a):
				_edges[a] = {}
			if not _edges.has(b):
				_edges[b] = {}
			if not _edges[a].has(b):
				_edges[a][b] = km
				_edges[b][a] = km


func new_game() -> void:
	_rng.randomize()
	regions.clear()
	build_graph()
	for r in Registry.all("region"):
		regions[r["id"]] = {"intel": 0, "density": float(r.get("danger", 0.3)), "searched": 0, "visits": 0}
	current_region = "core:ufa"
	current_place = START_PLACE
	set_intel(current_region, 3)
	regions[current_region]["visits"] = 1
	for n in neighbors(current_region):
		set_intel(n, 1)


## Ensures regions added by newly installed packages get state entries.
func sync_with_registry() -> void:
	build_graph()
	for r in Registry.all("region"):
		if not regions.has(r["id"]):
			regions[r["id"]] = {"intel": 0, "density": float(r.get("danger", 0.3)), "searched": 0, "visits": 0}


func neighbors(id: String) -> Array:
	return _edges.get(id, {}).keys()


func road_km(a: String, b: String) -> float:
	return float(_edges.get(a, {}).get(b, -1.0))


func distance_km(a: String, b: String) -> float:
	var ra := Registry.get_def("region", a)
	var rb := Registry.get_def("region", b)
	if ra.is_empty() or rb.is_empty():
		return 0.0
	return haversine_km(float(ra["lat"]), float(ra["lon"]), float(rb["lat"]), float(rb["lon"]))


static func haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var r := 6371.0
	var dlat := deg_to_rad(lat2 - lat1)
	var dlon := deg_to_rad(lon2 - lon1)
	var a := sin(dlat / 2) * sin(dlat / 2) + cos(deg_to_rad(lat1)) * cos(deg_to_rad(lat2)) * sin(dlon / 2) * sin(dlon / 2)
	return r * 2.0 * atan2(sqrt(a), sqrt(1.0 - a))


func intel(id: String) -> int:
	return int(regions.get(id, {}).get("intel", 0))


func set_intel(id: String, level: int) -> void:
	if regions.has(id) and level > intel(id):
		regions[id]["intel"] = level


func density(id: String) -> float:
	return float(regions.get(id, {}).get("density", 0.0))


func density_label(id: String) -> String:
	var lvl := intel(id)
	if lvl == 0:
		return "нет данных"
	var d := density(id)
	if lvl == 1:
		return "высокая?" if d > 0.55 else "умеренная?"
	if d > 0.75:
		return "очень высокая"
	if d > 0.5:
		return "высокая"
	if d > 0.25:
		return "умеренная"
	return "низкая"


## Strategic tier: migration toward neighbours, seasonal effects, hordes.
func simulate(dt_minutes: float) -> void:
	var days := dt_minutes / 1440.0
	var season := Clock.season()
	var mobility: float = {"winter": 0.25, "spring": 0.8, "summer": 1.0, "autumn": 0.8}[season]
	var flow := {}
	for id in regions:
		flow[id] = 0.0
	for a in _edges:
		if not regions.has(a):
			continue
		for b in _edges[a]:
			if not regions.has(b) or a > b:
				continue
			var diff := density(a) - density(b)
			var km: float = _edges[a][b]
			var f := diff * 0.08 * mobility * days * clampf(60.0 / maxf(km, 10.0), 0.2, 1.5)
			flow[a] -= f
			flow[b] += f
	for id in regions:
		var d := density(id) + float(flow[id])
		if season == "summer":
			d -= 0.004 * days # heat breaks bodies down slowly
		regions[id]["density"] = clampf(d, 0.0, 1.0)
	# hordes: occasional mass movement out of dense regions
	if _rng.randf() < 0.05 * days * mobility:
		var src := ""
		var best := 0.6
		for id in regions:
			if density(id) > best:
				best = density(id)
				src = id
		if src != "":
			var ns := neighbors(src)
			if not ns.is_empty():
				var dst: String = ns[_rng.randi() % ns.size()]
				var moved := density(src) * 0.15
				regions[src]["density"] = density(src) - moved
				regions[dst]["density"] = clampf(density(dst) + moved, 0.0, 1.0)
				if intel(dst) >= 2 or intel(src) >= 2 or dst == current_region:
					Session.journal.add("world", "Орда заражённых движется из района «%s» к «%s»." % [Registry.display_name("region", src), Registry.display_name("region", dst)])


func add_noise(id: String, amount: float) -> void:
	if regions.has(id):
		regions[id]["density"] = clampf(density(id) + amount, 0.0, 1.0)


# --- overland actions -------------------------------------------------------------

func travel_hours(to_id: String) -> float:
	var km := road_km(current_region, to_id)
	if km < 0.0:
		return -1.0
	return km / (WALK_KMH * Session.player.survival.move_multiplier())


## Walks to a neighbouring region. Time passes, needs are auto-managed from the
## inventory, encounters can happen. Returns a list of report lines.
func travel(to_id: String) -> PackedStringArray:
	var report := PackedStringArray()
	var km := road_km(current_region, to_id)
	if km < 0.0:
		report.append("Нет дороги в этот район.")
		return report
	var p := Session.player
	var from_id := current_region
	var done_km := 0.0
	var hours := 0
	p.survival.exertion = 1.0
	while done_km < km and not p.survival.dead:
		if p.survival.need("energy") < 20.0:
			report.append("Привал: сон 6 ч.")
			p.survival.sleeping = true
			p.survival.exertion = 0.0
			Scheduler.fast_forward(360.0, 60.0)
			p.survival.sleeping = false
			p.survival.exertion = 1.0
			continue
		Scheduler.fast_forward(60.0, 30.0)
		hours += 1
		done_km += WALK_KMH * p.survival.move_multiplier() * Session.weather.move_mult()
		_auto_consume(report)
		var dens := lerpf(density(from_id), density(to_id), clampf(done_km / km, 0.0, 1.0))
		if _rng.randf() < dens * 0.12 * Session.config.p("zombie_count"):
			report.append(_encounter(dens))
	p.survival.exertion = 0.0
	if p.survival.dead:
		report.append("Вы не дошли.")
		return report
	current_region = to_id
	current_place = ""
	regions[to_id]["visits"] = int(regions[to_id]["visits"]) + 1
	set_intel(to_id, 3)
	for n in neighbors(to_id):
		set_intel(n, 1)
	report.insert(0, "Путь «%s» → «%s»: %.0f км, %d ч." % [Registry.display_name("region", from_id), Registry.display_name("region", to_id), km, hours])
	Session.journal.add("travel", "Добрались до района «%s»." % Registry.display_name("region", to_id))
	EventBus.region_visited.emit(to_id)
	return report


## Searches the surroundings of the current region (3 hours).
func search_area() -> PackedStringArray:
	var report := PackedStringArray()
	var p := Session.player
	var rdef := Registry.get_def("region", current_region)
	var st: Dictionary = regions[current_region]
	var scarcity := maxf(0.15, 1.0 - float(st["searched"]) * 0.3)
	p.survival.exertion = 1.0
	for _h in 3:
		Scheduler.fast_forward(60.0, 30.0)
		if p.survival.dead:
			break
		if _rng.randf() < density(current_region) * 0.25 * Session.config.p("zombie_count"):
			report.append(_encounter(density(current_region)))
	p.survival.exertion = 0.0
	if p.survival.dead:
		return report
	st["searched"] = int(st["searched"]) + 1
	var found := AfInventory.roll_loot(str(rdef.get("loot_table", "region_town")), _rng, scarcity)
	if found.is_empty():
		report.append("Ничего полезного. Район уже обобран." if scarcity < 0.5 else "Ничего полезного.")
	for it in found:
		var left := p.inventory.add(it["item"], int(it["qty"]), float(it["quality"]), float(it["condition"]))
		var got := int(it["qty"]) - left
		if got > 0:
			report.append("Найдено: %s ×%d" % [Registry.display_name("item", it["item"]), got])
		if left > 0:
			report.append("Не унести (перегруз): %s ×%d" % [Registry.display_name("item", it["item"]), left])
	set_intel(current_region, 3)
	return report


func _auto_consume(report: PackedStringArray) -> void:
	var p := Session.player
	for pair in [["hydration", "drink"], ["satiety", "food"]]:
		if p.survival.need(pair[0]) > 45.0 or Session.config.disabled_needs().has(pair[0]):
			continue
		for s in p.inventory.stacks:
			var d := p.inventory.def_of(s)
			if d.get("category") == pair[1] and s.get("available", true) and not str(d["id"]).ends_with("dirty_water"):
				report.append("В пути: " + p.use_item(int(s["uid"])))
				break


func _encounter(dens: float) -> String:
	var p := Session.player
	var weapon := p.equipped_def("firearm")
	var stack := p.equipped_stack("firearm")
	var defense := 0.0
	var how := "голыми руками"
	if not weapon.is_empty() and int(stack.get("ammo", 0)) > 0:
		var spent := mini(int(stack["ammo"]), _rng.randi_range(1, 4))
		stack["ammo"] = int(stack["ammo"]) - spent
		defense = 0.6
		how = "%s (%d выстр.)" % [weapon["name"], spent]
		add_noise(current_region, 0.01)
	else:
		var melee := p.equipped_def("melee")
		var mstack := p.equipped_stack("melee")
		if not melee.is_empty() and float(mstack.get("condition", 0.0)) > 0.0:
			defense = 0.35 * float(mstack["condition"])
			mstack["condition"] = maxf(0.0, float(mstack["condition"]) - 0.03)
			how = str(melee["name"])
	var dmg := _rng.randf_range(4.0, 16.0) * (0.5 + dens) * (1.0 - defense) * Session.config.p("zombie_damage")
	p.survival.take_hit(dmg, "нападение заражённых")
	var extra := ""
	if _rng.randf() < 0.3 * (1.0 - defense):
		p.survival.add_injury("bleeding", _rng.randf_range(0.2, 0.6), "left_arm")
		extra = ", кровотечение"
	if p.survival.expose_to_infection(0.03 * (1.0 - defense)):
		Log.d("worldmap", "infected during encounter")
	return "Стычка с заражёнными (%s): −%.0f здоровья%s." % [how, dmg, extra]


# --- districts and cities ---------------------------------------------------------

func district_of(region_id: String) -> String:
	return str(Registry.get_def("region", region_id).get("district", ""))


func district_regions(district_id: String) -> Array:
	return Registry.all("region").filter(func(r): return str(r.get("district", "")) == district_id)


## Intel of a district = best intel of its settlements.
func district_intel(district_id: String) -> int:
	var best := 0
	for r in district_regions(district_id):
		best = maxi(best, intel(str(r["id"])))
	return best


func district_density(district_id: String) -> float:
	var rs := district_regions(district_id)
	if rs.is_empty():
		return 0.0
	var s := 0.0
	for r in rs:
		s += density(str(r["id"]))
	return s / rs.size()


func city_of_region(region_id: String) -> String:
	return str(Registry.get_def("region", region_id).get("city", ""))


func in_city(city: String) -> bool:
	return city != "" and city_of_region(current_region) == city


func place_pos(place_id: String) -> Vector2:
	var p := Registry.get_def("place", place_id)
	if p.is_empty():
		var r := Registry.get_def("region", current_region)
		return Vector2(float(r.get("lat", 0.0)), float(r.get("lon", 0.0)))
	return Vector2(float(p["lat"]), float(p["lon"]))


## Walking time inside the city from the current place (or city entrance).
func walk_minutes(place_id: String) -> float:
	var a := place_pos(current_place)
	var b := place_pos(place_id)
	var d := haversine_km(a.x, a.y, b.x, b.y) * CITY_ROUTE_FACTOR
	return d / (CITY_WALK_KMH * maxf(0.3, Session.player.survival.move_multiplier())) * 60.0


## Walks through the city to a place. Time passes, encounters depend on the
## city's infection density. Returns report lines.
func walk_to_place(place_id: String) -> PackedStringArray:
	var report := PackedStringArray()
	var p := Session.player
	var minutes := walk_minutes(place_id)
	var dens := density(current_region)
	p.survival.exertion = 1.0
	var left := minutes
	while left > 0.0 and not p.survival.dead:
		var step := minf(30.0, left)
		Scheduler.fast_forward(step, step)
		left -= step
		if _rng.randf() < dens * 0.08 * step / 30.0 * Session.config.p("zombie_count"):
			report.append(_encounter(dens))
	p.survival.exertion = 0.0
	if p.survival.dead:
		report.append("Вы не дошли.")
		return report
	current_place = place_id
	var name := Registry.display_name("place", place_id)
	report.insert(0, "Дорога до «%s»: %d мин." % [name, int(minutes)])
	return report


# --- persistence -------------------------------------------------------------

func save_key() -> String:
	return "world_map"


func schema_sql() -> PackedStringArray:
	return [
		"CREATE TABLE IF NOT EXISTS regions (id TEXT PRIMARY KEY, intel INTEGER, density REAL, searched INTEGER, visits INTEGER)",
		"CREATE TABLE IF NOT EXISTS world_state (key TEXT PRIMARY KEY, value TEXT)",
	]


func save_to_db(db: AfDatabase) -> void:
	db.exec("DELETE FROM regions")
	for id in regions:
		var r: Dictionary = regions[id]
		db.exec("INSERT INTO regions VALUES (?, ?, ?, ?, ?)", [id, r["intel"], r["density"], r["searched"], r["visits"]])
	db.exec("INSERT OR REPLACE INTO world_state VALUES ('current_region', ?)", [current_region])
	db.exec("INSERT OR REPLACE INTO world_state VALUES ('current_place', ?)", [current_place])


func load_from_db(db: AfDatabase) -> void:
	_rng.randomize()
	regions.clear()
	build_graph()
	# rows for regions whose package is missing are kept as-is (preserved, inactive)
	for r in db.select("SELECT * FROM regions"):
		regions[r["id"]] = {"intel": int(r["intel"]), "density": float(r["density"]), "searched": int(r["searched"]), "visits": int(r["visits"])}
	sync_with_registry()
	var cur: Variant = db.scalar("SELECT value FROM world_state WHERE key = 'current_region'", [], "core:ufa")
	current_region = str(cur) if Registry.has_def("region", str(cur)) else "core:ufa"
	current_place = str(db.scalar("SELECT value FROM world_state WHERE key = 'current_place'", [], ""))
	if current_place != "" and not Registry.has_def("place", current_place):
		current_place = ""


func active_region_ids() -> Array:
	return regions.keys().filter(func(id): return Registry.has_def("region", id))
