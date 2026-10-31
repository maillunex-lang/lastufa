class_name AfCharacterPanel
extends AfPanel
## Hero state: vitals, injuries with treatment, symptoms, journal.

var _content: VBoxContainer


func _init() -> void:
	super._init("Персонаж")
	var tabs := AfUI.hbox(8)
	body.add_child(tabs)
	tabs.add_child(AfUI.button("Состояние", _show_state, 160))
	tabs.add_child(AfUI.button("Журнал", _show_journal, 160))
	_content = AfUI.vbox(8)
	body.add_child(AfUI.scroll(_content))


func _ready() -> void:
	_show_state()


func _show_state() -> void:
	AfUI.clear(_content)
	var p := Session.player
	var s := p.survival
	_content.add_child(AfUI.label("%s · убито заражённых: %d" % [p.name, p.kills], 22, AfTheme.ACCENT_SOFT))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 6)
	_content.add_child(grid)
	var rows := [["Здоровье", s.health, AfTheme.DANGER], ["Сытость", s.need("satiety"), Color("c9a050")], ["Вода", s.need("hydration"), AfTheme.INFO],
		["Энергия", s.need("energy"), Color("9f8fd0")], ["Гигиена", s.need("hygiene"), Color("8fb0a0")], ["Стресс", s.stress, Color("b06a8a")],
		["Боль", s.pain(), AfTheme.WARN]]
	for r in rows:
		var l := AfUI.label("%s  %d" % [r[0], int(r[1])], 17)
		l.custom_minimum_size = Vector2(170, 0)
		grid.add_child(l)
		var b := AfUI.bar(float(r[1]), r[2], 10)
		b.custom_minimum_size = Vector2(320, 10)
		grid.add_child(b)
	_content.add_child(AfUI.label("Температура тела: %.1f °C · воздух %s · утепление +%d" % [s.body_temp, Session.weather.label(), int(p.insulation())], 16, AfTheme.TEXT_DIM))
	_content.add_child(AfUI.label("Травмы", 20, AfTheme.ACCENT_SOFT))
	if s.injuries.is_empty():
		_content.add_child(AfUI.label("Нет", 16, AfTheme.TEXT_DIM))
	for inj in s.injuries:
		var row := AfUI.hbox(10)
		row.add_child(AfUI.label("%s — %s, тяжесть %d%%%s" % [AfSurvival.INJURY_NAMES.get(inj["type"], inj["type"]), _limb(str(inj["limb"])),
			int(float(inj["severity"]) * 100), " · обработано" if inj["treated"] else ""], 16))
		row.add_child(AfUI.spacer())
		var cure := _cure_item(str(inj["type"]))
		if not inj["treated"] and cure != "":
			var b := AfUI.button("Лечить: " + Registry.display_name("item", cure), _treat.bind(cure), 220)
			b.disabled = p.inventory.count(cure) <= 0
			row.add_child(b)
		_content.add_child(row)
	var sym := s.symptoms()
	if not sym.is_empty():
		_content.add_child(AfUI.label("Симптомы", 20, AfTheme.ACCENT_SOFT))
		for x in sym:
			_content.add_child(AfUI.label("• " + x, 16, AfTheme.WARN))
	var fit := s.move_multiplier()
	if fit < 0.99:
		_content.add_child(AfUI.label("Подвижность снижена до %d%%" % int(fit * 100), 16, AfTheme.WARN))


func _treat(item_id: String) -> void:
	var p := Session.player
	for st in p.inventory.stacks:
		if st["item"] == Registry.resolve("item", item_id):
			EventBus.toast(p.use_item(int(st["uid"])), "good")
			break
	_show_state()


static func _cure_item(type: String) -> String:
	for d in Registry.all("item"):
		if type in d.get("use", {}).get("cures", []):
			return str(d["id"])
	return ""


static func _limb(l: String) -> String:
	return {"left_arm": "левая рука", "right_arm": "правая рука", "torso": "торс", "left_leg": "левая нога", "right_leg": "правая нога"}.get(l, l)


func _show_journal() -> void:
	AfUI.clear(_content)
	var entries := Session.journal.entries.duplicate()
	entries.reverse()
	for e in entries.slice(0, 120):
		var t := float(e["t"])
		var day := int(floor(t / 1440.0)) + 1
		var hh := int(fmod(t, 1440.0) / 60.0)
		var mm := int(fmod(t, 60.0))
		var card := AfUI.card(10)
		var v := AfUI.vbox(2)
		card.add_child(v)
		v.add_child(AfUI.label("День %d, %02d:%02d · %s" % [day, hh, mm, e["category"]], 13, AfTheme.TEXT_DIM))
		v.add_child(AfUI.label(str(e["text"]), 16, AfTheme.TEXT, true))
		_content.add_child(card)
