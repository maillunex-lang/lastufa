class_name AfContentPanel
extends AfPanel
## Content & mods manager: installed packages (enable/disable, load order,
## rollback, uninstall, history), online catalog, download queue (pause,
## resume, cancel, priority, speed, ETA), ZIP import and storage management.

var _tab := "installed"
var _content: VBoxContainer
var _status: Label
var _dirty := false
var _refresh_t := 0.0


func _init() -> void:
	super._init("Контент и моды", false)
	var tabs := AfUI.hbox(8)
	body.add_child(tabs)
	for spec in [["installed", "Установленные"], ["catalog", "Каталог"], ["queue", "Загрузки"], ["import", "Импорт ZIP"], ["storage", "Хранилище"]]:
		tabs.add_child(AfUI.button(spec[1], _switch.bind(spec[0]), 150))
	_status = AfUI.label("", 15, AfTheme.TEXT_DIM, true)
	body.add_child(_status)
	_content = AfUI.vbox(8)
	body.add_child(AfUI.scroll(_content))


func _ready() -> void:
	Updates.restart_required.connect(_on_restart_required)
	Packages.packages_changed.connect(_mark)
	Updates.catalog_updated.connect(_mark)
	Updates.queue_changed.connect(_mark)
	_render()


func _exit_tree() -> void:
	super._exit_tree()
	if Updates.restart_required.is_connected(_on_restart_required):
		Updates.restart_required.disconnect(_on_restart_required)
	for pair in [[Packages.packages_changed, _mark], [Updates.catalog_updated, _mark], [Updates.queue_changed, _mark]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
	if _dirty_registry:
		Registry.reload()


var _dirty_registry := false


func _on_restart_required(version: String) -> void:
	if get_tree().current_scene and get_tree().current_scene.has_method("_on_restart_required"):
		return  # the main menu shows its own dialog
	AfDialog.show_in(self, "Требуется перезапуск", "Обновление игры %s установлено и заработает после перезапуска." % version,
		[["Позже", Callable()], ["Перезапустить", Updates.restart_game]])


func _mark() -> void:
	_dirty = true


func _process(delta: float) -> void:
	_refresh_t -= delta
	if _dirty or (_tab == "queue" and _refresh_t <= 0.0):
		_dirty = false
		_refresh_t = 0.5
		_render()


func _switch(tab: String) -> void:
	_tab = tab
	if tab == "catalog" and Updates.catalog.is_empty() and not Updates.checking:
		Updates.check_updates()
	_render()


func _render() -> void:
	AfUI.clear(_content)
	var errs: Array = Registry.load_errors
	_status.text = ("Активно пакетов: %d" % Registry.active_packages.size()) + ("" if errs.is_empty() else " · проблем: %d" % errs.size())
	if Session.active and _tab in ["installed", "import"]:
		_status.text += " · изменения контента применяются после перезагрузки сохранения"
	match _tab:
		"installed": _render_installed()
		"catalog": _render_catalog()
		"queue": _render_queue()
		"import": _render_import()
		"storage": _render_storage()


func _render_installed() -> void:
	var core := Packages.core_manifest()
	_content.add_child(_pkg_card("Ядро игры (встроено в APK)", "SYSTEM · v%s" % AfPaths.game_version(), str(core.get("description", "")), []))
	var rows := Packages.installed()
	if rows.is_empty():
		_content.add_child(AfUI.label("Дополнительные пакеты не установлены. Откройте «Каталог» или «Импорт ZIP».", 16, AfTheme.TEXT_DIM, true))
	for row in rows:
		var id := str(row["id"])
		var m := Packages.get_manifest(id)
		var sub := "%s · v%s · %s · %s%s" % [AfManifest.TYPE_LABELS.get(row["type"], row["type"]), row["version"], AfFs.human_size(int(row["size_bytes"])),
			"подписан" if int(row["signed"]) == 1 else "без подписи", "" if int(row["enabled"]) == 1 else " · ОТКЛЮЧЁН"]
		var desc := str(m.get("description", ""))
		if Packages.activation_errors.has(id):
			desc = "⚠ " + str(Packages.activation_errors[id]) + "\n" + desc
		var actions := [
			["Отключить" if int(row["enabled"]) == 1 else "Включить", func(): Packages.set_enabled(id, int(row["enabled"]) != 1); _dirty_registry = true],
			["▲", func(): Packages.move_load_order(id, -1); _dirty_registry = true],
			["▼", func(): Packages.move_load_order(id, 1); _dirty_registry = true],
		]
		if not Packages.backups(id).is_empty():
			actions.append(["Откатить", func(): _report(Packages.rollback(id))])
		actions.append(["История", func(): _show_history(id)])
		actions.append(["Удалить", func(): _report(Packages.uninstall(id))])
		_content.add_child(_pkg_card(str(row["name"]), sub, desc, actions))
	if not Registry.overrides.is_empty():
		_content.add_child(AfUI.label("Переопределения контента (порядок загрузки решает, чья версия действует):", 16, AfTheme.ACCENT_SOFT))
		for o in Registry.overrides.slice(0, 30):
			_content.add_child(AfUI.label("• %s %s: %s → %s%s" % [o["kind"], o["id"], o["from"], o["by"], " (patch)" if o["patch"] else ""], 14, AfTheme.TEXT_DIM))
	if not Registry.load_errors.is_empty():
		_content.add_child(AfUI.label("Ошибки загрузки данных:", 16, AfTheme.WARN))
		for e in Registry.load_errors.slice(0, 30):
			_content.add_child(AfUI.label("• " + str(e), 14, AfTheme.WARN, true))


func _render_catalog() -> void:
	var row := AfUI.hbox(10)
	row.add_child(AfUI.button("Проверить обновления", func(): Updates.check_updates(), 260))
	var srv := Updates.servers()
	row.add_child(AfUI.label("Серверы: " + (", ".join(srv) if not srv.is_empty() else "не настроены"), 14, AfTheme.TEXT_DIM, true))
	_content.add_child(row)
	if Updates.checking:
		_content.add_child(AfUI.label("Проверка…", 16, AfTheme.TEXT_DIM))
		return
	if Updates.catalog_error != "":
		_content.add_child(AfUI.label("⚠ " + Updates.catalog_error + ". Для разработки: python3 tools/afpkg.py serve", 16, AfTheme.WARN, true))
	for e in Updates.catalog:
		var state := str(e["state"])
		var sub := "%s · v%s · %s%s" % [AfManifest.TYPE_LABELS.get(e.get("type", ""), e.get("type", "")), e["version"], AfFs.human_size(int(e.get("size", 0))),
			"" if str(e.get("installed_version", "")) == "" else " · установлена v" + str(e["installed_version"])]
		var actions := []
		match state:
			"available": actions.append(["Установить", _enqueue.bind(e)])
			"update": actions.append(["Обновить", _enqueue.bind(e)])
			"installed": sub += " · актуально"
			"incompatible": sub += " · требуется новая версия игры"
		var desc := str(e.get("description", ""))
		if str(e.get("changelog", "")) != "":
			desc += "\nИзменения: " + str(e["changelog"])
		_content.add_child(_pkg_card(str(e.get("name", e["id"])), sub, desc, actions))


func _enqueue(entry: Dictionary) -> void:
	var res: Dictionary = await Updates.enqueue(entry)
	if not res["ok"]:
		AfDialog.show_in(self, "Не удалось поставить в очередь", str(res["error"]))
	else:
		EventBus.toast("В очереди: %s (%d файлов, %s)" % [entry.get("name", entry["id"]), int(res["files"]), AfFs.human_size(int(res["bytes"]))], "info")
		_dirty_registry = true
		_switch("queue")


func _render_queue() -> void:
	var top := AfUI.hbox(10)
	top.add_child(AfUI.button("Возобновить всё" if Updates.paused_all else "Приостановить всё", func():
		Updates.paused_all = not Updates.paused_all
		_render(), 240))
	if Updates.blocked_reason != "":
		top.add_child(AfUI.label("⏸ " + Updates.blocked_reason, 15, AfTheme.WARN))
	_content.add_child(top)
	var jobs := Updates.jobs()
	if jobs.is_empty():
		_content.add_child(AfUI.label("Очередь пуста.", 16, AfTheme.TEXT_DIM))
	for j in jobs:
		var card := AfUI.card(12)
		var v := AfUI.vbox(6)
		card.add_child(v)
		var job := str(j["job"])
		v.add_child(AfUI.label("%s · %s" % [job, _state_name(str(j["state"]))], 18, AfTheme.ACCENT_SOFT))
		var pct := 100.0 * float(j["done"]) / maxf(1.0, float(j["total"]))
		v.add_child(AfUI.bar(pct, AfTheme.ACCENT, 10))
		v.add_child(AfUI.label("%s из %s · файлов %d/%d · %s/с · осталось %s · приоритет %d" % [AfFs.human_size(int(j["done"])), AfFs.human_size(int(j["total"])),
			int(j["files_done"]), int(j["files"]), AfFs.human_size(int(j["speed"])), AfUI.eta_text(float(j["eta"])), int(j["priority"])], 14, AfTheme.TEXT_DIM))
		if str(j["error"]) != "":
			v.add_child(AfUI.label("Последняя ошибка: " + str(j["error"]), 14, AfTheme.WARN, true))
		var row := AfUI.hbox(8)
		if str(j["state"]) in ["paused", "error"]:
			row.add_child(AfUI.button("Возобновить" if j["state"] == "paused" else "Повторить", func(): Updates.resume_job(job), 160))
		else:
			row.add_child(AfUI.button("Пауза", func(): Updates.pause_job(job), 120))
		row.add_child(AfUI.button("Приоритет ▲", func(): Updates.set_priority(job, int(j["priority"]) + 1), 160))
		row.add_child(AfUI.button("Отмена", func(): Updates.cancel_job(job), 120))
		v.add_child(row)
		_content.add_child(card)


func _render_import() -> void:
	_content.add_child(AfUI.label("Пакет — ZIP-архив с mod.json или manifest.json в корне (или в единственной папке). Исполняемый код (.gd, .so, .dll…) запрещён; поведение задаётся декларативными правилами scripts/*.json.", 15, AfTheme.TEXT_DIM, true))
	_content.add_child(AfUI.button("Выбрать ZIP на устройстве…", _pick_zip, 320))
	var dir := ProjectSettings.globalize_path(AfPaths.IMPORT_DIR)
	_content.add_child(AfUI.label("Или положите ZIP в папку: " + dir, 14, AfTheme.TEXT_DIM, true))
	var cands := Packages.import_candidates()
	for p in cands:
		var row := AfUI.hbox(10)
		row.add_child(AfUI.label(p.get_file(), 16))
		row.add_child(AfUI.spacer())
		row.add_child(AfUI.accent_button("Установить", func(): _install_zip(p), 180))
		_content.add_child(row)
	if cands.is_empty():
		_content.add_child(AfUI.label("В папке импорта нет архивов.", 15, AfTheme.TEXT_DIM))


func _pick_zip() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.zip ; ZIP-пакеты"])
	fd.use_native_dialog = true
	fd.file_selected.connect(func(path): _install_zip(path); fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered_ratio(0.8)


func _install_zip(path: String) -> void:
	var res := Packages.install_zip(path)
	_dirty_registry = true
	_report(res)


func _render_storage() -> void:
	var r := Packages.storage_report()
	for spec in [["Пакеты контента", "packages"], ["Резервные копии пакетов", "backups"], ["Незавершённые загрузки", "downloads"], ["Кэш", "cache"], ["Сохранения", "saves"], ["Свободно на устройстве", "free"]]:
		var row := AfUI.hbox(10)
		row.add_child(AfUI.label(spec[0], 17))
		row.add_child(AfUI.spacer())
		row.add_child(AfUI.label(AfFs.human_size(int(r[spec[1]])), 17, AfTheme.ACCENT_SOFT))
		_content.add_child(row)
	_content.add_child(AfUI.label("Кэш ассетов в памяти: %s" % AfFs.human_size(Assets.cache_bytes()), 15, AfTheme.TEXT_DIM))
	_content.add_child(AfUI.button("Очистить кэш и резервные копии", func():
		EventBus.toast("Освобождено " + AfFs.human_size(Packages.clear_cache()), "good")
		Assets.clear()
		_render(), 360))
	var row2 := AfUI.hbox(10)
	row2.add_child(AfUI.label("Загружать только через Wi-Fi", 17))
	var c := CheckButton.new()
	c.button_pressed = bool(Settings.get_value("content/wifi_only"))
	c.toggled.connect(func(on): Settings.set_value("content/wifi_only", on))
	row2.add_child(c)
	_content.add_child(row2)
	_content.add_child(AfUI.label("Установленные регионы:", 17, AfTheme.ACCENT_SOFT))
	for row in Packages.installed():
		if row["type"] == "REGION":
			_content.add_child(AfUI.label("• %s v%s · %s" % [row["name"], row["version"], AfFs.human_size(int(row["size_bytes"]))], 15))


func _show_history(id: String) -> void:
	var lines := []
	for h in Packages.history(id):
		lines.append("%s: %s %s → %s %s" % [Time.get_datetime_string_from_unix_time(int(h["at"])), h["action"], h["from_version"] if h["from_version"] else "", h["to_version"] if h["to_version"] else "", h["note"] if h["note"] else ""])
	AfDialog.show_in(self, "История: " + id, "", [], lines)


func _report(res: Dictionary) -> void:
	_dirty_registry = true
	if res.get("ok", false):
		var w: Array = Array(res.get("warnings", []))
		AfDialog.show_in(self, "Готово", "%s %s" % [res.get("id", ""), res.get("version", "")], [], w)
	else:
		AfDialog.show_in(self, "Ошибка", str(res.get("error", "")))
	_dirty = true


func _pkg_card(title_text: String, sub: String, desc: String, actions: Array) -> PanelContainer:
	var card := AfUI.card(12)
	var v := AfUI.vbox(4)
	card.add_child(v)
	v.add_child(AfUI.label(title_text, 19, AfTheme.ACCENT_SOFT))
	v.add_child(AfUI.label(sub, 14, AfTheme.TEXT_DIM))
	if desc != "":
		v.add_child(AfUI.label(desc, 15, AfTheme.TEXT, true))
	if not actions.is_empty():
		var row := AfUI.hbox(8)
		for a in actions:
			row.add_child(AfUI.button(a[0], a[1], 56 if a[0].length() <= 2 else 130))
		v.add_child(row)
	return card


static func _state_name(s: String) -> String:
	return {"queued": "в очереди", "active": "загрузка", "paused": "пауза", "error": "ошибка"}.get(s, s)
