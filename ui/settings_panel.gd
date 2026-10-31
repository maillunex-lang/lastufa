class_name AfSettingsPanel
extends AfPanel
## Settings: performance profile, display, autosave, content delivery.


func _init() -> void:
	super._init("Настройки")
	var v := AfUI.vbox(12)
	body.add_child(AfUI.scroll(v))
	v.add_child(AfUI.label("Производительность", 20, AfTheme.ACCENT_SOFT))
	var prof := OptionButton.new()
	prof.custom_minimum_size = Vector2(320, AfTheme.MIN_TOUCH)
	var keys := ["auto", "low", "medium", "high"]
	for k in keys:
		prof.add_item("Авто (%s)" % Settings.PROFILES[Settings.detect_profile()]["label"] if k == "auto" else Settings.PROFILES[k]["label"])
	prof.select(keys.find(str(Settings.get_value("graphics/profile"))))
	prof.item_selected.connect(func(i): Settings.set_value("graphics/profile", keys[i]))
	v.add_child(_row("Профиль качества", prof))
	v.add_child(AfUI.label("Профиль задаёт число активных заражённых, частоту симуляции, тени, частицы, разрешение и лимит кадров. Изменения графики применяются сразу, состав локации — при следующем входе.", 14, AfTheme.TEXT_DIM, true))
	v.add_child(_row("Адаптивное качество (снижать при перегреве/просадках)", _check("graphics/adaptive_quality")))
	v.add_child(_row("Показывать FPS и память", _check("graphics/show_fps")))
	v.add_child(AfUI.label("Игра", 20, AfTheme.ACCENT_SOFT))
	var auto := OptionButton.new()
	auto.custom_minimum_size = Vector2(320, AfTheme.MIN_TOUCH)
	var mins := [60, 120, 240, 480]
	for m in mins:
		auto.add_item("каждые %d игровых мин" % m)
	auto.select(maxi(0, mins.find(int(Settings.get_value("game/autosave_minutes")))))
	auto.item_selected.connect(func(i): Settings.set_value("game/autosave_minutes", mins[i]))
	v.add_child(_row("Автосохранение", auto))
	v.add_child(AfUI.label("Загрузки и обновления", 20, AfTheme.ACCENT_SOFT))
	v.add_child(_row("Загружать только через Wi-Fi", _check("content/wifi_only")))
	v.add_child(_row("Проверять обновления при запуске", _check("content/auto_check_updates")))
	var server := LineEdit.new()
	server.placeholder_text = "по умолчанию из config/update_servers.json"
	server.text = str(Settings.get_value("content/server_override"))
	server.custom_minimum_size = Vector2(480, AfTheme.MIN_TOUCH)
	server.text_submitted.connect(func(t): Settings.set_value("content/server_override", t.strip_edges()))
	server.focus_exited.connect(func(): Settings.set_value("content/server_override", server.text.strip_edges()))
	v.add_child(_row("Сервер обновлений (зеркала через запятую)", server))
	v.add_child(AfUI.label("Версия игры %s · API модов v%d · формат сохранений v%d · %s" % [AfPaths.game_version(), AfPaths.MOD_API_VERSION, AfPaths.SAVE_FORMAT_VERSION, OS.get_name()], 14, AfTheme.TEXT_DIM))


func _row(text: String, ctrl: Control) -> HBoxContainer:
	var r := AfUI.hbox(12)
	var l := AfUI.label(text, 17, AfTheme.TEXT, true)
	r.add_child(l)
	r.add_child(ctrl)
	return r


func _check(key: String) -> CheckButton:
	var c := CheckButton.new()
	c.button_pressed = bool(Settings.get_value(key))
	c.custom_minimum_size = Vector2(80, AfTheme.MIN_TOUCH)
	c.toggled.connect(func(on): Settings.set_value(key, on))
	return c
