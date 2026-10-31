extends Node
## Save slots backed by one SQLite database per slot.
##
## Layout: user://saves/<slot>/world.db   - all persistent systems, one table set each
##         user://saves/<slot>/meta.json  - summary + sha256 of world.db
##         user://saves/<slot>/backups/   - rotating previous versions
##
## Saving writes a fresh world.db.tmp in a single transaction, hashes it,
## rotates the previous file into backups and renames the temp file into
## place, so a crash at any point leaves a valid save. Loading verifies the
## hash, falls back to the newest valid backup, migrates old formats, and
## reports packages that were active when saving but are missing now
## (their content stays in the save, marked unavailable).

signal slots_changed

const SLOTS := ["autosave", "quicksave", "slot_1", "slot_2", "slot_3", "slot_4", "slot_5"]
const KEEP_BACKUPS := 3

var last_load_report := {}
var _autosave_requested := false
var busy := false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT and OS.get_name() == "Android":
		# the OS may kill a backgrounded app at any time - persist now
		if Session.active and not Session.player.survival.dead:
			save("autosave", "pause")
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if Session.active and not Session.player.survival.dead:
			save("autosave", "exit")
		Session.end_session()
		get_tree().quit()


func _process(_delta: float) -> void:
	if _autosave_requested and not busy:
		_autosave_requested = false
		save("autosave", "auto")


func request_autosave() -> void:
	_autosave_requested = true


func slot_dir(slot: String) -> String:
	return AfPaths.SAVES_DIR.path_join(slot)


func slot_info(slot: String) -> Dictionary:
	var m: Variant = AfFs.read_json(slot_dir(slot).path_join("meta.json"))
	return m if typeof(m) == TYPE_DICTIONARY else {}


func list_slots() -> Array:
	var out := []
	for s in SLOTS:
		var info := slot_info(s)
		info["slot"] = s
		info["exists"] = FileAccess.file_exists(slot_dir(s).path_join("world.db"))
		out.append(info)
	return out


func latest_slot() -> String:
	var best := ""
	var best_t := -1
	for info in list_slots():
		if info["exists"] and int(info.get("saved_unix", 0)) > best_t:
			best_t = int(info.get("saved_unix", 0))
			best = info["slot"]
	return best


func has_crash_marker() -> bool:
	return FileAccess.file_exists(AfPaths.SESSION_LOCK) and not Session.active


func clear_crash_marker() -> void:
	if FileAccess.file_exists(AfPaths.SESSION_LOCK):
		DirAccess.remove_absolute(AfPaths.SESSION_LOCK)


# --- save --------------------------------------------------------------------

func save(slot: String, reason: String = "manual") -> bool:
	if not Session.active or busy:
		return false
	if not AfDatabase.is_available():
		EventBus.toast("Сохранение невозможно: SQLite недоступен", "danger")
		return false
	busy = true
	var t0 := Time.get_ticks_msec()
	var dir := slot_dir(slot)
	DirAccess.make_dir_recursive_absolute(dir.path_join("backups"))
	var tmp := dir.path_join("world.db.tmp")
	for suffix in ["", "-wal", "-shm", "-journal"]:
		if FileAccess.file_exists(tmp + suffix):
			DirAccess.remove_absolute(tmp + suffix)
	var db := AfDatabase.new()
	var ok := db.open(tmp)
	if ok:
		db.exec("PRAGMA journal_mode = MEMORY")
		ok = db.begin()
		ok = ok and db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
		for p in Session.persistables():
			for sql in p.schema_sql():
				ok = ok and db.exec(sql)
			if ok:
				p.save_to_db(db)
		var packages := []
		for pkg in Registry.active_packages:
			packages.append({"id": pkg["id"], "version": pkg["version"]})
		var meta_rows := {
			"format_version": str(AfPaths.SAVE_FORMAT_VERSION),
			"game_version": AfPaths.game_version(),
			"saved_unix": str(int(Time.get_unix_time_from_system())),
			"packages": JSON.stringify(packages),
			"reason": reason,
		}
		for k in meta_rows:
			ok = ok and db.exec("INSERT INTO meta (key, value) VALUES (?, ?)", [k, meta_rows[k]])
		ok = ok and db.commit()
		db.close()
	if not ok:
		Log.e("saves", "save to %s failed: %s" % [slot, db.last_error])
		DirAccess.remove_absolute(tmp)
		busy = false
		EventBus.game_saved.emit(slot, false)
		EventBus.toast("Ошибка сохранения", "danger")
		return false
	var sha := AfFs.sha256_file(tmp)
	var final_db := dir.path_join("world.db")
	var old_meta := slot_info(slot)
	if FileAccess.file_exists(final_db):
		var stamp := "%015d" % int(Time.get_unix_time_from_system() * 1000.0)
		DirAccess.rename_absolute(final_db, dir.path_join("backups").path_join(stamp + ".db"))
		AfFs.write_json_atomic(dir.path_join("backups").path_join(stamp + ".json"), old_meta)
	if DirAccess.rename_absolute(tmp, final_db) != OK:
		Log.e("saves", "could not move save into place")
		busy = false
		return false
	var p := Session.player
	var meta := {
		"slot": slot,
		"format_version": AfPaths.SAVE_FORMAT_VERSION,
		"game_version": AfPaths.game_version(),
		"saved_unix": int(Time.get_unix_time_from_system()),
		"saved_text": Time.get_datetime_string_from_system(false, true),
		"sha256": sha,
		"reason": reason,
		"day": Clock.day(),
		"time": Clock.time_text(),
		"season": Clock.season_name(),
		"region": Registry.display_name("region", Session.world_map.current_region),
		"health": int(p.survival.health),
		"hero": p.name,
		"packages": Registry.active_packages.map(func(x): return {"id": x["id"], "version": x["version"]}),
	}
	AfFs.write_json_atomic(dir.path_join("meta.json"), meta)
	_prune_backups(dir.path_join("backups"))
	busy = false
	Log.i("saves", "saved %s (%s) in %d ms" % [slot, reason, Time.get_ticks_msec() - t0])
	EventBus.game_saved.emit(slot, true)
	slots_changed.emit()
	return true


func _prune_backups(bdir: String) -> void:
	var d := DirAccess.open(bdir)
	if d == null:
		return
	var dbs := Array(d.get_files()).filter(func(f): return f.ends_with(".db"))
	dbs.sort()
	while dbs.size() > KEEP_BACKUPS:
		var f: String = dbs.pop_front()
		DirAccess.remove_absolute(bdir.path_join(f))
		DirAccess.remove_absolute(bdir.path_join(f.get_basename() + ".json"))


# --- load --------------------------------------------------------------------

## Loads a slot into a new session. Returns a report dictionary:
## {ok, error, used_backup, migrated_from, missing_packages[], offline}
func load_slot(slot: String, apply_offline: bool = true) -> Dictionary:
	var report := {"ok": false, "error": "", "used_backup": false, "migrated_from": 0, "missing_packages": [], "offline": {}}
	var dir := slot_dir(slot)
	var candidates := _load_candidates(dir)
	if candidates.is_empty():
		report["error"] = "сохранение не найдено"
		return report
	var chosen := {}
	for c in candidates:
		if c["sha"] != "" and AfFs.sha256_file(c["db"]) == c["sha"]:
			chosen = c
			break
		Log.w("saves", "integrity check failed: %s" % c["db"])
	if chosen.is_empty():
		report["error"] = "все копии сохранения повреждены"
		return report
	report["used_backup"] = chosen["backup"]
	# work on a copy so migrations never damage the original
	var work := dir.path_join("load_work.db")
	if FileAccess.file_exists(work):
		DirAccess.remove_absolute(work)
	DirAccess.copy_absolute(chosen["db"], work)
	var db := AfDatabase.new()
	if not db.open(work):
		report["error"] = "не удалось открыть базу сохранения"
		return report
	var fmt := int(str(db.scalar("SELECT value FROM meta WHERE key = 'format_version'", [], "1")))
	if fmt > AfPaths.SAVE_FORMAT_VERSION:
		db.close()
		report["error"] = "сохранение создано более новой версией игры"
		return report
	if fmt < AfPaths.SAVE_FORMAT_VERSION:
		var err := AfSaveMigrations.migrate(db, fmt)
		if err != "":
			db.close()
			report["error"] = err
			return report
		report["migrated_from"] = fmt
	var pk: Variant = JSON.parse_string(str(db.scalar("SELECT value FROM meta WHERE key = 'packages'", [], "[]")))
	if typeof(pk) == TYPE_ARRAY:
		for p in pk:
			if not Registry.is_package_active(str(p["id"])):
				report["missing_packages"].append("%s %s" % [p["id"], p["version"]])
	var saved_unix := int(str(db.scalar("SELECT value FROM meta WHERE key = 'saved_unix'", [], "0")))
	Session.slot = slot
	Session.start_from_db(db)
	db.close()
	DirAccess.remove_absolute(work)
	if not report["missing_packages"].is_empty():
		EventBus.toast("Отсутствуют пакеты: %s. Их данные сохранены и вернутся после установки." % ", ".join(report["missing_packages"]), "warn")
	if apply_offline and saved_unix > 0:
		report["offline"] = Session.apply_offline_progress(Time.get_unix_time_from_system() - saved_unix)
	report["ok"] = true
	last_load_report = report
	EventBus.game_loaded.emit(slot)
	Log.i("saves", "loaded %s (backup=%s, migrated_from=%d)" % [slot, report["used_backup"], report["migrated_from"]])
	return report


func _load_candidates(dir: String) -> Array:
	var out := []
	var meta := slot_info(dir.get_file())
	if FileAccess.file_exists(dir.path_join("world.db")):
		out.append({"db": dir.path_join("world.db"), "sha": str(meta.get("sha256", "")), "backup": false})
	var bdir := dir.path_join("backups")
	var d := DirAccess.open(bdir)
	if d:
		var dbs := Array(d.get_files()).filter(func(f): return f.ends_with(".db"))
		dbs.sort()
		dbs.reverse()
		for f in dbs:
			var m: Variant = AfFs.read_json(bdir.path_join(f.get_basename() + ".json"))
			out.append({"db": bdir.path_join(f), "sha": str((m as Dictionary).get("sha256", "")) if typeof(m) == TYPE_DICTIONARY else "", "backup": true})
	return out


func delete_slot(slot: String) -> void:
	AfFs.remove_recursive(slot_dir(slot))
	slots_changed.emit()
