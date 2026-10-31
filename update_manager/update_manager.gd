extends Node
## Content update manager and download queue.
##
## Server layout (produced by tools/afpkg.py build):
##   <mirror>/catalog.json
##   <mirror>/packages/<id>/<version>/manifest.json
##   <mirror>/packages/<id>/<version>/files/<relative path>
##   <mirror>/packages/<id>/<version>/<id>-<version>.zip   (for manual import)
##
## Updates are file-differential: only files whose sha256 differs from the
## installed version are downloaded; unchanged files are copied locally.
## The queue lives in system.db, so it survives app restarts; partial files
## are resumed with HTTP Range requests. Mirrors are tried in order and
## rotated on failure with exponential backoff.

signal catalog_updated
signal queue_changed
signal job_finished(job: String, ok: bool, message: String)

const MAX_ATTEMPTS := 6

var catalog: Array = []          # entries from the server, annotated with local state
var catalog_error := ""
var last_check_unix := 0
var checking := false
var paused_all := false
var blocked_reason := ""

var _http: HTTPRequest
var _active := {}         # download row id -> AfHttpDownload
var _retry_at := {}       # row id -> unix time
var _mirror_index := 0
var _speed_bps := {}      # job -> smoothed bytes/sec
var _job_bytes_tick := {} # job -> bytes this second
var _tick_accum := 0.0
var _persist_accum := 0.0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	if SystemDB.available:
		SystemDB.db.exec("UPDATE downloads SET state = 'queued' WHERE state = 'active'")
	if bool(Settings.get_value("content/auto_check_updates")) and DisplayServer.get_name() != "headless":
		check_updates.call_deferred()


func servers() -> PackedStringArray:
	var override := str(Settings.get_value("content/server_override")).strip_edges()
	if override != "":
		return PackedStringArray(override.split(",", false))
	var cfg: Variant = AfFs.read_json("res://config/update_servers.json")
	var channel := str(Settings.get_value("content/channel"))
	if typeof(cfg) == TYPE_DICTIONARY and cfg.get("channels", {}).has(channel):
		return PackedStringArray(cfg["channels"][channel])
	return PackedStringArray()


func _mirror(offset: int = 0) -> String:
	var list := servers()
	if list.is_empty():
		return ""
	return list[(_mirror_index + offset) % list.size()].trim_suffix("/")


# --- catalog -------------------------------------------------------------------

func check_updates() -> bool:
	if checking:
		return false
	checking = true
	catalog_error = ""
	var list := servers()
	var data: Variant = null
	for attempt in list.size():
		var base := _mirror(attempt)
		var got: Variant = await _fetch_json(base + "/catalog.json")
		if typeof(got) == TYPE_DICTIONARY and typeof(got.get("packages")) == TYPE_ARRAY:
			_mirror_index = (_mirror_index + attempt) % maxi(1, list.size())
			data = got
			break
	checking = false
	if data == null:
		catalog_error = "серверы обновлений недоступны" if not list.is_empty() else "не настроен сервер обновлений"
		catalog_updated.emit()
		return false
	last_check_unix = int(Time.get_unix_time_from_system())
	catalog = []
	for entry in data["packages"]:
		if typeof(entry) != TYPE_DICTIONARY or not entry.has("id") or not entry.has("version"):
			continue
		var e: Dictionary = entry.duplicate()
		var have := Packages.installed_version(str(e["id"]))
		e["installed_version"] = have
		if have == "":
			e["state"] = "available"
		elif AfVersion.compare(str(e["version"]), have) > 0:
			e["state"] = "update"
		else:
			e["state"] = "installed"
		if e.has("min_game_version") and AfVersion.compare(AfPaths.game_version(), str(e["min_game_version"])) < 0:
			e["state"] = "incompatible"
		catalog.append(e)
	Log.i("updates", "catalog: %d packages from %s" % [catalog.size(), _mirror()])
	catalog_updated.emit()
	return true


func updates_available() -> Array:
	return catalog.filter(func(e): return e["state"] == "update")


func _fetch_json(url: String) -> Variant:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	if _http.request(url) != OK:
		return null
	var result: Array = await _http.request_completed
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		Log.w("updates", "GET %s failed (result %d, http %d)" % [url, result[0], result[1]])
		return null
	return JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())


# --- queue -------------------------------------------------------------------

## Fetches the package manifest, computes the file diff and enqueues downloads.
## Returns {ok, error, bytes, files}.
func enqueue(entry: Dictionary, priority: int = 0) -> Dictionary:
	if not SystemDB.available:
		return {"ok": false, "error": "системная БД недоступна"}
	var id := str(entry["id"])
	var version := str(entry["version"])
	var job := "%s@%s" % [id, version]
	if not SystemDB.db.select("SELECT job FROM download_jobs WHERE job = ?", [job]).is_empty():
		return {"ok": false, "error": "уже в очереди"}
	var rel_manifest := str(entry.get("manifest", "packages/%s/%s/manifest.json" % [id, version]))
	var manifest: Variant = null
	for attempt in servers().size():
		manifest = await _fetch_json(_mirror(attempt) + "/" + rel_manifest)
		if typeof(manifest) == TYPE_DICTIONARY:
			break
	if typeof(manifest) != TYPE_DICTIONARY:
		return {"ok": false, "error": "не удалось получить манифест"}
	var errors := AfManifest.validate(manifest, true)
	errors.append_array(AfManifest.check_compat(manifest))
	if str(manifest.get("id")) != id or str(manifest.get("version")) != version:
		errors.append("манифест не соответствует каталогу")
	if not errors.is_empty():
		return {"ok": false, "error": "; ".join(errors)}
	var base_path := str(entry.get("files_base", rel_manifest.get_base_dir() + "/files"))
	var have := Packages.file_index(id)
	var need_bytes := 0
	var rows := []
	for f in manifest["files"]:
		var rel := str(f["path"])
		var sha := str(f["sha256"]).to_lower()
		if have.has(rel) and str(have[rel]["sha256"]) == sha:
			continue # unchanged - reuse local copy
		need_bytes += int(f.get("size", 0))
		rows.append([job, id, version, rel, base_path + "/" + rel,
			AfPaths.DOWNLOADS_DIR.path_join(id).path_join(version).path_join(rel), sha, int(f.get("size", 0))])
	var free := AfFs.space_left("user://")
	var needed := need_bytes + int(manifest.get("size", need_bytes)) # download + staging copy
	if free >= 0 and free < needed + 50 * 1024 * 1024:
		return {"ok": false, "error": "недостаточно места: нужно %s, свободно %s" % [AfFs.human_size(needed), AfFs.human_size(free)]}
	var db := SystemDB.db
	db.begin()
	db.exec("INSERT INTO download_jobs (job, package_id, version, manifest_json, priority, state, created_at) VALUES (?, ?, ?, ?, ?, 'queued', ?)",
		[job, id, version, JSON.stringify(manifest), priority, int(Time.get_unix_time_from_system())])
	for r in rows:
		db.exec("INSERT INTO downloads (job, package_id, version, rel_path, url_path, dest, sha256, size, priority, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			r + [priority, int(Time.get_unix_time_from_system())])
	db.commit()
	Log.i("updates", "queued %s: %d of %d files, %s" % [job, rows.size(), manifest["files"].size(), AfFs.human_size(need_bytes)])
	queue_changed.emit()
	return {"ok": true, "error": "", "bytes": need_bytes, "files": rows.size()}


func jobs() -> Array:
	if not SystemDB.available:
		return []
	var out := []
	for j in SystemDB.db.select("SELECT job, package_id, version, priority, state FROM download_jobs ORDER BY priority DESC, created_at"):
		var agg: Array = SystemDB.db.select("SELECT COALESCE(SUM(size),0) AS total, COALESCE(SUM(CASE WHEN state='done' THEN size ELSE downloaded END),0) AS done, COUNT(*) AS files, SUM(CASE WHEN state='done' THEN 1 ELSE 0 END) AS files_done, MAX(last_error) AS err FROM downloads WHERE job = ?", [j["job"]])
		var a: Dictionary = agg[0]
		var live := 0
		for rid in _active:
			var dl: AfHttpDownload = _active[rid]
			if dl.dest.begins_with(AfPaths.DOWNLOADS_DIR.path_join(str(j["package_id"])).path_join(str(j["version"]))):
				live += dl.bytes_done
		var done := int(a["done"]) + live
		var total := int(a["total"])
		var speed := float(_speed_bps.get(j["job"], 0.0))
		j["total"] = total
		j["done"] = mini(done, total)
		j["files"] = int(a["files"])
		j["files_done"] = int(a["files_done"]) if a["files_done"] != null else 0
		j["speed"] = speed
		j["eta"] = (total - done) / speed if speed > 1.0 else -1.0
		j["error"] = a["err"] if a["err"] != null else ""
		out.append(j)
	return out


func pause_job(job: String) -> void:
	_stop_active_for(job)
	SystemDB.db.exec("UPDATE download_jobs SET state = 'paused' WHERE job = ?", [job])
	SystemDB.db.exec("UPDATE downloads SET state = 'paused' WHERE job = ? AND state != 'done'", [job])
	queue_changed.emit()


func resume_job(job: String) -> void:
	SystemDB.db.exec("UPDATE download_jobs SET state = 'queued' WHERE job = ?", [job])
	SystemDB.db.exec("UPDATE downloads SET state = 'queued', attempts = 0, last_error = NULL WHERE job = ? AND state != 'done'", [job])
	queue_changed.emit()


func cancel_job(job: String) -> void:
	_stop_active_for(job)
	var rows := SystemDB.db.select("SELECT package_id, version FROM download_jobs WHERE job = ?", [job])
	SystemDB.db.exec("DELETE FROM downloads WHERE job = ?", [job])
	SystemDB.db.exec("DELETE FROM download_jobs WHERE job = ?", [job])
	if rows.size() > 0:
		AfFs.remove_recursive(AfPaths.DOWNLOADS_DIR.path_join(str(rows[0]["package_id"])).path_join(str(rows[0]["version"])))
	queue_changed.emit()


func set_priority(job: String, priority: int) -> void:
	SystemDB.db.exec("UPDATE download_jobs SET priority = ? WHERE job = ?", [priority, job])
	SystemDB.db.exec("UPDATE downloads SET priority = ? WHERE job = ?", [priority, job])
	queue_changed.emit()


func _stop_active_for(job: String) -> void:
	for rid in _active.keys():
		var row := SystemDB.db.select("SELECT job, downloaded FROM downloads WHERE id = ?", [rid])
		if row.size() > 0 and row[0]["job"] == job:
			var dl: AfHttpDownload = _active[rid]
			SystemDB.db.exec("UPDATE downloads SET downloaded = ? WHERE id = ?", [dl.bytes_done, rid])
			dl.cancel()
			_active.erase(rid)


# --- worker ------------------------------------------------------------------

func _process(delta: float) -> void:
	if not SystemDB.available:
		return
	_tick_accum += delta
	_persist_accum += delta
	for rid in _active.keys():
		var dl: AfHttpDownload = _active[rid]
		var got := dl.poll(delta)
		if got > 0:
			var job := _job_of(rid)
			_job_bytes_tick[job] = int(_job_bytes_tick.get(job, 0)) + got
		if dl.state == AfHttpDownload.State.DONE:
			_active.erase(rid)
			_on_file_done(rid, dl)
		elif dl.state == AfHttpDownload.State.FAILED:
			_active.erase(rid)
			_on_file_failed(rid, dl)
	if _tick_accum >= 1.0:
		for job in _job_bytes_tick:
			_speed_bps[job] = lerpf(float(_speed_bps.get(job, 0.0)), _job_bytes_tick[job] / _tick_accum, 0.5)
		_job_bytes_tick.clear()
		_tick_accum = 0.0
	if _persist_accum >= 2.0:
		_persist_accum = 0.0
		for rid in _active:
			SystemDB.db.exec("UPDATE downloads SET downloaded = ? WHERE id = ?", [_active[rid].bytes_done, rid])
	_start_more()


var _job_cache := {}


func _job_of(rid: int) -> String:
	if not _job_cache.has(rid):
		_job_cache[rid] = str(SystemDB.db.scalar("SELECT job FROM downloads WHERE id = ?", [rid], ""))
	return _job_cache[rid]


func _start_more() -> void:
	if paused_all:
		blocked_reason = "загрузки приостановлены"
		return
	var max_parallel := int(Settings.get_value("content/max_parallel_downloads"))
	if _active.size() >= max_parallel:
		return
	var queued := SystemDB.db.select("SELECT d.id, d.url_path, d.dest, d.size FROM downloads d JOIN download_jobs j ON j.job = d.job WHERE d.state = 'queued' AND j.state IN ('queued', 'active') ORDER BY d.priority DESC, d.id LIMIT 8")
	if queued.is_empty():
		blocked_reason = ""
		return
	if not AfNetworkState.downloads_allowed(bool(Settings.get_value("content/wifi_only"))):
		if AfNetworkState.connection_kind() == "unknown":
			blocked_reason = "тип сети не определён — отключите «только Wi-Fi», чтобы скачать"
		else:
			blocked_reason = "ожидание Wi-Fi (включено «только Wi-Fi»)"
		return
	blocked_reason = ""
	var now := int(Time.get_unix_time_from_system())
	for row in queued:
		if _active.size() >= max_parallel:
			break
		var rid := int(row["id"])
		if _active.has(rid) or int(_retry_at.get(rid, 0)) > now:
			continue
		var base := _mirror()
		if base == "":
			blocked_reason = "не настроен сервер обновлений"
			return
		var dl := AfHttpDownload.new()
		if dl.start(base + "/" + str(row["url_path"]), str(row["dest"]), int(row["size"])):
			_active[rid] = dl
			SystemDB.db.exec("UPDATE downloads SET state = 'active' WHERE id = ?", [rid])
			SystemDB.db.exec("UPDATE download_jobs SET state = 'active' WHERE job = (SELECT job FROM downloads WHERE id = ?)", [rid])
		else:
			_on_file_failed(rid, dl)


func _on_file_done(rid: int, dl: AfHttpDownload) -> void:
	var row: Dictionary = SystemDB.db.select("SELECT * FROM downloads WHERE id = ?", [rid])[0]
	if AfFs.sha256_file(dl.dest) != str(row["sha256"]):
		DirAccess.remove_absolute(dl.dest)
		dl.error = "контрольная сумма не совпала"
		_on_file_failed(rid, dl)
		return
	SystemDB.db.exec("UPDATE downloads SET state = 'done', downloaded = size, last_error = NULL WHERE id = ?", [rid])
	queue_changed.emit()
	_try_finish_job(str(row["job"]))


func _on_file_failed(rid: int, dl: AfHttpDownload) -> void:
	var attempts := int(SystemDB.db.scalar("SELECT attempts FROM downloads WHERE id = ?", [rid], 0)) + 1
	var state := "queued" if attempts < MAX_ATTEMPTS else "failed"
	SystemDB.db.exec("UPDATE downloads SET state = ?, attempts = ?, last_error = ?, downloaded = ? WHERE id = ?",
		[state, attempts, dl.error, dl.bytes_done, rid])
	_retry_at[rid] = int(Time.get_unix_time_from_system()) + int(pow(2.0, attempts))
	_mirror_index += 1 # next attempt goes to the next mirror
	Log.w("updates", "download %d failed (%s), attempt %d" % [rid, dl.error, attempts])
	if state == "failed":
		SystemDB.db.exec("UPDATE download_jobs SET state = 'error' WHERE job = (SELECT job FROM downloads WHERE id = ?)", [rid])
	queue_changed.emit()


func _try_finish_job(job: String) -> void:
	var remaining := int(SystemDB.db.scalar("SELECT COUNT(*) AS n FROM downloads WHERE job = ? AND state != 'done'", [job], 1))
	if remaining > 0:
		return
	var jrow: Array = SystemDB.db.select("SELECT * FROM download_jobs WHERE job = ?", [job])
	if jrow.is_empty():
		return
	var manifest: Dictionary = JSON.parse_string(str(jrow[0]["manifest_json"]))
	var res := apply_downloaded(manifest)
	if res["ok"]:
		SystemDB.db.exec("DELETE FROM downloads WHERE job = ?", [job])
		SystemDB.db.exec("DELETE FROM download_jobs WHERE job = ?", [job])
		AfFs.remove_recursive(AfPaths.DOWNLOADS_DIR.path_join(str(manifest["id"])).path_join(str(manifest["version"])))
		_speed_bps.erase(job)
		EventBus.toast("Установлено: %s %s" % [manifest.get("name", manifest["id"]), manifest["version"]], "good")
	else:
		SystemDB.db.exec("UPDATE download_jobs SET state = 'error' WHERE job = ?", [job])
		SystemDB.db.exec("UPDATE downloads SET last_error = ? WHERE job = ?", [res["error"], job])
		EventBus.toast("Ошибка установки %s: %s" % [manifest["id"], res["error"]], "danger")
	job_finished.emit(job, res["ok"], str(res.get("error", "")))
	queue_changed.emit()


## Builds a staging directory from downloaded + unchanged local files and installs it.
func apply_downloaded(manifest: Dictionary) -> Dictionary:
	var id := str(manifest["id"])
	var dl_root := AfPaths.DOWNLOADS_DIR.path_join(id).path_join(str(manifest["version"]))
	var cur_root := AfPaths.PACKAGES_DIR.path_join(id)
	var staging := AfPaths.STAGING_DIR.path_join("%s_upd_%d" % [id, Time.get_ticks_usec()])
	for f in manifest["files"]:
		var rel := str(f["path"])
		var dst := staging.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var src := dl_root.path_join(rel)
		if not FileAccess.file_exists(src):
			src = cur_root.path_join(rel)
		if DirAccess.copy_absolute(src, dst) != OK:
			AfFs.remove_recursive(staging)
			return {"ok": false, "error": "нет файла для сборки пакета: " + rel}
	var res := Packages.install_from_staging(staging, manifest, "update")
	if res["ok"]:
		Registry.reload()
	return res
