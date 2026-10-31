class_name AfLocationGenerator
extends RefCounted
## Builds a playable location definition for a map place (hospital, police,
## mall, school, factory…) from a type template. Deterministic: the same place
## always produces the same layout (seeded by its id), so nothing but the
## location state (looted containers, surviving infected) has to be saved.
## Hand-made locations (place.location) always take precedence.

const PREFIX := "gen:"

const TYPE_NAMES := {
	"residential": "Жилой двор", "hospital": "Больница", "police": "Отдел полиции", "fire_station": "Пожарная часть",
	"university": "Университет", "college": "Колледж", "school": "Школа", "mall": "Торговый центр",
	"supermarket": "Супермаркет", "market": "Рынок", "townhall": "Администрация", "prison": "Исправительное учреждение",
	"bus_station": "Автовокзал", "station": "Вокзал", "industrial": "Промзона", "power_plant": "ТЭЦ",
	"park": "Парк", "stadium": "Стадион", "fuel": "АЗС", "military": "Военный объект",
}


static func type_name(t: String) -> String:
	return str(TYPE_NAMES.get(t, "Место"))


## Returns the location id to enter for a place (registering a generated one if needed).
static func ensure_for_place(place_id: String) -> String:
	var place := Registry.get_def("place", place_id)
	if place.is_empty():
		return ""
	if place.has("location"):
		var loc := RegistryHelpers.full_id_for(str(place["location"]), str(place.get("_package", "core")), "location")
		if Registry.has_def("location", loc):
			return loc
	var def := generate(place)
	Registry.add_runtime_def("location", def)
	return str(def["id"])


## For saves made inside a generated location.
static func ensure_location(loc_id: String) -> bool:
	if Registry.has_def("location", loc_id):
		return true
	if not loc_id.begins_with(PREFIX):
		return false
	return ensure_for_place(loc_id.substr(PREFIX.length())) == loc_id


static func generate(place: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(place["id"]))
	var g := _Gen.new(rng)
	var t := str(place.get("type", "residential"))
	match t:
		"hospital": g.hospital()
		"police": g.police()
		"fire_station": g.fire_station()
		"university", "college", "school": g.school(t)
		"mall": g.mall()
		"supermarket": g.supermarket()
		"market": g.market()
		"townhall": g.townhall()
		"prison": g.prison()
		"bus_station", "station": g.station(t)
		"industrial", "power_plant": g.industrial(t)
		"park", "stadium": g.park(t)
		"fuel": g.fuel()
		"military": g.military()
		_: g.residential()
	var region := "core:" + str(place.get("city", "ufa"))
	return {
		"id": PREFIX + str(place["id"]),
		"name": "%s — %s" % [Registry.display_name("region", region), place["name"]],
		"region": region,
		"place": place["id"],
		"size": [g.w, g.d],
		"ground_color": g.ground,
		"player_spawn": [0, g.d / 2.0 - 11.0],
		"patches": g.patches,
		"buildings": g.buildings,
		"props": g.props,
		"lights": g.lights,
		"containers": g.containers,
		"zombie_spawns": g.spawns,
		"exits": [{"id": "street", "name": "Выход на улицу", "pos": [0, g.d / 2.0 - 2.5], "radius": 3}],
		"_package": "core",
		"generated": true,
	}


class _Gen:
	var rng: RandomNumberGenerator
	var w := 80.0
	var d := 80.0
	var ground := "#2b2c2a"
	var patches: Array = []
	var buildings: Array = []
	var props: Array = []
	var lights: Array = []
	var containers: Array = []
	var spawns: Array = []
	var _cid := 0

	func _init(r: RandomNumberGenerator) -> void:
		rng = r

	func j(v: float, amount: float = 1.5) -> float:
		return v + rng.randf_range(-amount, amount)

	func building(name: String, x: float, z: float, sx: float, h: float, sz: float, color: String, kind: String = "panel") -> void:
		buildings.append({"name": name, "pos": [x, z], "size": [sx, h, sz], "color": color, "kind": kind})

	## Container in front (south side) of a point.
	func box(name: String, x: float, z: float, table: String, sec: float = 4.0) -> void:
		_cid += 1
		containers.append({"id": "c%d" % _cid, "name": name, "pos": [x, z], "loot_table": table, "search_sec": sec})

	func spawn(type: String, x: float, z: float, count: int, radius: float = 4.0) -> void:
		spawns.append({"type": type, "pos": [x, z], "count": count, "radius": radius})

	func cars(n: int, x0: float, z0: float, x1: float, z1: float, palette: Array = ["#5b6b7a", "#7a3b33", "#c8c4b8", "#3a4a3a", "#8a7a5a", "#2a2d33"]) -> void:
		for i in n:
			props.append({"type": "car", "pos": [rng.randf_range(x0, x1), rng.randf_range(z0, z1)], "rot": rng.randf_range(-30, 30) + (90.0 if rng.randf() < 0.3 else 0.0),
				"color": palette[rng.randi() % palette.size()]})

	func trees(n: int, x0: float, z0: float, x1: float, z1: float) -> void:
		for i in n:
			props.append({"type": "tree", "pos": [rng.randf_range(x0, x1), rng.randf_range(z0, z1)]})

	func barrel(x: float, z: float) -> void:
		lights.append({"type": "fire_barrel", "pos": [x, z]})

	func common_street() -> void:
		patches.append({"pos": [0, d / 2.0 - 6.0], "size": [w, 10], "color": "#232422"})
		props.append({"type": "barricade", "pos": [j(-12.0, 4), d / 2.0 - 9.0], "rot": j(0.0, 15)})
		spawn("walker", j(0.0, 8), d / 2.0 - 14.0, 2 + rng.randi() % 2, 6)

	# --- templates ---------------------------------------------------------------

	func residential() -> void:
		building("Пятиэтажка", -16, -22, 34, 14, 11, "#8d8a83")
		building("Пятиэтажка", 22, -10, 11, 14, 30, "#9a948a")
		building("Девятиэтажка", -28, 12, 12, 26, 24, "#a19d95")
		for i in 4:
			box("Квартира %d" % (10 + rng.randi() % 90), j(-28.0 + i * 8, 1), -15.5, "residential", 4)
		box("Подъезд — почтовые ящики", 15.5, -6, "residential", 3)
		box("Подвал девятиэтажки", -21, 8, "residential", 4)
		patches.append({"pos": [0, 0], "size": [18, 12], "color": "#33402c"})
		props.append({"type": "swing", "pos": [0, 0], "rot": 0})
		props.append({"type": "bench", "pos": [-5, 4], "rot": 0})
		cars(4, -10, 8, 12, 22)
		box("Машина у подъезда", j(4.0), 17, "car", 3)
		trees(5, -36, -36, 36, 30)
		barrel(6, 6)
		spawn("walker", 0, -5, 5, 8)
		spawn("walker", 18, 14, 3, 5)
		if rng.randf() < 0.5:
			spawn("lurker", -22, 6, 1, 1)
		common_street()

	func hospital() -> void:
		building("Главный корпус", -6, -20, 46, 18, 16, "#b9b6ad", "office")
		building("Приёмное отделение", 26, 0, 14, 6, 12, "#a8b4b0", "office")
		building("Морг", -30, 14, 10, 4, 8, "#7f8784", "office")
		box("Регистратура", -10, -11, "pharmacy", 4)
		box("Ординаторская", 4, -11, "pharmacy", 5)
		box("Склад медикаментов", -24, -11, "pharmacy", 6)
		box("Приёмный покой", 26, 7.5, "pharmacy", 4)
		box("Палата", 12, -11, "residential", 3)
		cars(2, 10, 6, 20, 16, ["#e8e6df"])  # ambulances
		cars(4, -20, 10, 0, 22)
		box("Скорая помощь", 15, 12, "pharmacy", 3)
		trees(4, -38, -36, 38, -30)
		spawn("walker", 0, -4, 8, 10)
		spawn("runner", 24, 12, 2, 3)
		spawn("walker", -30, 20, 3, 3)
		barrel(-4, 4)
		common_street()

	func police() -> void:
		building("Здание отдела", -4, -18, 30, 9, 12, "#4f5a6b", "office")
		building("Гараж", 24, -14, 12, 4, 10, "#5d5a55", "garage")
		box("Дежурная часть", -8, -10.5, "police", 5)
		box("Оружейная комната", 4, -10.5, "police", 7)
		box("Гараж — служебные машины", 24, -7.5, "garage", 5)
		cars(4, -16, 0, 16, 14, ["#2d3b55", "#e8e6df"])
		box("Патрульная машина", j(-4.0, 6), 6, "car", 3)
		props.append({"type": "barricade", "pos": [0, 18], "rot": 0})
		spawn("walker", 0, 0, 4, 8)
		spawn("riot", 8, -4, 2, 3)
		barrel(-14, 4)
		common_street()

	func fire_station() -> void:
		building("Депо", 0, -16, 32, 8, 16, "#a0413a", "garage")
		building("Вышка", 22, -18, 5, 16, 5, "#8a3a33", "office")
		box("Бокс пожарных машин", -6, -7.5, "garage", 5)
		box("Аптечка дежурной смены", 6, -7.5, "pharmacy", 3)
		cars(2, -10, 0, 10, 8, ["#c0392b"])
		spawn("walker", 0, 4, 4, 6)
		common_street()

	func school(kind: String) -> void:
		var big := kind != "school"
		building("Учебный корпус", -2, -20, 52 if big else 40, 14 if big else 10, 14, "#b5a58a" if big else "#c2b28f", "office")
		if big:
			building("Общежитие", 28, 10, 12, 18, 24, "#9a948a")
			box("Общежитие — комнаты", 21, 8, "residential", 4)
			box("Лаборатория", 10, -12, "pharmacy" if kind == "university" else "garage", 6)
		box("Аудитория", -14, -12, "residential", 4)
		box("Буфет", -2, -12, "kiosk", 4)
		box("Кабинет директора", 14 if not big else -24, -12, "residential", 4)
		patches.append({"pos": [-10, 8], "size": [30, 18], "color": "#3a4030"})
		props.append({"type": "swing", "pos": [-14, 8], "rot": 0})
		trees(6, -36, 0, 0, 30)
		spawn("walker", -6, 2, 9 if big else 6, 10)
		spawn("runner", 8, 10, 2, 4)
		common_street()

	func mall() -> void:
		building("Торговый центр", 0, -18, 56, 12, 30, "#6f7680", "office")
		box("Продуктовый гипермаркет", -20, -2.5, "kiosk", 5)
		box("Аптека", -8, -2.5, "pharmacy", 4)
		box("Магазин одежды", 4, -2.5, "residential", 4)
		box("Электроника", 14, -2.5, "car", 4)
		box("Склад — разгрузка", 24, -2.5, "garage", 6)
		cars(10, -34, 6, 34, 24)
		box("Брошенная машина на парковке", j(-20.0, 6), 14, "car", 3)
		box("Машина у входа", j(18.0, 6), 12, "car", 3)
		barrel(0, 10)
		spawn("walker", -10, 6, 8, 12)
		spawn("walker", 16, 16, 4, 6)
		spawn("runner", 0, 2, 3, 4)
		spawn("lurker", 28, -2, 1, 1)
		common_street()

	func supermarket() -> void:
		building("Супермаркет", -4, -16, 32, 6, 22, "#7e6a55", "shop")
		box("Торговый зал", -12, -4.5, "kiosk", 5)
		box("Касса", -2, -4.5, "kiosk", 3)
		box("Подсобка", 8, -4.5, "kiosk", 5)
		cars(5, -20, 4, 20, 20)
		box("Машина на парковке", j(10.0, 6), 12, "car", 3)
		spawn("walker", 0, 4, 5, 8)
		common_street()

	func market() -> void:
		for i in 6:
			building("Павильон", -25 + i * 10, -14, 7, 3.5, 6, ["#8a6a4a", "#6a7a5a", "#7a5a5a"][i % 3], "shop")
			if i % 2 == 0:
				box("Прилавок", -25 + i * 10, -9.5, "kiosk", 3)
		building("Крытый рынок", 0, 8, 30, 7, 12, "#7e7466", "shop")
		box("Мясной ряд", -6, 15, "kiosk", 4)
		box("Склад рынка", 8, 15, "garage", 5)
		cars(3, -30, 20, 30, 28, ["#c8c4b8", "#5b6b7a"])
		spawn("walker", 0, -4, 8, 12)
		spawn("runner", -20, 4, 2, 3)
		common_street()

	func townhall() -> void:
		building("Администрация", 0, -18, 40, 14, 16, "#b8b2a6", "office")
		box("Приёмная", -10, -9.5, "residential", 4)
		box("Архив", 4, -9.5, "residential", 6)
		box("Пост охраны", 14, -9.5, "police", 4)
		patches.append({"pos": [0, 4], "size": [30, 14], "color": "#3a3f3a"})
		trees(6, -30, -4, 30, 12)
		cars(3, -20, 14, 20, 22, ["#1e2228", "#2a2d33"])
		spawn("walker", 0, 2, 5, 8)
		spawn("riot", 10, -6, 1, 1)
		common_street()

	func prison() -> void:
		for side in [[-30.0, 0.0, 2.0, 50.0], [30.0, 0.0, 2.0, 50.0], [0.0, -26.0, 62.0, 2.0]]:
			building("Ограда", side[0], side[1], side[2], 5, side[3], "#6a6a66", "utility")
		building("Корпус", -8, -12, 30, 10, 12, "#6f6c66", "office")
		building("КПП", 14, 16, 10, 4, 6, "#5a5f66", "office")
		box("Дежурная", 14, 20, "police", 5)
		box("Оружейная", -4, -5.5, "police", 7)
		box("Камеры", -16, -5.5, "residential", 4)
		spawn("walker", -6, 4, 8, 10)
		spawn("riot", 10, 6, 3, 4)
		common_street()

	func station(kind: String) -> void:
		building("Вокзал" if kind == "station" else "Автовокзал", 0, -20, 44, 10, 14, "#b0a48c", "office")
		box("Зал ожидания", -10, -12, "residential", 4)
		box("Буфет", 2, -12, "kiosk", 4)
		box("Камера хранения", 14, -12, "residential", 5)
		if kind == "station":
			patches.append({"pos": [0, 2], "size": [76, 4], "color": "#4a4038"})
			for i in 3:
				props.append({"type": "bus", "pos": [-24 + i * 22, 2], "rot": 90, "color": "#3a6a5a"})
		else:
			for i in 3:
				props.append({"type": "bus", "pos": [-20 + i * 16, 6], "rot": 0, "color": "#d9c46a"})
		box("Брошенный автобус", 0, 12, "car", 4)
		cars(3, -30, 14, 30, 22)
		spawn("walker", 0, -2, 9, 12)
		spawn("runner", -16, 10, 2, 3)
		common_street()

	func industrial(kind: String) -> void:
		ground = "#2f2e2a"
		building("Цех" if kind == "industrial" else "Машинный зал", -14, -18, 34, 12, 18, "#8e8a7e", "industrial")
		building("Склад", 24, -14, 16, 8, 22, "#9a958a", "industrial")
		building("Ёмкость", 20, 16, 8, 10, 8, "#b9b4a6", "tank")
		building("Ёмкость", 30, 16, 8, 10, 8, "#b9b4a6", "tank")
		if kind == "power_plant":
			building("Труба", -30, 18, 5, 30, 5, "#a39a8a", "tank")
		box("Цех — инструментальная", -20, -8, "garage", 5)
		box("Склад", 16, -2, "region_industrial", 6)
		box("Бытовка", -4, -8, "residential", 4)
		box("Пульт управления", 4, -8, "region_industrial", 5)
		cars(2, -20, 6, 0, 14, ["#5a5f4a", "#6a5a3a"])
		barrel(-6, 4)
		spawn("walker", 0, 2, 6, 10)
		spawn("lurker", 24, 4, 1, 1)
		common_street()

	func park(kind: String) -> void:
		ground = "#2d3328"
		if kind == "stadium":
			building("Трибуна", 0, -26, 50, 8, 8, "#7a7f86", "office")
			patches.append({"pos": [0, -4], "size": [46, 30], "color": "#36502c"})
			box("Раздевалка", -16, -21, "residential", 4)
			box("Ларёк", 16, -21, "kiosk", 3)
			spawn("walker", 0, -4, 8, 14)
		else:
			patches.append({"pos": [0, 0], "size": [70, 60], "color": "#34442d"})
			trees(22, -36, -36, 36, 26)
			for i in 4:
				props.append({"type": "bench", "pos": [rng.randf_range(-20, 20), rng.randf_range(-20, 10)], "rot": rng.randf_range(0, 180)})
			building("Летнее кафе", 18, -18, 10, 3.5, 8, "#7e6a55", "shop")
			box("Летнее кафе", 18, -13, "kiosk", 3)
			box("Будка сторожа", -24, -20, "residential", 3)
			spawn("walker", 0, -6, 5, 14)
			spawn("lurker", -20, 0, 1, 1)
		barrel(4, 8)
		common_street()

	func fuel() -> void:
		building("Магазин АЗС", -12, -16, 14, 4, 10, "#c0b8a0", "shop")
		building("Навес", 10, -8, 22, 1, 12, "#d0c8b0", "utility")
		box("Касса и магазин", -12, -10.5, "kiosk", 4)
		box("Подсобка", -4, -12, "garage", 4)
		cars(4, -6, 0, 24, 12)
		box("Машина у колонки", 6, 2, "car", 3)
		spawn("walker", 4, 0, 3, 6)
		common_street()

	func military() -> void:
		building("Казарма", -16, -18, 30, 8, 12, "#4b5a3a", "office")
		building("Склад вооружения", 22, -16, 14, 5, 12, "#3f4a35", "industrial")
		building("КПП", 0, 18, 8, 4, 6, "#4b5a3a", "office")
		box("Оружейный склад", 22, -9.5, "region_military", 7)
		box("Казарма", -16, -11.5, "region_military", 5)
		box("Гараж техники", 4, -6, "garage", 5)
		box("КПП", 0, 22, "police", 4)
		props.append({"type": "barricade", "pos": [-10, 20], "rot": 0})
		props.append({"type": "barricade", "pos": [10, 20], "rot": 0})
		cars(3, -20, 0, 20, 10, ["#4b5a3a"])
		spawn("riot", 0, -2, 3, 6)
		spawn("walker", -14, 4, 5, 8)
		common_street()
