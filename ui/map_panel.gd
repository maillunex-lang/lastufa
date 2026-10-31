class_name AfMapPanel
extends AfPanel
## Strategic map: Bashkortostan → district → (city → city district → place).
## In "map mode" (the hero is not inside a 3D location) it is the main screen
## and cannot be closed; actions advance game time explicitly.

var world: AfGameWorld
var strategic := false
var _view: AfMapView
var _crumbs: HBoxContainer
var _card: VBoxContainer
var _time_lbl: Label
var _vitals: Label


func _init(p_strategic: bool = false) -> void:
	strategic = p_strategic
	super._init("Карта", true)
	if strategic:
		header.get_child(header.get_child_count() - 1).queue_free()
		header.add_child(AfUI.button("Персонаж", func(): get_parent().add_child(AfCharacterPanel.new()), 140))
		header.add_child(AfUI.button("Убежище", func(): get_parent().add_child(AfBasePanel.new()), 140))
		header.add_child(AfUI.button("Инвентарь", func(): get_parent().add_child(AfInventoryPanel.new()), 140))
		header.add_child(AfUI.button("Меню", func():
			var m := AfGameMenu.new()
			m.world = world
			get_parent().add_child(m), 120))
	var row := AfUI.hbox(14)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(row)
	var left := AfUI.vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.7
	row.add_child(left)
	_crumbs = AfUI.hbox(6)
	left.add_child(_crumbs)
	_view = AfMapView.new()
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.selected.connect(_on_selected)
	_view.level_changed.connect(_rebuild_crumbs)
	left.add_child(_view)
	var side := AfUI.card(16)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.custom_minimum_size = Vector2(390, 0)
	row.add_child(side)
	var sv := AfUI.vbox(8)
	side.add_child(sv)
	_time_lbl = AfUI.label("", 16, AfTheme.TEXT_DIM)
	sv.add_child(_time_lbl)
	_vitals = AfUI.label("", 14, AfTheme.TEXT_DIM, true)
	sv.add_child(_vitals)
	_card = AfUI.vbox(8)
	sv.add_child(AfUI.scroll(_card))


func _ready() -> void:
	_open_where_hero_is.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if not strategic:
		super._unhandled_input(event)


## Opens the most detailed level that contains the hero.
func _open_where_hero_is() -> void:
	var wm := Session.world_map
	var place := Registry.get_def("place", wm.current_place)
	if not place.is_empty() and wm.in_city(str(place.get("city", ""))):
		_view.show_level("city_district", str(place["city_district"]))
		_view.select("place", str(place["id"]))
		return
	var d := wm.district_of(wm.current_region)
	if d != "" and Registry.has_def("district", d):
		_view.show_level("district", d)
	else:
		_view.show_level("republic")
	_view.select("region", wm.current_region)


func _rebuild_crumbs() -> void:
	AfUI.clear(_crumbs)
	var parts := [["Башкортостан", func(): _view.show_level("republic"); _refresh_card()]]
	match _view.level:
		"district":
			parts.append([Registry.display_name("district", _view.focus), Callable()])
		"city", "city_district":
			var city := _view.focus if _view.level == "city" else str(Registry.get_def("city_district", _view.focus).get("city", ""))
			var region := _city_region(city)
			var dist := Session.world_map.district_of(region)
			if Registry.display_name("district", dist) != Registry.display_name("region", region):
				parts.append([Registry.display_name("district", dist), func(): _view.show_level("district", dist); _view.select("region", region)])
			parts.append([Registry.display_name("region", region), func(): _view.show_level("city", city); _refresh_card()])
			if _view.level == "city_district":
				parts.append([Registry.display_name("city_district", _view.focus), Callable()])
	for i in parts.size():
		if i > 0:
			_crumbs.add_child(AfUI.label("›", 18, AfTheme.TEXT_DIM))
		var b := AfUI.button(parts[i][0], parts[i][1])
		b.custom_minimum_size = Vector2(0, 46)
		b.disabled = i == parts.size() - 1
		_crumbs.add_child(b)


func _city_region(city: String) -> String:
	for r in Registry.all("region"):
		if str(r.get("city", "")) == city:
			return str(r["id"])
	return ""


func _refresh_card() -> void:
	_on_selected(_view.sel_kind, _view.sel_id)


func _refresh_status() -> void:
	var s := Session.player.survival
	_time_lbl.text = "День %d · %s · %s · %s" % [Clock.day(), Clock.time_text(), Clock.season_name(), Session.weather.label()]
	_vitals.text = "Здоровье %d · Сытость %d · Вода %d · Энергия %d" % [s.health, s.need("satiety"), s.need("hydration"), s.need("energy")]


func _on_selected(kind: String, id: String) -> void:
	_refresh_status()
	AfUI.clear(_card)
	match kind:
		"district": _card_district(id)
		"region": _card_region(id)
		"city_district": _card_city_district(id)
		"place": _card_place(id)
		_:
			_card.add_child(AfUI.label("Выберите район, населённый пункт или место на карте.", 16, AfTheme.TEXT_DIM, true))


func _title(text: String, sub: String) -> void:
	_card.add_child(AfUI.label(text, 24, AfTheme.ACCENT_SOFT, true))
	if sub != "":
		_card.add_child(AfUI.label(sub, 14, AfTheme.TEXT_DIM, true))


func _card_district(id: String) -> void:
	var wm := Session.world_map
	var d := Registry.get_def("district", id)
	var regs := wm.district_regions(id)
	var known := regs.filter(func(r): return wm.intel(str(r["id"])) > 0).size()
	_title(str(d["name"]), "%s · населённых пунктов на карте: %d · известно: %d" % ["Городской округ" if d["kind"] == "city" else "Муниципальный район", regs.size(), known])
	if wm.district_intel(id) >= 2:
		_card.add_child(AfUI.label("Заражённые: %s" % _density_text(wm.district_density(id)), 16, AfTheme.TEXT))
	else:
		_card.add_child(AfUI.label("Обстановка неизвестна — нужна разведка.", 15, AfTheme.TEXT_DIM, true))
	if wm.district_of(wm.current_region) == id:
		_card.add_child(AfUI.label("Вы в этом районе: %s." % Registry.display_name("region", wm.current_region), 16, AfTheme.GOOD, true))
	_card.add_child(AfUI.accent_button("Открыть карту района", func(): _view.show_level("district", id)))


func _card_region(id: String) -> void:
	var wm := Session.world_map
	var r := Registry.get_def("region", id)
	if r.is_empty():
		return
	var lvl := wm.intel(id)
	_title(str(r["name"]), "%s · %s · разведданные: %s" % [_kind(str(r["kind"])), Registry.display_name("district", str(r.get("district", ""))), AfWorldMap.INTEL_NAMES[lvl]])
	if lvl > 0 and str(r.get("description", "")) != "":
		_card.add_child(AfUI.label(str(r["description"]), 15, AfTheme.TEXT, true))
	if int(r.get("population", 0)) > 0:
		_card.add_child(AfUI.label("Население до катастрофы: %s" % _num(int(r["population"])), 14, AfTheme.TEXT_DIM))
	_card.add_child(AfUI.label("Заражённые: " + wm.density_label(id), 15, AfTheme.DANGER if wm.density(id) > 0.5 and lvl >= 2 else AfTheme.TEXT))
	var in_location := world != null and world.mode == "location"
	var city := str(r.get("city", ""))
	if id == wm.current_region:
		_card.add_child(AfUI.label("Вы здесь.", 16, AfTheme.GOOD))
		if city != "":
			_card.add_child(AfUI.accent_button("Открыть карту города", func(): _view.show_level("city", city); _on_selected("", "")))
		elif r.has("location") and Registry.has_def("location", str(r["location"])):
			_card.add_child(_action("Войти в локацию", func(): _enter_location(str(r["location"])), in_location, true))
		elif r.has("location"):
			_card.add_child(AfUI.label("Детальная локация не установлена (нужен пакет «%s»)." % str(r["location"]).get_slice(":", 0), 14, AfTheme.WARN, true))
		_base_actions("", id, in_location)
		_card.add_child(_action("Обыскать окрестности (3 ч)", _do_search, in_location))
		_card.add_child(_action("Отдохнуть (сон 8 ч)", _do_rest, in_location))
	else:
		var km := wm.road_km(wm.current_region, id)
		if km > 0.0:
			_card.add_child(AfUI.label("Дорога: %.0f км, пешком ~%.0f ч" % [km, wm.travel_hours(id)], 15, AfTheme.TEXT))
			_card.add_child(_action("Отправиться", _do_travel.bind(id), in_location, true))
		else:
			_card.add_child(AfUI.label("Нет прямой дороги из текущего пункта. Двигайтесь через соседние (пунктир на карте района).", 14, AfTheme.TEXT_DIM, true))
		if city != "":
			_card.add_child(AfUI.button("Посмотреть карту города", func(): _view.show_level("city", city); _on_selected("", "")))
	if in_location:
		_card.add_child(AfUI.label("Чтобы путешествовать, выйдите из локации через выход.", 13, AfTheme.TEXT_DIM, true))


func _card_city_district(id: String) -> void:
	var cd := Registry.get_def("city_district", id)
	var places := Registry.all("place").filter(func(p): return str(p.get("city_district", "")) == id)
	_title(str(cd["name"]), "Район города · значимых мест: %d" % places.size())
	var types := {}
	for p in places:
		types[AfLocationGenerator.type_name(str(p["type"]))] = true
	_card.add_child(AfUI.label(", ".join(PackedStringArray(types.keys())), 14, AfTheme.TEXT_DIM, true))
	_card.add_child(AfUI.accent_button("Открыть район", func(): _view.show_level("city_district", id); _on_selected("", "")))


func _card_place(id: String) -> void:
	var wm := Session.world_map
	var p := Registry.get_def("place", id)
	_title(str(p["name"]), "%s · %s" % [AfLocationGenerator.type_name(str(p["type"])), Registry.display_name("city_district", str(p["city_district"]))])
	var in_location := world != null and world.mode == "location"
	if not wm.in_city(str(p["city"])):
		_card.add_child(AfUI.label("Сначала доберитесь до города.", 15, AfTheme.TEXT_DIM, true))
		return
	var loc_id := ""
	if p.has("location"):
		loc_id = RegistryHelpers.full_id_for(str(p["location"]), str(p.get("_package", "core")), "location")
	else:
		loc_id = AfLocationGenerator.PREFIX + id
	var st: Dictionary = Session.locations.locations.get(loc_id, {})
	if not st.is_empty():
		var searched := 0
		for c in st.get("containers", {}).values():
			searched += 1 if c["searched"] else 0
		_card.add_child(AfUI.label("Вы здесь бывали. Обыскано точек: %d." % searched, 14, AfTheme.TEXT_DIM))
	if id == wm.current_place:
		_card.add_child(AfUI.label("Вы здесь.", 16, AfTheme.GOOD))
		_card.add_child(_action("Войти", func(): _enter_place(id), in_location, true))
		_base_actions(id, wm.current_region, in_location)
	else:
		var minutes := wm.walk_minutes(id)
		_card.add_child(AfUI.label("Путь пешком: ~%d мин (%s)" % [int(minutes), "от въезда в город" if wm.current_place == "" else "от «%s»" % Registry.display_name("place", wm.current_place)], 15, AfTheme.TEXT, true))
		_card.add_child(_action("Идти сюда", _do_walk.bind(id), in_location, true))
	if in_location:
		_card.add_child(AfUI.label("Сначала выйдите из текущей локации через выход.", 13, AfTheme.TEXT_DIM, true))


## Base: found it here, or open it when you're at it.
func _base_actions(place: String, region: String, in_location: bool) -> void:
	var b := Session.base
	if b.exists and b.place_id == place and b.region_id == region:
		_card.add_child(AfUI.label("Здесь ваше убежище.", 16, AfTheme.ACCENT_SOFT))
		_card.add_child(AfUI.button("Открыть убежище", func(): get_parent().add_child(AfBasePanel.new())))
	elif not b.exists:
		var city := str(Registry.get_def("region", region).get("city", ""))
		if place == "" and city != "":
			return  # in a city the base is founded at a concrete place
		_card.add_child(_action("Основать убежище здесь", func():
			AfDialog.show_in(get_parent(), "Основать убежище?", "Здесь будет ваш дом: склад, постройки, люди. Перенести его потом будет непросто.",
				[["Отмена", Callable()], ["Основать", func():
					b.found(place, region)
					_refresh_card()
					_view.queue_redraw()]]), false))


func _action(text: String, cb: Callable, blocked: bool, accent: bool = false) -> Button:
	var b := AfUI.accent_button(text, cb) if accent else AfUI.button(text, cb)
	b.disabled = blocked
	return b


# --- actions -------------------------------------------------------------------------

func _enter_location(loc: String) -> void:
	close()
	world.enter_location(loc)


func _enter_place(id: String) -> void:
	var loc := AfLocationGenerator.ensure_for_place(id)
	if loc == "":
		AfDialog.show_in(get_parent(), "Недоступно", "Для этого места нет локации.")
		return
	close()
	world.enter_location(loc)


func _do_walk(id: String) -> void:
	var lines := Session.world_map.walk_to_place(id)
	_after_action("Путь по городу", lines)
	_view.queue_redraw()
	_view.select("place", id)


func _do_travel(id: String) -> void:
	var lines := Session.world_map.travel(id)
	_after_action("Путь", lines)
	var d := Session.world_map.district_of(Session.world_map.current_region)
	if d != _view.focus and Registry.has_def("district", d):
		_view.show_level("district", d)
	_view.select("region", Session.world_map.current_region)


func _do_search() -> void:
	_after_action("Обыск окрестностей", Session.world_map.search_area())
	Session.events.maybe_meet("search")


func _do_rest() -> void:
	var s := Session.player.survival
	var lines := PackedStringArray()
	s.sleeping = true
	var dens := Session.world_map.density(Session.world_map.current_region)
	var slept := 0
	for h in 8:
		Scheduler.fast_forward(60.0, 30.0)
		slept += 1
		if randf() < dens * 0.06:
			lines.append("Вас разбудил шум снаружи после %d ч сна." % slept)
			break
	s.sleeping = false
	lines.insert(0, "Сон: %d ч. Энергия %d." % [slept, s.need("energy")])
	_after_action("Отдых", lines)


func _after_action(title_text: String, lines: PackedStringArray) -> void:
	_refresh_card()
	_view.queue_redraw()
	if Session.player.survival.dead:
		EventBus.player_died.emit(Session.player.survival.death_cause)
		return
	AfDialog.show_in(get_parent(), title_text, "", [["Продолжить", Callable()]], Array(lines))


static func _density_text(d: float) -> String:
	if d > 0.75:
		return "очень высокая плотность"
	if d > 0.5:
		return "высокая плотность"
	if d > 0.25:
		return "умеренная плотность"
	return "низкая плотность"


static func _kind(k: String) -> String:
	return {"city": "Город", "town": "Город", "village": "Село", "industrial": "Промзона", "military": "Военный объект",
		"lab": "Научный объект", "infrastructure": "Инфраструктура", "nature": "Природа"}.get(k, k)


static func _num(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = " " + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
