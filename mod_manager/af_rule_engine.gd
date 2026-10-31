class_name AfRuleEngine
extends RefCounted
## Sandboxed, declarative scripting for packages and mods (mod API v1).
##
## Packages never ship executable code. Instead, files in scripts/*.json
## declare rules: { "on": <event>, "if": [conditions], "actions": [...] }.
## Only whitelisted events and actions exist; every action validates and clamps
## its parameters; firing is rate-limited. This is the "isolated script" layer.

const EVENTS := ["day_passed", "hour_passed", "zombie_killed", "item_used", "location_entered", "container_looted", "region_visited", "session_started"]
const ACTIONS := ["journal", "notify", "give_item", "add_stress", "reveal_region", "set_flag"]
const MAX_ACTIONS_PER_RULE := 8
const MAX_FIRES_PER_EVENT := 16
const MAX_GIVE_QTY := 20

var fired_once := {}   # rule id -> true
var last_fired := {}   # rule id -> game minute
var flags := {}        # flag -> value
var fires_total := 0
var rejected: Array = []  # [rule id, reason] for the mod manager UI


func clear() -> void:
	fired_once.clear()
	last_fired.clear()
	flags.clear()
	fires_total = 0
	validate_all()


func validate_all() -> void:
	rejected.clear()
	for r in Registry.all("rule"):
		var why := _validate(r)
		if why != "":
			rejected.append([r["id"], why])


func _validate(r: Dictionary) -> String:
	if not EVENTS.has(str(r.get("on", ""))):
		return "неизвестное событие %s" % r.get("on", "")
	if typeof(r.get("actions")) != TYPE_ARRAY or r["actions"].size() > MAX_ACTIONS_PER_RULE:
		return "actions: массив до %d элементов" % MAX_ACTIONS_PER_RULE
	for a in r["actions"]:
		if typeof(a) != TYPE_DICTIONARY or not ACTIONS.has(str(a.get("type", ""))):
			return "недопустимое действие %s" % (a.get("type", "?") if typeof(a) == TYPE_DICTIONARY else "?")
	if r.has("if") and typeof(r["if"]) != TYPE_ARRAY:
		return "if должен быть массивом"
	return ""


func dispatch(event: String, ctx: Dictionary) -> int:
	if not EVENTS.has(event):
		return 0
	var count := 0
	for r in Registry.all("rule"):
		if count >= MAX_FIRES_PER_EVENT:
			Log.w("rules", "rate limit reached for event %s" % event)
			break
		if str(r.get("on")) != event or _validate(r) != "":
			continue
		var id := str(r["id"])
		if bool(r.get("once", false)) and fired_once.has(id):
			continue
		var cooldown := float(r.get("cooldown_minutes", 0.0))
		if cooldown > 0.0 and last_fired.has(id) and Clock.total_minutes - float(last_fired[id]) < cooldown:
			continue
		if not _conditions_hold(r.get("if", []), ctx):
			continue
		for a in r["actions"]:
			_run_action(a, str(r.get("_package", "core")))
		fired_once[id] = true
		last_fired[id] = Clock.total_minutes
		count += 1
		fires_total += 1
	return count


func _conditions_hold(conds: Array, ctx: Dictionary) -> bool:
	for c in conds:
		if typeof(c) != TYPE_DICTIONARY:
			return false
		var field := str(c.get("field", ""))
		var actual: Variant
		if field.begins_with("flag:"):
			actual = flags.get(field.substr(5))
		elif field == "season":
			actual = Clock.season()
		elif field == "hour":
			actual = Clock.hour()
		elif field == "region":
			actual = Session.world_map.current_region
		else:
			actual = ctx.get(field)
		if not _compare(actual, str(c.get("op", "==")), c.get("value")):
			return false
	return true


static func _compare(a: Variant, op: String, b: Variant) -> bool:
	if op == "in":
		return typeof(b) == TYPE_ARRAY and (b as Array).has(a)
	if op == "exists":
		return a != null
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		var x := float(a)
		var y := float(b)
		match op:
			"==": return is_equal_approx(x, y)
			"!=": return not is_equal_approx(x, y)
			">": return x > y
			"<": return x < y
			">=": return x >= y
			"<=": return x <= y
		return false
	match op:
		"==": return str(a) == str(b)
		"!=": return str(a) != str(b)
	return false


func _run_action(a: Dictionary, pkg: String) -> void:
	match str(a["type"]):
		"journal":
			Session.journal.add(str(a.get("category", "mod")).substr(0, 16), str(a.get("text", "")).substr(0, 600))
		"notify":
			EventBus.toast(str(a.get("text", "")).substr(0, 200), str(a.get("kind", "info")) if str(a.get("kind")) in ["info", "good", "warn", "danger"] else "info")
		"give_item":
			var item := RegistryHelpers.full_id_for(str(a.get("item", "")), pkg)
			if Registry.has_def("item", item):
				Session.player.inventory.add(item, clampi(int(a.get("qty", 1)), 1, MAX_GIVE_QTY))
		"add_stress":
			var s := Session.player.survival
			s.stress = clampf(s.stress + clampf(float(a.get("amount", 0.0)), -50.0, 50.0), 0.0, 100.0)
		"reveal_region":
			var rid := RegistryHelpers.full_id_for(str(a.get("region", "")), pkg, "region")
			Session.world_map.set_intel(rid, clampi(int(a.get("level", 1)), 1, 2))
		"set_flag":
			var key := str(a.get("flag", "")).substr(0, 48)
			if key != "":
				flags[key] = a.get("value", true)


func save_key() -> String:
	return "rules"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS rule_state (key TEXT PRIMARY KEY, value TEXT)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("INSERT OR REPLACE INTO rule_state VALUES ('fired_once', ?)", [JSON.stringify(fired_once)])
	db.exec("INSERT OR REPLACE INTO rule_state VALUES ('last_fired', ?)", [JSON.stringify(last_fired)])
	db.exec("INSERT OR REPLACE INTO rule_state VALUES ('flags', ?)", [JSON.stringify(flags)])


func load_from_db(db: AfDatabase) -> void:
	clear()
	for r in db.select("SELECT * FROM rule_state"):
		var v: Variant = JSON.parse_string(str(r["value"]))
		if typeof(v) != TYPE_DICTIONARY:
			continue
		match str(r["key"]):
			"fired_once": fired_once = v
			"last_fired": last_fired = v
			"flags": flags = v
