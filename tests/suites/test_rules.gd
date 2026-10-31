extends RefCounted


func before_each(_t) -> void:
	Session.new_game()


func after_each(_t) -> void:
	Session.end_session()
	for row in Packages.installed():
		Packages.uninstall(str(row["id"]), true)
	Registry.reload()


func test_core_rules_fire_once(t) -> void:
	var n0 := Session.journal.entries.size()
	EventBus.zombie_killed.emit("core:walker", Vector3.ZERO)
	EventBus.zombie_killed.emit("core:walker", Vector3.ZERO)
	var story := Session.journal.entries.slice(n0).filter(func(e): return e["text"].begins_with("Первый."))
	t.eq(story.size(), 1, "first-kill rule fired exactly once")
	t.eq(Session.player.kills, 2, "kills counted")


func test_day_rule_reveals_region(t) -> void:
	t.ok(Session.world_map.intel("core:irmel_object") < 2, "not scouted at start")
	Clock.advance(1440.0 * 3)
	t.eq(Session.world_map.intel("core:irmel_object"), 2, "radio intercept pinpointed the object")


func test_mod_rules_sandbox(t) -> void:
	var dir: String = t.tmp_dir("rules")
	var files := {"scripts/rules.json": TestPkg.data_file("rule", [
		{"id": "gift", "on": "item_used", "if": [{"field": "item", "op": "==", "value": "core:crackers"}], "actions": [
			{"type": "give_item", "item": "core:honey", "qty": 999},
			{"type": "set_flag", "flag": "ate_crackers", "value": true}]},
		{"id": "flagged", "on": "item_used", "if": [{"field": "flag:ate_crackers", "op": "==", "value": true}], "once": true, "actions": [
			{"type": "notify", "text": "Флаг работает"}]},
		{"id": "evil", "on": "item_used", "actions": [{"type": "os_execute", "cmd": "rm -rf /"}]},
		{"id": "bad_event", "on": "frame", "actions": []}
	])}
	TestPkg.zip(t, dir.path_join("r.zip"), TestPkg.manifest("rules.mod", "1.0.0", "MOD", files), files)
	t.ok(Packages.install_zip(dir.path_join("r.zip"))["ok"], "installed")
	Registry.reload()
	Session.rules.validate_all()
	var bad_ids := Session.rules.rejected.map(func(r): return r[0])
	t.ok(bad_ids.has("rules.mod:evil") and bad_ids.has("rules.mod:bad_event"), "invalid rules rejected: %s" % str(bad_ids))
	var honey0 := Session.player.inventory.count("honey")
	Session.player.inventory.max_weight = 1000.0
	for s in Session.player.inventory.stacks:
		if s["item"] == "core:crackers":
			Session.player.use_item(int(s["uid"]))
			break
	t.eq(Session.player.inventory.count("honey") - honey0, AfRuleEngine.MAX_GIVE_QTY, "give_item clamped")
	t.eq(Session.rules.flags.get("ate_crackers"), true, "flag set")
	t.ok(Session.rules.fired_once.has("rules.mod:flagged"), "flag condition rule fired")


func test_compare_ops(t) -> void:
	t.ok(AfRuleEngine._compare(5, ">", 3), ">")
	t.ok(AfRuleEngine._compare("a", "in", ["a", "b"]), "in")
	t.ok(not AfRuleEngine._compare(null, "exists", null), "exists")
	t.ok(AfRuleEngine._compare(2.0, "==", 2), "num eq")
