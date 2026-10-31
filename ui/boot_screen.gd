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
	if await _handle_cli():
		return
	var ver := "Версия %s" % AfPaths.game_version()
	if Bootstrap.is_code_updated():
		ver += " (обновление поверх APK %s)" % Bootstrap.apk_version
	await _step("%s, профиль «%s» (%s, ядер: %d)" % [ver, Settings.PROFILES[Settings.active_profile_name]["label"], OS.get_name(), OS.get_processor_count()], true, 10)
	for sk in Bootstrap.skipped:
		await _step("Обновление %s %s не подключено: %s" % [sk["id"], sk["version"], sk["reason"]], false, 12)
	await _step("Хранилище: свободно %s" % AfFs.human_size(AfFs.space_left("user://")), AfFs.space_left("user://") > 50 * 1024 * 1024, 25)
	await _step("SQLite: %s" % ("доступен" if AfDatabase.is_available() and SystemDB.available else "НЕДОСТУПЕН — сохранения и пакеты отключены"), SystemDB.available, 40)
	var n := Packages.installed().size()
	await _step("Пакетов контента: %d, активно: %d" % [n, Registry.active_packages.size() - 1], Packages.activation_errors.is_empty(), 55)
	for e in Registry.load_errors.slice(0, 5):
		await _step(str(e), false, 60)
	var defs := 0
	for k in ["item", "zombie", "region", "location"]:
		defs += Registry.all(k).size()
	await _step("Данные: предметов %d, заражённых %d, районов %d, локаций %d" % [Registry.all("item").size(), Registry.all("zombie").size(), Registry.all("region").size(), Registry.all("location").size()], defs > 0, 70)
	var jobs := Updates.jobs().size()
	if jobs > 0:
		await _step("Незавершённых загрузок: %d — будут продолжены" % jobs, true, 75)
	if Saves.has_crash_marker():
		await _step("Прошлая сессия завершилась аварийно — доступно восстановление из автосохранения", false, 80)
		get_tree().set_meta("crash_recovery", true)
	# the code that is running now has booted successfully
	Bootstrap.mark_boot_ok()
	if bool(Settings.get_value("content/auto_check_updates")) and DisplayServer.get_name() != "headless":
		await _step("Проверка обновлений…", true, 85)
		var done := {"v": false}
		_check_async(done)
		var deadline := Time.get_ticks_msec() + 6000
		while not done["v"] and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		var upd := Updates.code_update()
		if not upd.is_empty():
			await _offer_update(upd)
			return
		await _step("Обновления: " + ("игра актуальна" if Updates.catalog_error == "" and done["v"] else "сервер недоступен, продолжаем"), true, 95)
	await _step("Готово", true, 100)
	await get_tree().create_timer(0.3).timeout
	_to_menu()


func _check_async(done: Dictionary) -> void:
	await Updates.check_updates()
	done["v"] = true


func _to_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


## Offers a newer game-code pack: download with progress, then restart.
func _offer_update(entry: Dictionary) -> void:
	var choice := {"v": ""}
	AfDialog.show_in(self, "Доступно обновление игры", "Версия %s → %s, %s.\n%s" % [AfPaths.game_version(), entry["version"], AfFs.human_size(int(entry.get("size", 0))), str(entry.get("changelog", ""))],
		[["Позже", func(): choice["v"] = "later"], ["Обновить", func(): choice["v"] = "update"]])
	while choice["v"] == "":
		await get_tree().process_frame
	if choice["v"] == "later":
		_to_menu()
		return
	var res: Dictionary = await Updates.enqueue(entry, 100)
	if not res.get("ok", false) and str(res.get("error", "")) != "уже в очереди":
		await _step("Не удалось начать загрузку: %s" % res.get("error", ""), false, 90)
		await get_tree().create_timer(2.0).timeout
		_to_menu()
		return
	var job := "%s@%s" % [entry["id"], entry["version"]]
	var status := AfUI.label("", 16, AfTheme.TEXT_DIM)
	_log.add_child(status)
	var result := {"done": false, "ok": false, "msg": ""}
	var on_finished := func(j, ok, msg):
		if j == job:
			result["done"] = true
			result["ok"] = ok
			result["msg"] = msg
	Updates.job_finished.connect(on_finished)
	while not result["done"]:
		for j in Updates.jobs():
			if j["job"] == job:
				_bar.value = 100.0 * float(j["done"]) / maxf(1.0, float(j["total"]))
				status.text = "Загрузка %s из %s · %s/с %s" % [AfFs.human_size(int(j["done"])), AfFs.human_size(int(j["total"])), AfFs.human_size(int(j["speed"])),
					("· " + Updates.blocked_reason) if Updates.blocked_reason != "" else ""]
				if str(j["state"]) == "error":
					result["done"] = true
					result["msg"] = str(j["error"])
		await get_tree().create_timer(0.25).timeout
	Updates.job_finished.disconnect(on_finished)
	if not result["ok"]:
		await _step("Обновление не установлено: %s" % result["msg"], false, 100)
		await get_tree().create_timer(2.5).timeout
		_to_menu()
		return
	var text := "Обновление %s установлено. Игра перезапустится." % entry["version"]
	if OS.get_name() == "Android":
		text = "Обновление %s установлено. Игра закроется — откройте её снова." % entry["version"]
	AfDialog.show_in(self, "Готово", text, [["Позже", _to_menu], ["Перезапустить", Updates.restart_game]])


## Command-line hooks used by tools/test_code_update.sh (user args after "--").
func _handle_cli() -> bool:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("af-import="):
			var res := Packages.install_zip(a.substr(10), "cli")
			print("AF_IMPORT ok=%s id=%s version=%s error=%s" % [res.get("ok"), res.get("id", ""), res.get("version", ""), res.get("error", "")])
			get_tree().quit(0 if res.get("ok", false) else 1)
			return true
	for a in args:
		if a.begins_with("af-server="):
			Settings.set_value("content/server_override", a.substr(10))
			Settings.set_value("content/wifi_only", false)
	if args.has("af-update"):
		# headless self-update: check the catalog, download + install a newer code pack
		var ok: bool = await Updates.check_updates()
		var upd := Updates.code_update()
		print("AF_UPDATE catalog=%s offered=%s error=%s" % [ok, upd.get("version", ""), Updates.catalog_error])
		if not upd.is_empty():
			var res: Dictionary = await Updates.enqueue(upd, 100)
			var job := "%s@%s" % [upd["id"], upd["version"]]
			var deadline := Time.get_ticks_msec() + 60000
			while res.get("ok", false) and Time.get_ticks_msec() < deadline and not SystemDB.db.select("SELECT job FROM download_jobs WHERE job = ?", [job]).is_empty():
				await get_tree().process_frame
			print("AF_UPDATE installed=%s pending_restart=%s" % [Packages.installed_version("game.core"), Updates.pending_restart_version])
		get_tree().quit()
		return true
	if args.has("af-print-versions"):
		if args.has("af-mark-ok"):
			Bootstrap.mark_boot_ok()
		print("AF_VERSIONS apk=%s code=%s mounted=%s skipped=%s probe=%s" % [Bootstrap.apk_version, AfPaths.game_version(),
			JSON.stringify(Bootstrap.mounted), JSON.stringify(Bootstrap.skipped), str(EventBus.get("build_probe"))])
		get_tree().quit()
		return true
	return false
