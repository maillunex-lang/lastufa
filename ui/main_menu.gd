extends Control
## Main menu.

var _layer: Control


func _ready() -> void:
	theme = AfTheme.get_theme()
	var bg := ColorRect.new()
	bg.color = AfTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var glow := _Ember.new()
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + s, 80)
	for s in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 48)
	add_child(margin)
	var row := AfUI.hbox(40)
	margin.add_child(row)
	var left := AfUI.vbox(12)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(left)
	left.add_child(AfUI.label("ASHENFALL", 72, AfTheme.ACCENT_SOFT))
	left.add_child(AfUI.label("U F A", 34, AfTheme.ACCENT))
	left.add_child(AfUI.label("Постапокалиптический Башкортостан. Выживите, соберите людей, восстановите то, что осталось.", 18, AfTheme.TEXT_DIM, true))
	var ver := "v%s" % AfPaths.game_version()
	if Bootstrap.is_code_updated():
		ver += " (APK %s)" % Bootstrap.apk_version
	left.add_child(AfUI.label("%s · пакетов: %d · %s" % [ver, Registry.active_packages.size(), Settings.PROFILES[Settings.active_profile_name]["label"] + " профиль"], 14, AfTheme.TEXT_DIM))
	var right := AfUI.vbox(10)
	right.custom_minimum_size = Vector2(380, 0)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(right)
	var latest := Saves.latest_slot()
	if get_tree().has_meta("crash_recovery") and FileAccess.file_exists("user://saves/autosave/world.db"):
		right.add_child(AfUI.accent_button("Восстановить после сбоя", _load.bind("autosave")))
	if latest != "":
		var info := Saves.slot_info(latest)
		right.add_child(AfUI.accent_button("Продолжить · день %s" % info.get("day", "?"), _load.bind(latest)))
	right.add_child(AfUI.button("Новая игра", _new_game) if latest != "" else AfUI.accent_button("Новая игра", _new_game))
	right.add_child(AfUI.button("Загрузить", func(): _layer.add_child(AfSaveLoadPanel.new(false))))
	right.add_child(AfUI.button("Контент и моды", func(): _layer.add_child(AfContentPanel.new())))
	right.add_child(AfUI.button("Настройки", func(): _layer.add_child(AfSettingsPanel.new())))
	right.add_child(AfUI.button("Выход", func():
		get_tree().quit()))
	_layer = Control.new()
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_layer)
	Updates.restart_required.connect(_on_restart_required)
	if Updates.pending_restart_version != "":
		_on_restart_required.call_deferred(Updates.pending_restart_version)


func _exit_tree() -> void:
	if Updates.restart_required.is_connected(_on_restart_required):
		Updates.restart_required.disconnect(_on_restart_required)


func _on_restart_required(version: String) -> void:
	var text := "Обновление игры %s установлено и заработает после перезапуска." % version
	if OS.get_name() == "Android":
		text += " Игра закроется — откройте её снова."
	AfDialog.show_in(_layer, "Требуется перезапуск", text, [["Позже", Callable()], ["Перезапустить", Updates.restart_game]])


func _new_game() -> void:
	var setup := func():
		var panel := AfNewGamePanel.new()
		panel.start_requested.connect(_start_new_game)
		_layer.add_child(panel)
	if Saves.latest_slot() != "":
		AfDialog.show_in(_layer, "Новая игра", "Автосохранение будет перезаписано. Ручные слоты сохранятся.", [["Отмена", Callable()], ["Дальше", setup]])
	else:
		setup.call()


func _start_new_game(params: Dictionary) -> void:
	Saves.clear_crash_marker()
	if get_tree().has_meta("crash_recovery"):
		get_tree().remove_meta("crash_recovery")
	Session.slot = "slot_1"
	Session.new_game(params)
	Saves.save("autosave", "new_game")
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _load(slot: String) -> void:
	var rep := Saves.load_slot(slot)
	if not rep["ok"]:
		AfDialog.show_in(_layer, "Ошибка загрузки", str(rep["error"]))
		return
	Saves.clear_crash_marker()
	if get_tree().has_meta("crash_recovery"):
		get_tree().remove_meta("crash_recovery")
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		for c in _layer.get_children():
			if c is AfPanel:
				c.close()
				return


class _Ember extends Control:
	var t := 0.0

	func _process(delta: float) -> void:
		t += delta
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(size.x * 0.28, size.y * 1.05)
		for i in 6:
			var r := size.y * (0.35 + i * 0.12) + sin(t * 0.6 + i) * 6.0
			draw_circle(c, r, Color(0.85, 0.45, 0.15, 0.035))
		for i in 40:
			var x := fmod(i * 97.3 + t * (8.0 + i % 5), size.x)
			var y := size.y - fmod(i * 53.1 + t * (14.0 + i % 7) * 2.0, size.y)
			draw_circle(Vector2(x, y), 1.5 + (i % 3), Color(0.95, 0.6, 0.3, 0.25))
