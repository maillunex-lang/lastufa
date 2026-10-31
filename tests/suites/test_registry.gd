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


func test_map_data_integrity(t) -> void:
	Registry.reload()
	t.eq(Registry.all("district").size(), 63, "54 districts + 9 city okrugs")
	t.ok(Registry.all("region").size() > 400, "settlements")
	t.eq(Registry.all("city_district").size(), 7, "Ufa city districts")
	t.ok(Registry.all("place").size() > 100, "places in Ufa")
	var bad := 0
	for r in Registry.all("region"):
		if not Registry.has_def("district", str(r.get("district", ""))):
			bad += 1
		for l in r.get("links", []):
			if not Registry.has_def("region", str(l)):
				bad += 1
	t.eq(bad, 0, "region districts and links resolve")
	for p in Registry.all("place"):
		if not Registry.has_def("city_district", str(p["city_district"])):
			bad += 1
	t.eq(bad, 0, "places reference existing city districts")
	var start := Registry.get_def("place", AfWorldMap.START_PLACE)
	t.eq(str(start.get("location", "")), "ufa_chernikovka", "start place uses the hand-made yard")
	t.eq(str(Registry.get_def("region", "ufa").get("city", "")), "ufa", "Ufa opens the city map")
	var shapes := []
	for d in Registry.all("district") + Registry.all("city_district"):
		shapes.append([d["name"], d["polygons"]])
	for b in Registry.all("border"):
		shapes.append([b["name"], [b["points"]]])
	for sh in shapes:
		var d := {"name": sh[0]}
		for ring in sh[1]:
			var pts := PackedVector2Array()
			for p in ring:
				pts.append(AfMapView.to_map(float(p[0]), float(p[1])))
			if Geometry2D.triangulate_polygon(pts).is_empty():
				bad += 1
				t.ok(false, "not drawable: %s ring of %d points" % [d["name"], pts.size()])
	t.eq(bad, 0, "all district polygons are drawable")


func test_location_generator_all_types(t) -> void:
	var seen := {}
	for p in Registry.all("place"):
		if seen.has(p["type"]) or p.has("location"):
			continue
		seen[p["type"]] = true
		var loc := AfLocationGenerator.ensure_for_place(str(p["id"]))
		var def := Registry.get_def("location", loc)
		t.ok(not def.is_empty(), "generated %s" % p["type"])
		t.ok(def["containers"].size() >= 2, "%s has loot points" % p["type"])
		for c in def["containers"]:
			t.ok(Registry.has_def("loot_table", RegistryHelpers.full_id_for(str(c["loot_table"]), "core", "loot_table")), "%s loot table %s" % [p["type"], c["loot_table"]])
		for z in def["zombie_spawns"]:
			t.ok(Registry.has_def("zombie", RegistryHelpers.full_id_for(str(z["type"]), "core", "zombie")), "%s zombie %s" % [p["type"], z["type"]])
		var again := AfLocationGenerator.generate(p)
		t.eq(again["containers"].size(), def["containers"].size(), "deterministic layout")
	t.ok(seen.size() >= 15, "templates for many place types (%d)" % seen.size())
