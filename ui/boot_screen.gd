extends Control
## Boot: verifies the platform pieces step by step (storage, SQLite, content
## packages, crash recovery) with a visible log, then opens the main menu.

var _log: VBoxContainer
var _bar: ProgressBar


func _ready() -> void:
	theme = AfTheme.get_theme()
	var bg := ColorRect.new()
	bg.color = AfTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var v := AfUI.vbox(12)
	v.custom_minimum_size = Vector2(640, 0)
	center.add_child(v)
	v.add_child(AfUI.label("ASHENFALL: UFA", 52, AfTheme.ACCENT_SOFT))
	_bar = AfUI.bar(0, AfTheme.ACCENT, 6)
	v.add_child(_bar)
	_log = AfUI.vbox(2)
	v.add_child(_log)
	_boot.call_deferred()


func _step(text: String, ok: bool, pct: float) -> void:
	_log.add_child(AfUI.label(("✓ " if ok else "⚠ ") + text, 16, AfTheme.TEXT_DIM if ok else AfTheme.WARN, true))
	_bar.value = pct
	await get_tree().process_frame


func _boot() -> void:
	await _step("Версия %s, профиль «%s» (%s, ядер: %d)" % [AfPaths.game_version(), Settings.PROFILES[Settings.active_profile_name]["label"], OS.get_name(), OS.get_processor_count()], true, 15)
	await _step("Хранилище: свободно %s" % AfFs.human_size(AfFs.space_left("user://")), AfFs.space_left("user://") > 50 * 1024 * 1024, 30)
	await _step("SQLite: %s" % ("доступен" if AfDatabase.is_available() and SystemDB.available else "НЕДОСТУПЕН — сохранения и пакеты отключены"), SystemDB.available, 45)
	var n := Packages.installed().size()
	await _step("Пакетов контента: %d, активно: %d" % [n, Registry.active_packages.size() - 1], Packages.activation_errors.is_empty(), 65)
	for e in Registry.load_errors.slice(0, 5):
		await _step(str(e), false, 70)
	var defs := 0
	for k in ["item", "zombie", "region", "location"]:
		defs += Registry.all(k).size()
	await _step("Данные: предметов %d, заражённых %d, районов %d, локаций %d" % [Registry.all("item").size(), Registry.all("zombie").size(), Registry.all("region").size(), Registry.all("location").size()], defs > 0, 85)
	var jobs := Updates.jobs().size()
	if jobs > 0:
		await _step("Незавершённых загрузок: %d — будут продолжены" % jobs, true, 90)
	if Saves.has_crash_marker():
		await _step("Прошлая сессия завершилась аварийно — доступно восстановление из автосохранения", false, 95)
		get_tree().set_meta("crash_recovery", true)
	await _step("Готово", true, 100)
	await get_tree().create_timer(0.35).timeout
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
