extends RefCounted
## Integration tests for the content delivery pipeline against the real
## development server (tools/afpkg.py serve). Requires python3 with the
## `cryptography` package; skipped otherwise.

const PORT := 8799
var pid := -1
var dist := ""
var src := ""
var python := "python3"


func _ready_env(t) -> bool:
	var out := []
	if OS.execute(python, ["-c", "import cryptography"], out, true) != 0:
		print("    (skipped: python3 + cryptography not available)")
		return false
	dist = ProjectSettings.globalize_path(t.tmp_dir("dist"))
	src = ProjectSettings.globalize_path(t.tmp_dir("src"))
	AfFs.copy_recursive("res://content_src/region_sterlitamak", "user://test_tmp/src/region")
	return true


func _afpkg(args: Array) -> int:
	var out := []
	var code := OS.execute(python, [ProjectSettings.globalize_path("res://tools/afpkg.py")] + args, out, true)
	if code != 0:
		print("    afpkg failed: ", out)
	return code


func before_each(t) -> void:
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	for j in Updates.jobs():
		Updates.cancel_job(j["job"])
	Settings.set_value("content/wifi_only", false)
	Settings.set_value("content/server_override", "http://127.0.0.1:%d" % PORT)


func after_each(_t) -> void:
	if pid > 0:
		OS.kill(pid)
		pid = -1
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	Settings.set_value("content/server_override", "")
	Registry.reload()


func _start_server(t) -> void:
	OS.set_environment("AFPKG_QUIET", "1")
	pid = OS.create_process(python, [ProjectSettings.globalize_path("res://tools/afpkg.py"), "serve", "--out", dist, "--port", str(PORT), "--host", "127.0.0.1"])
	t.ok(pid > 0, "server started")
	# wait until it answers
	for i in 50:
		var c := HTTPClient.new()
		c.connect_to_host("127.0.0.1", PORT)
		var deadline := Time.get_ticks_msec() + 200
		while Time.get_ticks_msec() < deadline:
			c.poll()
			if c.get_status() == HTTPClient.STATUS_CONNECTED:
				c.close()
				return
			OS.delay_msec(10)
		c.close()
	t.ok(false, "server did not come up")


func _wait_job(t, job: String, timeout_ms: int = 20000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await t.get_tree().process_frame
		if SystemDB.db.select("SELECT job FROM download_jobs WHERE job = ?", [job]).is_empty():
			return true
		var st := str(SystemDB.db.scalar("SELECT state FROM download_jobs WHERE job = ?", [job], ""))
		if st == "error":
			return false
	return false


func test_catalog_install_and_differential_update(t) -> void:
	if not _ready_env(t):
		return
	var src_region := ProjectSettings.globalize_path("user://test_tmp/src/region")
	t.eq(_afpkg(["build", src_region, "--out", dist]), 0, "built 1.0.0")
	_start_server(t)
	t.ok(await Updates.check_updates(), "catalog fetched: %s" % Updates.catalog_error)
	var entry: Dictionary = Updates.catalog.filter(func(e): return e["id"] == "region.sterlitamak")[0]
	t.eq(entry["state"], "available", "not installed yet")
	var res: Dictionary = await Updates.enqueue(entry)
	t.ok(res["ok"], "enqueued: %s" % res.get("error"))
	t.eq(int(res["files"]), 6, "all files queued for fresh install")
	t.ok(await _wait_job(t, "region.sterlitamak@1.0.0"), "job finished")
	t.eq(Packages.installed_version("region.sterlitamak"), "1.0.0", "installed")
	t.eq(int(Packages.get_package("region.sterlitamak")["signed"]), 1, "signature verified")
	t.ok(Registry.has_def("location", "region.sterlitamak:sterlitamak_soda"), "registry reloaded with new location")
	t.eq(str(Registry.get_def("region", "core:sterlitamak").get("location")), "region.sterlitamak:sterlitamak_soda", "patch linked map node")
	# --- 1.1.0 changes a single file
	var mpath := src_region.path_join("manifest.json")
	var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(mpath))
	m["version"] = "1.1.0"
	AfFs.write_json_atomic(mpath, m)
	var lpath := src_region.path_join("data/loot.json")
	AfFs.write_text_atomic(lpath, FileAccess.get_file_as_string(lpath).replace("\"weight\": 4}", "\"weight\": 6}"))
	t.eq(_afpkg(["build", src_region, "--out", dist]), 0, "built 1.1.0")
	await Updates.check_updates()
	entry = Updates.catalog.filter(func(e): return e["id"] == "region.sterlitamak")[0]
	t.eq(entry["state"], "update", "update detected")
	res = await Updates.enqueue(entry)
	t.ok(res["ok"], "update enqueued")
	t.eq(int(res["files"]), 1, "only the changed file is downloaded")
	t.ok(await _wait_job(t, "region.sterlitamak@1.1.0"), "update job finished")
	t.eq(Packages.installed_version("region.sterlitamak"), "1.1.0", "updated")
	t.eq(Packages.backups("region.sterlitamak").size(), 1, "previous version backed up")
	t.ok(Packages.rollback("region.sterlitamak")["ok"], "rollback works after network update")
	t.eq(Packages.installed_version("region.sterlitamak"), "1.0.0", "rolled back")


func test_mirror_fallback_and_resume(t) -> void:
	if not _ready_env(t):
		return
	t.eq(_afpkg(["build", ProjectSettings.globalize_path("user://test_tmp/src/region"), "--out", dist]), 0, "built")
	_start_server(t)
	Settings.set_value("content/server_override", "http://127.0.0.1:1,http://127.0.0.1:%d" % PORT)
	t.ok(await Updates.check_updates(), "dead mirror skipped")
	# resumable download: pre-seed half the file as .part
	var rel := "packages/region.sterlitamak/1.0.0/files/data/location.json"
	var full := FileAccess.get_file_as_bytes(dist.path_join(rel))
	var dest := "user://test_tmp/resume/location.json"
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var half := full.slice(0, full.size() / 2)
	var f := FileAccess.open(dest + ".part", FileAccess.WRITE)
	f.store_buffer(half)
	f.close()
	var dl := AfHttpDownload.new()
	t.ok(dl.start("http://127.0.0.1:%d/%s" % [PORT, rel], dest, full.size()), "download started")
	t.eq(dl.bytes_done, half.size(), "resumes from partial size")
	var deadline := Time.get_ticks_msec() + 5000
	while dl.state != AfHttpDownload.State.DONE and dl.state != AfHttpDownload.State.FAILED and Time.get_ticks_msec() < deadline:
		dl.poll(0.016)
		OS.delay_msec(2)
	t.eq(dl.state, AfHttpDownload.State.DONE, "finished: %s" % dl.error)
	t.eq(FileAccess.get_file_as_bytes(dest), full, "resumed file is byte-identical")
	# 404 fails cleanly
	var bad := AfHttpDownload.new()
	bad.start("http://127.0.0.1:%d/nope.bin" % PORT, "user://test_tmp/resume/nope.bin")
	deadline = Time.get_ticks_msec() + 3000
	while bad.state != AfHttpDownload.State.FAILED and bad.state != AfHttpDownload.State.DONE and Time.get_ticks_msec() < deadline:
		bad.poll(0.016)
		OS.delay_msec(2)
	t.eq(bad.state, AfHttpDownload.State.FAILED, "404 reported")


func test_corrupted_download_is_rejected(t) -> void:
	if not _ready_env(t):
		return
	t.eq(_afpkg(["build", ProjectSettings.globalize_path("user://test_tmp/src/region"), "--out", dist]), 0, "built")
	# tamper with a published file after the manifest was signed
	var p := dist.path_join("packages/region.sterlitamak/1.0.0/files/data/loot.json")
	var txt := FileAccess.get_file_as_string(p)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(txt.replace("soda_lab", "soda_lap"))
	f.close()
	_start_server(t)
	await Updates.check_updates()
	var entry: Dictionary = Updates.catalog.filter(func(e): return e["id"] == "region.sterlitamak")[0]
	await Updates.enqueue(entry)
	var ok: bool = await _wait_job(t, "region.sterlitamak@1.0.0", 6000)
	t.ok(not ok, "job does not complete with a corrupted file")
	t.eq(Packages.installed_version("region.sterlitamak"), "", "nothing installed")
	var err := str(SystemDB.db.scalar("SELECT last_error FROM downloads WHERE rel_path = 'data/loot.json'", [], ""))
	t.ok(err.contains("контрольная сумма"), "checksum error recorded: %s" % err)
