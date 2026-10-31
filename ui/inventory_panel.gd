class_name AfInventoryPanel
extends AfPanel
## Inventory: stacks with quality/condition, weight, equip/use/drop.

var _list: VBoxContainer
var _summary: Label
var _detail: VBoxContainer
var _selected := 0


func _init() -> void:
	super._init("Инвентарь")
	var row := AfUI.hbox(16)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(row)
	var left := AfUI.vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.4
	row.add_child(left)
	_summary = AfUI.label("", 17, AfTheme.TEXT_DIM)
	left.add_child(_summary)
	if Session.config.god_mode:
		left.add_child(AfUI.accent_button("Создать предмет (игра бога)", func(): get_parent().add_child(AfItemCreatorPanel.new())))
	_list = AfUI.vbox(6)
	left.add_child(AfUI.scroll(_list))
	var right := AfUI.card(16)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	_detail = AfUI.vbox(10)
	right.add_child(_detail)


func _ready() -> void:
	Session.player.inventory.changed.connect(_rebuild)
	_rebuild()


func _exit_tree() -> void:
	super._exit_tree()
	if Session.player.inventory.changed.is_connected(_rebuild):
		Session.player.inventory.changed.disconnect(_rebuild)


func _rebuild() -> void:
	var p := Session.player
	var inv := p.inventory
	_summary.text = "Вес: %.1f / %.0f кг · Предметов: %d" % [inv.total_weight(), inv.max_weight, inv.stacks.size()]
	AfUI.clear(_list)
	var sorted := inv.stacks.duplicate()
	sorted.sort_custom(func(a, b): return str(inv.def_of(a).get("category", "")) + str(a["item"]) < str(inv.def_of(b).get("category", "")) + str(b["item"]))
	for s in sorted:
		var d := inv.def_of(s)
		var name := str(d.get("name", s["item"]))
		if not s.get("available", true):
			name = "%s (недоступно: нет пакета %s)" % [s["item"], str(s["item"]).get_slice(":", 0)]
		var label := "%s%s ×%d" % ["◆ " if p.is_equipped(int(s["uid"])) else "", name, int(s["qty"])]
		var b := AfUI.button(label, _select.bind(int(s["uid"])))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if not s.get("available", true):
			b.disabled = true
		_list.add_child(b)
	if inv.find(_selected).is_empty():
		_selected = int(inv.stacks[0]["uid"]) if not inv.stacks.is_empty() else 0
	_show_detail()


func _select(uid: int) -> void:
	_selected = uid
	_show_detail()


func _show_detail() -> void:
	AfUI.clear(_detail)
	var p := Session.player
	var s := p.inventory.find(_selected)
	if s.is_empty():
		_detail.add_child(AfUI.label("Пусто", 18, AfTheme.TEXT_DIM))
		return
	var d := p.inventory.def_of(s)
	_detail.add_child(AfUI.label(str(d.get("name", s["item"])), 24, AfTheme.ACCENT_SOFT))
	_detail.add_child(AfUI.label("%s · %.2f кг · ×%d" % [_category(str(d.get("category", ""))), float(d.get("weight", 0.0)), int(s["qty"])], 16, AfTheme.TEXT_DIM))
	if d.has("description"):
		_detail.add_child(AfUI.label(str(d["description"]), 16, AfTheme.TEXT, true))
	_detail.add_child(AfUI.label("Качество", 15, AfTheme.TEXT_DIM))
	_detail.add_child(AfUI.bar(float(s["quality"]) * 100.0, AfTheme.INFO, 8))
	_detail.add_child(AfUI.label("Состояние" + (" (портится)" if d.has("spoil_hours") else ""), 15, AfTheme.TEXT_DIM))
	_detail.add_child(AfUI.bar(float(s["condition"]) * 100.0, AfTheme.GOOD if float(s["condition"]) > 0.4 else AfTheme.WARN, 8))
	if d.has("weapon"):
		var w: Dictionary = d["weapon"]
		var txt := "Урон %d · дальность %.1f м" % [int(w["damage"]) * int(w.get("pellets", 1)), float(w.get("range", 1.5))]
		if w.get("type") == "firearm":
			txt += " · магазин %d/%d · шум %d м" % [int(s.get("ammo", 0)), int(w.get("mag", 1)), int(w.get("noise", 30))]
		_detail.add_child(AfUI.label(txt, 16, AfTheme.TEXT))
	if d.has("clothing"):
		_detail.add_child(AfUI.label("Утепление +%d" % int(d["clothing"].get("insulation", 0)), 16, AfTheme.TEXT))
	var row := AfUI.hbox(8)
	_detail.add_child(row)
	if d.has("use"):
		row.add_child(AfUI.accent_button("Использовать", func():
			var msg := p.use_item(_selected)
			if msg != "":
				EventBus.toast(msg, "good")
			_rebuild(), 170))
	if d.has("weapon") or d.has("clothing"):
		row.add_child(AfUI.button("Снять" if p.is_equipped(_selected) else "Экипировать", func():
			p.equip(_selected)
			_rebuild(), 170))
	row.add_child(AfUI.button("Выбросить", func():
		p.drop(_selected)
		_rebuild(), 140))


static func _category(c: String) -> String:
	return {"food": "Еда", "drink": "Питьё", "medical": "Медицина", "weapon": "Оружие", "ammo": "Боеприпасы",
		"material": "Материалы", "clothing": "Одежда", "misc": "Разное"}.get(c, c)
