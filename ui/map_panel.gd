class_name AfMapPanel
extends AfPanel
## Strategic map panel. In "map mode" (hero is not inside a detailed location)
## it is the main screen and cannot be closed; actions advance game time.

var world: AfGameWorld
var strategic := false
var _view: AfMapView
var _card: VBoxContainer
var _time_lbl: Label
var _vitals: Label


func _init(p_strategic: bool = false) -> void:
	strategic = p_strategic
	super._init("Карта Башкортостана", true)
	if strategic:
		header.get_child(header.get_child_count() - 1).queue_free()
		header.add_child(AfUI.button("Персонаж", func(): get_parent().add_child(AfCharacterPanel.new()), 140))
		header.add_child(AfUI.button("Инвентарь", func(): get_parent().add_child(AfInventoryPanel.new()), 140))
		header.add_child(AfUI.button("Меню", func():
			var m := AfGameMenu.new()
			m.world = world
			get_parent().add_child(m), 120))
	var row := AfUI.hbox(14)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(row)
	_view = AfMapView.new()
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.size_flags_stretch_ratio = 1.7
	_view.region_selected.connect(_show_region)
	row.add_child(_view)
	var side := AfUI.card(16)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.custom_minimum_size = Vector2(380, 0)
	row.add_child(side)
	var sv := AfUI.vbox(10)
	side.add_child(sv)
	_time_lbl = AfUI.label("", 18, AfTheme.TEXT_DIM)
	sv.add_child(_time_lbl)
	_vitals = AfUI.label("", 15, AfTheme.TEXT_DIM, true)
	sv.add_child(_vitals)
	_card = AfUI.vbox(10)
	sv.add_child(AfUI.scroll(_card))


func _ready() -> void:
	_show_region(Session.world_map.current_region)
	_view.selected = Session.world_map.current_region


func _unhandled_input(event: InputEvent) -> void:
	if not strategic:
		super._unhandled_input(event)


func _refresh_status() -> void:
	var s := Session.player.survival
	_time_lbl.text = "День %d · %s · %s · %s" % [Clock.day(), Clock.time_text(), Clock.season_name(), Session.weather.label()]
	_vitals.text = "Здоровье %d · Сытость %d · Вода %d · Энергия %d" % [s.health, s.need("satiety"), s.need("hydration"), s.need("energy")]


func _show_region(id: String) -> void:
	_refresh_status()
	AfUI.clear(_card)
	var wm := Session.world_map
	var r := Registry.get_def("region", id)
	if r.is_empty():
		return
	var lvl := wm.intel(id)
	_card.add_child(AfUI.label(str(r["name"]), 26, AfTheme.ACCENT_SOFT))
	_card.add_child(AfUI.label("%s · разведданные: %s" % [_kind(str(r["kind"])), AfWorldMap.INTEL_NAMES[lvl]], 15, AfTheme.TEXT_DIM))
	if lvl > 0:
		_card.add_child(AfUI.label(str(r.get("description", "")), 16, AfTheme.TEXT, true))
	if int(r.get("population", 0)) > 0:
		_card.add_child(AfUI.label("Население до катастрофы: %s" % _num(int(r["population"])), 15, AfTheme.TEXT_DIM))
	_card.add_child(AfUI.label("Заражённые: " + wm.density_label(id), 16, AfTheme.DANGER if wm.density(id) > 0.5 and lvl >= 2 else AfTheme.TEXT))
	var here := id == wm.current_region
	if here:
		_card.add_child(AfUI.label("Вы здесь.", 16, AfTheme.GOOD))
		if r.has("location") and Registry.has_def("location", str(r["location"])):
			_card.add_child(AfUI.accent_button("Войти в локацию", func():
				var loc := str(r["location"])
				close()
				world.enter_location(loc)))
		elif r.has("location"):
			_card.add_child(AfUI.label("Детальная локация не установлена (нужен пакет «%s»)." % str(r["location"]).get_slice(":", 0), 15, AfTheme.WARN, true))
		_card.add_child(AfUI.button("Обыскать окрестности (3 ч)", _do_search))
		_card.add_child(AfUI.button("Отдохнуть (сон 8 ч)", _do_rest))
	else:
		var km := wm.road_km(wm.current_region, id)
		if km > 0.0:
			var hours := wm.travel_hours(id)
			_card.add_child(AfUI.label("Дорога: %.0f км, пешком ~%.0f ч" % [km, hours], 16, AfTheme.TEXT))
			_card.add_child(AfUI.accent_button("Отправиться", _do_travel.bind(id)))
		else:
			_card.add_child(AfUI.label("Нет прямой дороги из текущего района.", 15, AfTheme.TEXT_DIM, true))
	if world and world.mode == "location":
		_card.add_child(AfUI.label("Чтобы путешествовать, покиньте локацию через выход.", 14, AfTheme.TEXT_DIM, true))
		for c in _card.get_children():
			if c is Button and (c.text.begins_with("Отправиться") or c.text.begins_with("Обыскать") or c.text.begins_with("Отдохнуть") or c.text.begins_with("Войти")):
				c.disabled = true


func _do_travel(id: String) -> void:
	var lines := Session.world_map.travel(id)
	_after_action("Путь", lines)
	_view.selected = Session.world_map.current_region
	_view.queue_redraw()


func _do_search() -> void:
	_after_action("Обыск окрестностей", Session.world_map.search_area())


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
	_show_region(Session.world_map.current_region)
	if Session.player.survival.dead:
		EventBus.player_died.emit(Session.player.survival.death_cause)
		return
	AfDialog.show_in(get_parent(), title_text, "", [["Продолжить", Callable()]], Array(lines))


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
