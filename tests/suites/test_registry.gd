extends RefCounted


func after_each(_t) -> void:
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	Registry.reload()


func test_core_content_loaded(t) -> void:
	Registry.reload()
	t.eq(Registry.load_errors.size(), 0, "no load errors: %s" % str(Registry.load_errors))
	t.ok(Registry.all("item").size() >= 25, "items")
	t.ok(Registry.all("zombie").size() >= 4, "zombies")
	t.ok(Registry.all("region").size() >= 20, "regions")
	t.ok(Registry.has_def("location", "ufa_chernikovka"), "start location")
	t.eq(Registry.resolve("item", "crowbar"), "core:crowbar", "short id resolves to core")
	t.eq(Registry.origin("item", "crowbar"), "core", "origin")
	# referential integrity of core data
	for lt in Registry.all("loot_table"):
		for e in lt["entries"]:
			t.ok(Registry.has_def("item", str(e["item"])), "loot %s -> %s" % [lt["id"], e["item"]])
	for road in Registry.all("road"):
		for n in road.get("nodes", []):
			t.ok(Registry.has_def("region", str(n)), "road %s -> %s" % [road["id"], n])
	for r in Registry.all("region"):
		if r.has("location"):
			t.ok(Registry.has_def("location", str(r["location"])), "region location")
		t.ok(Registry.has_def("loot_table", str(r.get("loot_table", ""))), "region loot table %s" % r["id"])


func test_mod_override_and_patch(t) -> void:
	var dir: String = t.tmp_dir("reg")
	var files := {
		"data/override.json": TestPkg.data_file("item", [
			{"id": "core:crowbar", "name": "Лом усиленный", "category": "weapon", "weight": 2.0, "weapon": {"type": "melee", "damage": 40, "range": 2.0}},
			{"id": "core:honey", "patch": true, "value": 99, "use": {"health": 10}},
			{"id": "broken"}
		])}
	TestPkg.zip(t, dir.path_join("ov.zip"), TestPkg.manifest("override.mod", "1.0.0", "MOD", files), files)
	t.ok(Packages.install_zip(dir.path_join("ov.zip"))["ok"], "installed")
	Registry.reload()
	t.eq(Registry.display_name("item", "crowbar"), "Лом усиленный", "override replaced def")
	var honey := Registry.get_def("item", "honey")
	t.eq(int(honey["value"]), 99, "patch changed value")
	t.eq(float(honey["use"]["health"]), 10.0, "patch deep-merged")
	t.eq(float(honey["use"]["hunger"]), 18.0, "patch kept other fields")
	t.ok(Registry.overrides.size() >= 2, "overrides reported")
	t.ok(Registry.load_errors.size() >= 1, "invalid def reported, not crashed")
