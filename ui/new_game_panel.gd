class_name AfNewGamePanel
extends AfPanel
## New game setup: difficulty preset and which survival needs are simulated.

signal start_requested(params: Dictionary)

var _difficulty := "normal"
var _hunger := true
var _thirst := true
var _diff_buttons := {}
var _desc: Label


func _init() -> void:
	super._init("Новая игра", false)
	var v := AfUI.vbox(12)
	body.add_child(AfUI.scroll(v))
	v.add_child(AfUI.label("Сложность", 20, AfTheme.ACCENT_SOFT))
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 10)
	row.add_theme_constant_override("v_separation", 10)
	v.add_child(row)
	for key in AfGameConfig.PRESETS:
		var b := AfUI.button(str(AfGameConfig.PRESETS[key]["label"]), _pick.bind(key), 200)
		b.toggle_mode = true
		_diff_buttons[key] = b
		row.add_child(b)
	_desc = AfUI.label("", 16, AfTheme.TEXT, true)
	v.add_child(_desc)
	v.add_child(AfUI.label("Потребности", 20, AfTheme.ACCENT_SOFT))
	v.add_child(_toggle("Голод — нужно искать и есть еду", true, func(on): _hunger = on))
	v.add_child(_toggle("Жажда — нужно искать и пить воду", true, func(on): _thirst = on))
	v.add_child(AfUI.label("Отключённая потребность всегда заполнена и не влияет на здоровье. Сон, температура тела, травмы и инфекция остаются. Параметры сохраняются вместе с игрой и не меняются после начала.", 14, AfTheme.TEXT_DIM, true))
	var bottom := AfUI.hbox(10)
	bottom.add_child(AfUI.spacer())
	bottom.add_child(AfUI.accent_button("Начать игру", func():
		start_requested.emit({"difficulty": _difficulty, "hunger": _hunger, "thirst": _thirst})
		close(), 260))
	body.add_child(bottom)
	_pick("normal")


func _toggle(text: String, value: bool, cb: Callable) -> HBoxContainer:
	var r := AfUI.hbox(12)
	r.add_child(AfUI.label(text, 18, AfTheme.TEXT, true))
	var c := CheckButton.new()
	c.button_pressed = value
	c.custom_minimum_size = Vector2(80, AfTheme.MIN_TOUCH)
	c.toggled.connect(cb)
	r.add_child(c)
	return r


func _pick(key: String) -> void:
	_difficulty = key
	for k in _diff_buttons:
		_diff_buttons[k].set_pressed_no_signal(k == key)
	var p: Dictionary = AfGameConfig.PRESETS[key]
	_desc.text = "%s\nЗаражённых: ×%.1f · их урон: ×%.1f · расход еды и воды: ×%.2f · припасы: ×%.2f · шанс заразиться: ×%.1f" % [
		p["desc"], p["zombie_count"], p["zombie_damage"], p["need_rate"], p["loot"], p["infection"]]
