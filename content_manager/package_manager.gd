extends Node
## Installs, updates, rolls back, enables/disables and orders content packages
## (DLC, regions, asset packs, localizations and user mods alike).
##
## Install is atomic: files are extracted to a staging directory, verified
## (paths, checksums, signature, compatibility) and only then swapped into
## place with directory renames. The previous version is kept as a backup for
## rollback. Any failure leaves the previously installed version untouched.

signal packages_changed

const CORE_ID := "core"
const KEEP_BACKUPS := 2

## Last resolution result: id -> error text for packages that couldn't activate.
var activation_errors := {}


func _ready() -> void:
	_cleanup_staging()


func _cleanup_staging() -> void:
	# Leftovers from an interrupted install are never trusted.
	if DirAccess.dir_exists_absolute(AfPaths.STAGING_DIR):
		AfFs.remove_recursive(AfPaths.STAGING_DIR)
	DirAccess.make_dir_recursive_absolute(AfPaths.STAGING_DIR)


func core_manifest() -> Dictionary:
	var m: Variant = AfFs.read_json(AfPaths.CORE_PACKAGE_DIR.path_join("manifest.json"))
	var d: Dictionary = m if typeof(m) == TYPE_DICTIONARY else {}
	d["id"] = CORE_ID
	d["version"] = AfPaths.game_version()
	return d


# --- queries -----------------------------------------------------------------

func installed() -> Array:
	if not SystemDB.available:
		return []
	return SystemDB.db.select("SELECT id, type, name, version, enabled, load_order, install_path, size_bytes, source, signed, status, installed_at FROM packages ORDER BY load_order, id")


func get_package(id: String) -> Dictionary:
	if not SystemDB.available:
		return {}
	var rows := SystemDB.db.select("SELECT * FROM packages WHERE id = ?", [id])
	return rows[0] if rows.size() > 0 else {}


func get_manifest(id: String) -> Dictionary:
	if id == CORE_ID:
		return core_manifest()
	var row := get_package(id)
	if row.is_empty():
		return {}
	var m: Variant = JSON.parse_string(str(row["manifest_json"]))
	return m if typeof(m) == TYPE_DICTIONARY else {}


func installed_version(id: String) -> String:
	if id == CORE_ID:
		return AfPaths.game_version()
	var row := get_package(id)
	return str(row.get("version", ""))


func file_index(id: String) -> Dictionary:
	var out := {}
	for r in SystemDB.db.select("SELECT path, sha256, size FROM package_files WHERE package_id = ?", [id]):
		out[r["path"]] = r
	return out


func history(id: String = "", limit: int = 50) -> Array:
	if id == "":
		return SystemDB.db.select("SELECT * FROM package_history ORDER BY id DESC LIMIT ?", [limit])
	return SystemDB.db.select("SELECT * FROM package_history WHERE package_id = ? ORDER BY id DESC LIMIT ?", [id, limit])


func backups(id: String) -> Array:
	var root := AfPaths.BACKUPS_DIR.path_join(id)
	var out := []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	var names := dir.get_directories()
	names.sort()
	names.reverse()
	for n in names:
		var m: Variant = AfFs.read_json(root.path_join(n).path_join("manifest.json"))
		out.append({"dir": root.path_join(n), "name": n, "version": (m as Dictionary).get("version", "?") if typeof(m) == TYPE_DICTIONARY else "?"})
	return out


# --- activation / load order ---------------------------------------------------

## Returns enabled packages that can be activated, in dependency-respecting
## load order. Populates activation_errors for those that can't.
func resolve_active() -> Array:
	activation_errors.clear()
	var candidates := {}
	for row in installed():
		if int(row["enabled"]) == 1:
			candidates[row["id"]] = row
	var manifests := {}
	for id in candidates:
		manifests[id] = get_manifest(id)
	# drop packages with unmet deps / conflicts until stable
	var changed := true
	while changed:
		changed = false
		for id in candidates.keys():
			var m: Dictionary = manifests[id]
			var problem := ""
			for err in AfManifest.check_compat(m):
				problem = err
			var deps: Dictionary = m.get("dependencies", {})
			for dep in deps:
				var have := ""
				if dep == CORE_ID:
					have = AfPaths.game_version()
				elif candidates.has(dep):
					have = str(candidates[dep]["version"])
				if have == "":
					problem = "нет зависимости %s %s" % [dep, deps[dep]]
				elif not AfVersion.satisfies(have, str(deps[dep])):
					problem = "зависимость %s %s, требуется %s" % [dep, have, deps[dep]]
			for c in m.get("conflicts", []):
				if candidates.has(str(c)):
					problem = "конфликтует с %s" % c
			if problem != "":
				activation_errors[id] = problem
				candidates.erase(id)
				changed = true
	# Kahn topological sort, ties broken by (load_order, id)
	var indeg := {}
	var edges := {}
	for id in candidates:
		indeg[id] = 0
		edges[id] = []
	for id in candidates:
		for dep in manifests[id].get("dependencies", {}):
			if candidates.has(dep):
				indeg[id] += 1
				edges[dep].append(id)
	var ready := []
	for id in candidates:
		if indeg[id] == 0:
			ready.append(id)
	var order := []
	while not ready.is_empty():
		ready.sort_custom(func(a, b):
			var la := int(candidates[a]["load_order"])
			var lb := int(candidates[b]["load_order"])
			return la < lb or (la == lb and a < b))
		var id: String = ready.pop_front()
		order.append(candidates[id])
		for nxt in edges[id]:
			indeg[nxt] -= 1
			if indeg[nxt] == 0:
				ready.append(nxt)
	for id in candidates:
		if indeg[id] > 0:
			activation_errors[id] = "циклическая зависимость"
	return order


func set_enabled(id: String, enabled: bool) -> void:
	SystemDB.db.exec("UPDATE packages SET enabled = ? WHERE id = ?", [1 if enabled else 0, id])
	SystemDB.log_history(id, "enable" if enabled else "disable", "", "")
	_changed(id)


func move_load_order(id: String, delta: int) -> void:
	var rows := installed()
	var idx := -1
	for i in rows.size():
		if rows[i]["id"] == id:
			idx = i
	var j := idx + delta
	if idx < 0 or j < 0 or j >= rows.size():
		return
	var tmp: Dictionary = rows[idx]
	rows[idx] = rows[j]
	rows[j] = tmp
	SystemDB.db.begin()
	for i in rows.size():
		SystemDB.db.exec("UPDATE packages SET load_order = ? WHERE id = ?", [(i + 1) * 10, rows[i]["id"]])
	SystemDB.db.commit()
	_changed(id)


func reverse_dependents(id: String) -> PackedStringArray:
	var out := PackedStringArray()
	for row in installed():
		var m := get_manifest(row["id"])
		if m.get("dependencies", {}).has(id):
			out.append(row["id"])
	return out


# --- install -----------------------------------------------------------------

## Installs a package from a ZIP archive. Returns {ok, error, id, version, warnings}.
func install_zip(zip_path: String, source: String = "manual") -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return _fail("не удалось открыть архив")
	var entries := reader.get_files()
	var prefix := _detect_prefix(entries)
	var manifest_entry := ""
	for name in AfManifest.MANIFEST_NAMES:
		if entries.has(prefix + name):
			manifest_entry = prefix + name
			break
	if manifest_entry == "":
		reader.close()
		return _fail("в архиве нет manifest.json или mod.json")
	var parsed: Variant = JSON.parse_string(reader.read_file(manifest_entry).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		reader.close()
		return _fail("манифест повреждён")
	var manifest: Dictionary = parsed
	var errors := AfManifest.validate(manifest, str(manifest.get("type", "")) != "MOD")
	if not errors.is_empty():
		reader.close()
		return _fail("; ".join(errors))
	# every archive entry must be a safe path; build listing
	var listed := {}
	for f in manifest.get("files", []):
		listed[str(f["path"])] = f
	var staging := _new_staging(str(manifest["id"]))
	var total := 0
	var count := 0
	for entry in entries:
		if entry.ends_with("/"):
			continue
		if not entry.begins_with(prefix):
			continue
		var rel := entry.substr(prefix.length())
		if AfManifest.MANIFEST_NAMES.has(rel):
			continue
		var why := AfManifest.check_path(rel)
		if why != "":
			reader.close()
			AfFs.remove_recursive(staging)
			return _fail(why)
		if not listed.is_empty() and not listed.has(rel):
			reader.close()
			AfFs.remove_recursive(staging)
			return _fail("файл отсутствует в манифесте: " + rel)
		var data := reader.read_file(entry)
		if listed.has(rel) and data.size() != int(listed[rel].get("size", data.size())):
			reader.close()
			AfFs.remove_recursive(staging)
			return _fail("размер файла не совпадает с манифестом: " + rel)
		total += data.size()
		count += 1
		if total > AfManifest.MAX_PACKAGE_BYTES or count > AfManifest.MAX_FILES:
			reader.close()
			AfFs.remove_recursive(staging)
			return _fail("архив превышает допустимый размер")
		var dest := staging.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var fw := FileAccess.open(dest, FileAccess.WRITE)
		if fw == null:
			reader.close()
			AfFs.remove_recursive(staging)
			return _fail("ошибка записи (нет места?)")
		fw.store_buffer(data)
		fw.close()
	reader.close()
	var warnings := PackedStringArray()
	if listed.is_empty():
		# hand-made mod without checksums: compute them and mark as unverified
		var files := []
		for rel in AfFs.list_files_recursive(staging):
			files.append({"path": rel, "sha256": AfFs.sha256_file(staging.path_join(rel)), "size": AfFs.file_size(staging.path_join(rel))})
		manifest["files"] = files
		warnings.append("мод без контрольных сумм: целостность не подтверждена автором")
	var res := install_from_staging(staging, manifest, source)
	if res.get("ok", false):
		res["warnings"] = warnings + PackedStringArray(res.get("warnings", []))
	return res


## Verifies a fully populated staging directory and atomically activates it.
func install_from_staging(staging: String, manifest: Dictionary, source: String) -> Dictionary:
	var errors := AfManifest.validate(manifest, true)
	errors.append_array(AfManifest.check_compat(manifest))
	if not errors.is_empty():
		AfFs.remove_recursive(staging)
		return _fail("; ".join(errors))
	var id := str(manifest["id"])
	var version := str(manifest["version"])
	var warnings := PackedStringArray()
	# 1. checksums
	var on_disk := AfFs.list_files_recursive(staging)
	var listed := {}
	var total_size := 0
	for f in manifest["files"]:
		var rel := str(f["path"])
		listed[rel] = true
		var p := staging.path_join(rel)
		if not FileAccess.file_exists(p):
			AfFs.remove_recursive(staging)
			return _fail("отсутствует файл " + rel)
		var actual := AfFs.sha256_file(p)
		if actual != str(f["sha256"]).to_lower():
			AfFs.remove_recursive(staging)
			return _fail("контрольная сумма не совпадает: " + rel)
		total_size += AfFs.file_size(p)
	for rel in on_disk:
		if not listed.has(rel) and not AfManifest.MANIFEST_NAMES.has(rel):
			AfFs.remove_recursive(staging)
			return _fail("лишний файл, не указанный в манифесте: " + rel)
	# 2. signature / code policy
	var key_id := AfManifest.verify_signature(manifest)
	if manifest.has("signature") and key_id == "":
		AfFs.remove_recursive(staging)
		return _fail("цифровая подпись недействительна — пакет мог быть подменён")
	var has_pck := false
	for rel in listed:
		if str(rel).get_extension() == "pck":
			has_pck = true
	if has_pck and (key_id == "" or not ["ENGINE", "SYSTEM"].has(str(manifest["type"]))):
		AfFs.remove_recursive(staging)
		return _fail("ресурсные пакеты .pck разрешены только в подписанных системных обновлениях")
	if key_id == "" and str(manifest["type"]) != "MOD":
		warnings.append("пакет не подписан")
	# 3. dependencies (installation is allowed, activation will report problems)
	for dep in manifest.get("dependencies", {}):
		var have := installed_version(dep)
		if have == "":
			warnings.append("не установлена зависимость %s" % dep)
		elif not AfVersion.satisfies(have, str(manifest["dependencies"][dep])):
			warnings.append("зависимость %s %s не удовлетворяет %s" % [dep, have, manifest["dependencies"][dep]])
	# 4. disk space for the swap is already used by staging; nothing more to allocate.
	AfFs.write_json_atomic(staging.path_join("manifest.json"), manifest)
	return _commit(staging, manifest, source, key_id != "", total_size, warnings)


func _commit(staging: String, manifest: Dictionary, source: String, signed: bool, size_bytes: int, warnings: PackedStringArray) -> Dictionary:
	var id := str(manifest["id"])
	var version := str(manifest["version"])
	var final_dir := AfPaths.PACKAGES_DIR.path_join(id)
	var prev := get_package(id)
	var backup_dir := ""
	if DirAccess.dir_exists_absolute(final_dir):
		# name starts with a zero-padded timestamp so lexical order == chronological order
		var stamp := int(Time.get_unix_time_from_system() * 1000.0)
		backup_dir = AfPaths.BACKUPS_DIR.path_join(id).path_join("%015d_%s" % [stamp, str(prev.get("version", "unknown"))])
		while DirAccess.dir_exists_absolute(backup_dir):
			stamp += 1
			backup_dir = AfPaths.BACKUPS_DIR.path_join(id).path_join("%015d_%s" % [stamp, str(prev.get("version", "unknown"))])
		DirAccess.make_dir_recursive_absolute(backup_dir.get_base_dir())
		if DirAccess.rename_absolute(final_dir, backup_dir) != OK:
			AfFs.remove_recursive(staging)
			return _fail("не удалось создать резервную копию предыдущей версии")
	if DirAccess.rename_absolute(staging, final_dir) != OK:
		if backup_dir != "":
			DirAccess.rename_absolute(backup_dir, final_dir)
		AfFs.remove_recursive(staging)
		return _fail("не удалось активировать новую версию; предыдущая версия сохранена")
	var db := SystemDB.db
	db.begin()
	var ok := db.exec("""INSERT INTO packages (id, type, name, version, enabled, load_order, install_path, manifest_json, size_bytes, source, signed, status, installed_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ok', ?)
		ON CONFLICT(id) DO UPDATE SET type=excluded.type, name=excluded.name, version=excluded.version,
		install_path=excluded.install_path, manifest_json=excluded.manifest_json, size_bytes=excluded.size_bytes,
		source=excluded.source, signed=excluded.signed, status='ok', installed_at=excluded.installed_at""",
		[id, manifest["type"], manifest["name"], version, 1, int(prev.get("load_order", _next_load_order())), final_dir,
		JSON.stringify(manifest), size_bytes, source, 1 if signed else 0, int(Time.get_unix_time_from_system())])
	ok = ok and db.exec("DELETE FROM package_files WHERE package_id = ?", [id])
	for f in manifest["files"]:
		ok = ok and db.exec("INSERT INTO package_files (package_id, path, sha256, size) VALUES (?, ?, ?, ?)",
			[id, f["path"], str(f["sha256"]).to_lower(), int(f.get("size", 0))])
	if not ok:
		db.rollback()
		AfFs.remove_recursive(final_dir)
		if backup_dir != "":
			DirAccess.rename_absolute(backup_dir, final_dir)
		return _fail("ошибка базы данных при установке; предыдущая версия восстановлена")
	db.commit()
	SystemDB.log_history(id, "update" if not prev.is_empty() else "install", str(prev.get("version", "")), version, source)
	_prune_backups(id)
	Log.i("packages", "installed %s %s (%s)" % [id, version, source])
	_changed(id)
	return {"ok": true, "id": id, "version": version, "warnings": warnings, "error": ""}


## Restores the most recent backup of a package (the current version becomes a backup).
func rollback(id: String) -> Dictionary:
	var list := backups(id)
	if list.is_empty():
		return _fail("нет резервной копии для отката")
	var src: String = list[0]["dir"]
	var m: Variant = AfFs.read_json(src.path_join("manifest.json"))
	if typeof(m) != TYPE_DICTIONARY:
		return _fail("резервная копия повреждена")
	var staging := _new_staging(id)
	AfFs.remove_recursive(staging)
	if DirAccess.rename_absolute(src, staging) != OK:
		return _fail("не удалось подготовить откат")
	var res := install_from_staging(staging, m, "rollback")
	if not res["ok"]:
		Log.e("packages", "rollback of %s failed: %s" % [id, res["error"]])
	else:
		SystemDB.log_history(id, "rollback", "", str(m["version"]))
	return res


func uninstall(id: String, force: bool = false) -> Dictionary:
	var dependents := reverse_dependents(id)
	if not dependents.is_empty() and not force:
		return _fail("от пакета зависят: " + ", ".join(dependents))
	var row := get_package(id)
	if row.is_empty():
		return _fail("пакет не установлен")
	SystemDB.db.begin()
	SystemDB.db.exec("DELETE FROM package_files WHERE package_id = ?", [id])
	SystemDB.db.exec("DELETE FROM packages WHERE id = ?", [id])
	SystemDB.db.commit()
	AfFs.remove_recursive(AfPaths.PACKAGES_DIR.path_join(id))
	SystemDB.log_history(id, "uninstall", str(row["version"]), "")
	_changed(id)
	return {"ok": true, "id": id, "error": ""}


## Removes backups of all packages and download leftovers.
func clear_cache() -> int:
	var freed := AfFs.dir_size(AfPaths.BACKUPS_DIR) + AfFs.dir_size(AfPaths.CACHE_DIR)
	AfFs.remove_recursive(AfPaths.BACKUPS_DIR)
	AfFs.remove_recursive(AfPaths.CACHE_DIR)
	AfPaths.ensure_dirs()
	return freed


func storage_report() -> Dictionary:
	return {
		"packages": AfFs.dir_size(AfPaths.PACKAGES_DIR),
		"backups": AfFs.dir_size(AfPaths.BACKUPS_DIR),
		"downloads": AfFs.dir_size(AfPaths.DOWNLOADS_DIR),
		"cache": AfFs.dir_size(AfPaths.CACHE_DIR),
		"saves": AfFs.dir_size(AfPaths.SAVES_DIR),
		"free": AfFs.space_left("user://"),
	}


## Package ZIPs dropped into user://import (or the app's import folder) can be installed from the UI.
func import_candidates() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(AfPaths.IMPORT_DIR)
	if dir:
		for f in dir.get_files():
			if f.to_lower().ends_with(".zip"):
				out.append(AfPaths.IMPORT_DIR.path_join(f))
	return out


# --- helpers -----------------------------------------------------------------

func _detect_prefix(entries: PackedStringArray) -> String:
	for name in AfManifest.MANIFEST_NAMES:
		if entries.has(name):
			return ""
	for e in entries:
		var parts := e.split("/")
		if parts.size() == 2 and AfManifest.MANIFEST_NAMES.has(parts[1]):
			return parts[0] + "/"
	return ""


func _new_staging(id: String) -> String:
	var p := AfPaths.STAGING_DIR.path_join("%s_%d" % [id, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(p)
	return p


func _next_load_order() -> int:
	return int(SystemDB.db.scalar("SELECT COALESCE(MAX(load_order), 0) + 10 AS n FROM packages", [], 10))


func _prune_backups(id: String) -> void:
	var list := backups(id)
	for idx in range(KEEP_BACKUPS, list.size()):
		AfFs.remove_recursive(list[idx]["dir"])


func _changed(id: String) -> void:
	packages_changed.emit()
	EventBus.package_changed.emit(id)


func _fail(msg: String) -> Dictionary:
	Log.w("packages", msg)
	return {"ok": false, "error": msg, "warnings": PackedStringArray()}
