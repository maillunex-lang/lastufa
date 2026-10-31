extends RefCounted

var dir := ""


func before_each(t) -> void:
	dir = t.tmp_dir("pkg")
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	Packages.clear_cache()


func after_each(_t) -> void:
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	Registry.reload()


func _items(name: String) -> Dictionary:
	return {"data/items.json": TestPkg.data_file("item", [{"id": "flask", "name": name, "category": "drink", "weight": 0.5}])}


func test_path_guard(t) -> void:
	t.eq(AfManifest.check_path("data/items.json"), "", "normal path ok")
	t.eq(AfManifest.check_path("assets/models/car.glb"), "", "asset ok")
	t.ok(AfManifest.check_path("../evil.json") != "", "parent traversal rejected")
	t.ok(AfManifest.check_path("data/../../x.json") != "", "nested traversal rejected")
	t.ok(AfManifest.check_path("/etc/passwd") != "", "absolute rejected")
	t.ok(AfManifest.check_path("C:/x.json") != "", "drive rejected")
	t.ok(AfManifest.check_path("data\\x.json") != "", "backslash rejected")
	t.ok(AfManifest.check_path("scripts/hack.gd") != "", "gdscript rejected")
	t.ok(AfManifest.check_path("assets/lib.so") != "", "native lib rejected")
	t.ok(AfManifest.check_path("random.txt") != "", "unknown root file rejected")
	t.ok(AfManifest.check_path("data/x.exe") != "", "exe rejected")


func test_manifest_validation(t) -> void:
	var m := TestPkg.manifest("test.mod", "1.0.0", "MOD", _items("Фляга"))
	t.eq(AfManifest.validate(m, true).size(), 0, "valid manifest")
	var bad := m.duplicate(true)
	bad["id"] = "Bad Id!"
	bad["type"] = "VIRUS"
	bad["version"] = "x"
	t.ok(AfManifest.validate(bad, true).size() >= 3, "three errors")
	var future := m.duplicate(true)
	future["min_game_version"] = "99.0.0"
	t.ok(AfManifest.check_compat(future).size() == 1, "future game version rejected")
	var api := m.duplicate(true)
	api["api_version"] = 99
	t.ok(AfManifest.check_compat(api).size() == 1, "future api rejected")
	var sys := m.duplicate(true)
	sys["systems"] = {"survival": ">=2.0.0"}
	t.ok(AfManifest.check_compat(sys).size() == 1, "system version constraint enforced")


func test_install_mod_zip_without_checksums(t) -> void:
	var zip_path := dir.path_join("handmade.zip")
	var files := _items("Фляга")
	t.make_zip(zip_path, {"handmade_mod/mod.json": JSON.stringify({"id": "handmade.mod", "name": "Самодельный", "type": "MOD", "version": "0.1.0"}),
		"handmade_mod/data/items.json": files["data/items.json"]})
	var res := Packages.install_zip(zip_path)
	t.ok(res["ok"], "installed: %s" % res.get("error"))
	t.ok(Array(res["warnings"]).size() > 0, "warned about missing checksums")
	t.eq(Packages.installed_version("handmade.mod"), "0.1.0", "version recorded")
	Registry.reload()
	t.eq(Registry.display_name("item", "handmade.mod:flask"), "Фляга", "content loaded")


func test_reject_zip_slip_and_code(t) -> void:
	var p1 := dir.path_join("slip.zip")
	t.make_zip(p1, {"mod.json": JSON.stringify({"id": "slip.mod", "name": "x", "type": "MOD", "version": "1.0.0"}), "../../evil.json": "{}"})
	t.ok(not Packages.install_zip(p1)["ok"], "zip slip rejected")
	var p2 := dir.path_join("code.zip")
	t.make_zip(p2, {"mod.json": JSON.stringify({"id": "code.mod", "name": "x", "type": "MOD", "version": "1.0.0"}), "scripts/run.gd": "extends Node"})
	t.ok(not Packages.install_zip(p2)["ok"], "gdscript payload rejected")
	t.eq(Packages.installed_version("code.mod"), "", "nothing installed")
	t.eq(AfFs.list_files_recursive(AfPaths.STAGING_DIR).size(), 0, "staging cleaned")


func test_checksum_mismatch_keeps_previous_version(t) -> void:
	var f1 := _items("Фляга v1")
	var m1 := TestPkg.manifest("flask.pack", "1.0.0", "ASSET", f1)
	TestPkg.zip(t, dir.path_join("v1.zip"), m1, f1)
	t.ok(Packages.install_zip(dir.path_join("v1.zip"))["ok"], "v1 installed")
	var f2 := _items("Фляга v2")
	var m2 := TestPkg.manifest("flask.pack", "1.1.0", "ASSET", f2)
	m2["files"][0]["sha256"] = "0".repeat(64) # tampered
	TestPkg.zip(t, dir.path_join("v2.zip"), m2, f2)
	var res := Packages.install_zip(dir.path_join("v2.zip"))
	t.ok(not res["ok"], "tampered update rejected")
	t.eq(Packages.installed_version("flask.pack"), "1.0.0", "v1 still installed")
	Registry.reload()
	t.eq(Registry.display_name("item", "flask.pack:flask"), "Фляга v1", "v1 content intact")


func test_update_backup_and_rollback(t) -> void:
	var f1 := _items("Фляга v1")
	TestPkg.zip(t, dir.path_join("v1.zip"), TestPkg.manifest("roll.pack", "1.0.0", "ASSET", f1), f1)
	var f2 := _items("Фляга v2")
	TestPkg.zip(t, dir.path_join("v2.zip"), TestPkg.manifest("roll.pack", "2.0.0", "ASSET", f2), f2)
	t.ok(Packages.install_zip(dir.path_join("v1.zip"))["ok"], "v1")
	t.ok(Packages.install_zip(dir.path_join("v2.zip"))["ok"], "v2")
	t.eq(Packages.backups("roll.pack").size(), 1, "one backup")
	var rb := Packages.rollback("roll.pack")
	t.ok(rb["ok"], "rollback ok: %s" % rb.get("error"))
	t.eq(Packages.installed_version("roll.pack"), "1.0.0", "rolled back to v1")
	Registry.reload()
	t.eq(Registry.display_name("item", "roll.pack:flask"), "Фляга v1", "content of v1")
	var hist := Packages.history("roll.pack")
	t.ok(hist.size() >= 3, "history recorded (%d)" % hist.size())


func test_signature(t) -> void:
	var f := _items("Подписанная фляга")
	var m := TestPkg.manifest("signed.pack", "1.0.0", "REGION", f)
	TestPkg.sign(m)
	t.eq(AfManifest.verify_signature(m), "dev_ashenfall", "valid signature verified")
	TestPkg.zip(t, dir.path_join("signed.zip"), m, f)
	t.ok(Packages.install_zip(dir.path_join("signed.zip"))["ok"], "signed installed")
	t.eq(int(Packages.get_package("signed.pack")["signed"]), 1, "marked signed")
	var forged := m.duplicate(true)
	forged["version"] = "1.0.1"
	t.eq(AfManifest.verify_signature(forged), "", "modified manifest fails signature")
	TestPkg.zip(t, dir.path_join("forged.zip"), forged, f)
	t.ok(not Packages.install_zip(dir.path_join("forged.zip"))["ok"], "forged package rejected")


func test_pck_requires_signed_system_package(t) -> void:
	var f := {"data/x.pck": PackedByteArray([1, 2, 3])}
	var m := TestPkg.manifest("pck.mod", "1.0.0", "MOD", f)
	TestPkg.zip(t, dir.path_join("pck.zip"), m, f)
	t.ok(not Packages.install_zip(dir.path_join("pck.zip"))["ok"], "unsigned pck rejected")


func test_dependencies_conflicts_and_order(t) -> void:
	var fa := _items("A")
	var fb := {"data/items.json": TestPkg.data_file("item", [{"id": "b", "name": "B", "category": "misc", "weight": 1}])}
	TestPkg.zip(t, dir.path_join("b.zip"), TestPkg.manifest("dep.b", "1.0.0", "MOD", fb, {"dependencies": {"dep.a": ">=1.0.0"}}), fb)
	t.ok(Packages.install_zip(dir.path_join("b.zip"))["ok"], "b installs before its dependency (with warning)")
	var active := Packages.resolve_active().map(func(r): return r["id"])
	t.ok(not active.has("dep.b"), "b inactive without a")
	t.ok(str(Packages.activation_errors.get("dep.b", "")).contains("dep.a"), "error names missing dep")
	TestPkg.zip(t, dir.path_join("a.zip"), TestPkg.manifest("dep.a", "1.2.0", "MOD", fa), fa)
	t.ok(Packages.install_zip(dir.path_join("a.zip"))["ok"], "a installed")
	# put b first in manual order: dependency order must still win
	Packages.move_load_order("dep.a", 1)
	active = Packages.resolve_active().map(func(r): return r["id"])
	t.eq(active, ["dep.a", "dep.b"], "a loads before b")
	t.ok(not Packages.uninstall("dep.a")["ok"], "uninstall refused while b depends on a")
	var fc := {"data/items.json": TestPkg.data_file("item", [{"id": "c", "name": "C", "category": "misc", "weight": 1}])}
	TestPkg.zip(t, dir.path_join("c.zip"), TestPkg.manifest("conf.c", "1.0.0", "MOD", fc, {"conflicts": ["dep.a"]}), fc)
	Packages.install_zip(dir.path_join("c.zip"))
	active = Packages.resolve_active().map(func(r): return r["id"])
	t.ok(not active.has("conf.c"), "conflicting package not activated")
	Packages.set_enabled("dep.a", false)
	active = Packages.resolve_active().map(func(r): return r["id"])
	t.ok(active.has("conf.c") and not active.has("dep.b"), "disabling a activates c, deactivates b")


func test_storage_report(t) -> void:
	var r := Packages.storage_report()
	for k in ["packages", "backups", "downloads", "cache", "saves", "free"]:
		t.ok(r.has(k), "has " + k)
	t.ok(int(r["free"]) > 0, "free space known")


func test_bootstrap_payload_matches_manifest(t) -> void:
	var f := _items("X")
	var m := TestPkg.manifest("payload.check", "2.3.4", "SYSTEM", f, {"dependencies": {"b": ">=1", "a": "^2.0.0"}})
	t.eq(Bootstrap.signing_payload(m), AfManifest.signing_payload(m), "Bootstrap and AfManifest sign the same payload")


func test_code_pack_needs_release_key(t) -> void:
	var f := {"code/game.pck": PackedByteArray([71, 68, 80, 67])}
	var m := TestPkg.manifest("game.core", "9.0.0", "SYSTEM", f)
	TestPkg.sign(m)  # dev key
	TestPkg.zip(t, dir.path_join("code.zip"), m, f)
	var res := Packages.install_zip(dir.path_join("code.zip"))
	t.ok(not res["ok"], "dev-signed code pack rejected")
	t.ok(str(res["error"]).contains("релизным"), "reason mentions release key: %s" % res["error"])
	t.ok(FileAccess.file_exists(Bootstrap.BOOT_FILE), "boot file written")
	t.eq(Bootstrap.code_version, AfPaths.game_version(), "nothing mounted in tests")


func test_categories(t) -> void:
	t.eq(AfManifest.category_of({"type": "REGION"}), "locations", "region -> locations")
	t.eq(AfManifest.category_of({"type": "SYSTEM"}), "system", "system -> game updates")
	t.eq(AfManifest.category_of({"type": "MOD", "category": "graphics"}), "graphics", "explicit category wins")
	t.eq(AfManifest.category_of({"type": "MOD", "category": "nonsense", "files": [{"path": "data/items.json"}]}), "items", "unknown category -> inferred")
	t.eq(AfManifest.category_of({"type": "MOD", "files": [{"path": "assets/textures/a.png"}, {"path": "assets/models/b.glb"}, {"path": "data/x.json"}]}), "graphics", "mostly assets -> graphics")
	t.eq(AfManifest.category_of({"type": "MOD", "files": [{"path": "assets/sfx/a.ogg"}]}), "audio", "sounds -> audio")
	t.eq(AfManifest.category_of({"type": "MOD", "files": [{"path": "data/zombies.json"}]}), "zombies", "zombies")
	t.eq(AfManifest.category_of({"type": "MOD"}), "other", "empty -> other")
	var out := []
	OS.execute("python3", ["-c", "import sys,json; sys.path.insert(0,'%s'); import afpkg; print(afpkg.category_of({'type':'MOD','files':[{'path':'assets/a.png'},{'path':'assets/b.png'},{'path':'data/items.json'}]}))" % ProjectSettings.globalize_path("res://tools")], out, true)
	if out.size() > 0 and str(out[0]).strip_edges() != "":
		t.eq(str(out[0]).strip_edges(), "graphics", "python tool infers the same category")
