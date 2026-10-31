extends RefCounted


func before_each(_t) -> void:
	for s in Saves.SLOTS:
		Saves.delete_slot(s)
	Session.new_game()


func after_each(_t) -> void:
	Session.end_session()
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	Registry.reload()


func test_roundtrip(t) -> void:
	var p := Session.player
	p.inventory.add("makarov", 1, 0.7, 0.6)
	p.survival.add_injury("fracture", 0.5, "left_leg")
	p.survival.needs["satiety"] = 33.0
	p.position = Vector3(3, 0, -4)
	p.has_position = true
	Session.world_map.set_intel("core:sibay", 2)
	Session.journal.add("test", "запись для проверки")
	Session.locations.container("core:ufa_chernikovka", "garage_7")["searched"] = true
	Session.rules.flags["met_ayrat"] = true
	Clock.advance(500.0)
	var minutes := Clock.total_minutes
	t.ok(Saves.save("slot_1"), "saved")
	t.ok(FileAccess.file_exists("user://saves/slot_1/world.db"), "db file exists")
	t.ok(not FileAccess.file_exists("user://saves/slot_1/world.db-wal"), "no WAL leftovers")
	Session.new_game() # wipe state
	var rep := Saves.load_slot("slot_1", false)
	t.ok(rep["ok"], "loaded: %s" % rep["error"])
	p = Session.player
	t.near(Clock.total_minutes, minutes, 0.01, "clock")
	t.eq(p.inventory.count("makarov"), 1, "inventory")
	t.eq(p.survival.injuries.size(), 1, "injury")
	t.near(p.survival.need("satiety"), 33.0, 0.01, "need")
	t.eq(p.position, Vector3(3, 0, -4), "position")
	t.eq(Session.world_map.intel("core:sibay"), 2, "intel")
	t.ok(Session.journal.entries.any(func(e): return e["text"] == "запись для проверки"), "journal")
	t.ok(Session.locations.container("core:ufa_chernikovka", "garage_7")["searched"], "container state")
	t.eq(Session.rules.flags.get("met_ayrat"), true, "rule flags")
	var info := Saves.slot_info("slot_1")
	t.eq(int(info["day"]), Clock.day(), "meta day")
	t.eq(str(info["sha256"]).length(), 64, "meta sha")


func test_corruption_falls_back_to_backup(t) -> void:
	Session.player.inventory.add("honey", 1)
	t.ok(Saves.save("slot_2"), "first save")
	Session.player.inventory.add("honey", 1)
	t.ok(Saves.save("slot_2"), "second save")
	var f := FileAccess.open("user://saves/slot_2/world.db", FileAccess.READ_WRITE)
	f.seek(200)
	f.store_buffer(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	f.close()
	var rep := Saves.load_slot("slot_2", false)
	t.ok(rep["ok"], "loaded from backup: %s" % rep["error"])
	t.ok(rep["used_backup"], "backup used")
	t.eq(Session.player.inventory.count("honey"), 1, "backup state (one honey)")


func test_backups_rotate(t) -> void:
	for i in 6:
		Saves.save("slot_3")
	var files := Array(DirAccess.get_files_at("user://saves/slot_3/backups")).filter(func(x): return x.ends_with(".db"))
	t.eq(files.size(), Saves.KEEP_BACKUPS, "backups capped")


func test_migration_from_v1(t) -> void:
	t.ok(Saves.save("slot_4"), "saved")
	# Rewrite the save as format 1: journal without the category column.
	var path := "user://saves/slot_4/world.db"
	var db := AfDatabase.new()
	db.open(path)
	db.exec("CREATE TABLE journal_old (id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, text TEXT)")
	db.exec("INSERT INTO journal_old (t, text) SELECT t, text FROM journal")
	db.exec("DROP TABLE journal")
	db.exec("ALTER TABLE journal_old RENAME TO journal")
	db.exec("UPDATE meta SET value = '1' WHERE key = 'format_version'")
	db.close()
	var meta := Saves.slot_info("slot_4")
	meta["sha256"] = AfFs.sha256_file(path)
	AfFs.write_json_atomic("user://saves/slot_4/meta.json", meta)
	var rep := Saves.load_slot("slot_4", false)
	t.ok(rep["ok"], "v1 save loads: %s" % rep["error"])
	t.eq(rep["migrated_from"], 1, "migrated from 1")
	t.ok(Session.journal.entries.size() > 0 and Session.journal.entries[0]["category"] == "misc", "migrated column default")


func test_missing_package_content_preserved(t) -> void:
	var dir: String = t.tmp_dir("savepkg")
	var files := {"data/items.json": TestPkg.data_file("item", [{"id": "relic", "name": "Реликвия", "category": "misc", "weight": 0.1}])}
	TestPkg.zip(t, dir.path_join("relic.zip"), TestPkg.manifest("relic.mod", "1.0.0", "MOD", files), files)
	t.ok(Packages.install_zip(dir.path_join("relic.zip"))["ok"], "mod installed")
	Registry.reload()
	Session.new_game()
	Session.player.inventory.add("relic.mod:relic", 2)
	Saves.save("slot_5")
	Packages.uninstall("relic.mod")
	Registry.reload()
	var rep := Saves.load_slot("slot_5", false)
	t.ok(rep["ok"], "loads without the mod")
	t.eq(rep["missing_packages"], ["relic.mod 1.0.0"], "missing package reported")
	var st: Array = Session.player.inventory.stacks.filter(func(s): return s["item"] == "relic.mod:relic")
	t.ok(st.size() >= 1, "stacks kept")
	t.ok(st.all(func(x): return not x["available"]), "marked unavailable")
	Saves.save("slot_5")
	TestPkg.zip(t, dir.path_join("relic.zip"), TestPkg.manifest("relic.mod", "1.0.0", "MOD", files), files)
	Packages.install_zip(dir.path_join("relic.zip"))
	Registry.reload()
	Saves.load_slot("slot_5", false)
	t.eq(Session.player.inventory.count("relic.mod:relic"), 2, "content returns after reinstall")


func test_offline_progress_is_limited_and_protected(t) -> void:
	Session.player.survival.needs["hydration"] = 30.0
	Saves.save("autosave")
	var info := Saves.slot_info("autosave")
	var d0 := Clock.total_minutes
	var res := Session.apply_offline_progress(3.0 * 24.0 * 3600.0) # 3 real days
	t.near(float(res["minutes"]), 1440.0, 0.01, "capped at 24 game hours")
	t.near(Clock.total_minutes - d0, 1440.0, 0.01, "clock advanced")
	t.ok(not Session.player.survival.dead, "hero protected")
	t.ok(Session.player.survival.need("hydration") >= 25.0, "need floor respected")
	t.ok(Session.journal.since(d0).size() >= 1, "report entries")
	t.ok(info.has("saved_unix"), "save timestamp")


func test_crash_marker(t) -> void:
	t.ok(FileAccess.file_exists(AfPaths.SESSION_LOCK), "lock exists during session")
	Session.end_session()
	t.ok(not FileAccess.file_exists(AfPaths.SESSION_LOCK), "lock removed on clean end")


func test_game_config_saved_and_applied(t) -> void:
	Session.new_game({"difficulty": "hard", "hunger": false, "thirst": true})
	t.eq(Session.config.difficulty, "hard", "difficulty set")
	Session.player.survival.needs["satiety"] = 50.0
	Scheduler.fast_forward(24.0 * 60.0, 60.0)
	var s := Session.player.survival
	t.eq(s.need("satiety"), 100.0, "hunger disabled: satiety stays full")
	t.ok(s.need("hydration") < 50.0, "thirst still active")
	t.ok(Saves.save("slot_3"), "saved")
	Session.new_game()
	t.eq(Session.config.difficulty, "normal", "new game defaults")
	t.ok(Saves.load_slot("slot_3", false)["ok"], "loaded")
	t.eq(Session.config.difficulty, "hard", "difficulty restored")
	t.ok(not Session.config.hunger_enabled and Session.config.thirst_enabled, "needs settings restored")
	t.ok(str(Saves.slot_info("slot_3").get("difficulty", "")).contains("без голода"), "slot list shows settings")


func test_old_save_without_config_is_normal(t) -> void:
	Session.new_game({"difficulty": "nightmare"})
	Saves.save("slot_4")
	var path := "user://saves/slot_4/world.db"
	var db := AfDatabase.new()
	db.open(path)
	db.exec("DROP TABLE game_config")
	db.close()
	var meta := Saves.slot_info("slot_4")
	meta["sha256"] = AfFs.sha256_file(path)
	AfFs.write_json_atomic("user://saves/slot_4/meta.json", meta)
	t.ok(Saves.load_slot("slot_4", false)["ok"], "old save loads")
	t.eq(Session.config.difficulty, "normal", "defaults to normal")
	t.ok(Session.config.hunger_enabled and Session.config.thirst_enabled, "all needs on")
