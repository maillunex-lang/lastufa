class_name AfPlayerState
extends RefCounted
## Persistent state of the hero: survival, inventory, equipment and position.
## The 3D controller (characters/player_controller.gd) reads/writes it.

var survival := AfSurvival.new()
var inventory := AfInventory.new()
var equipment := {"melee": 0, "firearm": 0, "body": 0}   # slot -> stack uid (0 = empty)
var name := "Тимур Галиев"
var location_id := "core:ufa_chernikovka"
var position := Vector3.ZERO
var has_position := false
var flashlight_on := false
var kills := 0


func new_game() -> void:
	survival.reset()
	inventory.clear()
	equipment = {"melee": 0, "firearm": 0, "body": 0}
	location_id = "core:ufa_chernikovka"
	has_position = false
	kills = 0
	inventory.add("crowbar", 1, 0.8, 0.85)
	inventory.add("water_bottle", 1)
	inventory.add("crackers", 2)
	inventory.add("bandage", 2)
	for s in inventory.stacks:
		if s["item"] == "core:crowbar":
			equipment["melee"] = int(s["uid"])


func equipped_def(slot: String) -> Dictionary:
	var s := inventory.find(int(equipment.get(slot, 0)))
	if s.is_empty() or not s.get("available", true):
		return {}
	return inventory.def_of(s)


func equipped_stack(slot: String) -> Dictionary:
	return inventory.find(int(equipment.get(slot, 0)))


func equip(uid: int) -> String:
	var s := inventory.find(uid)
	if s.is_empty():
		return ""
	var d := inventory.def_of(s)
	var slot := ""
	if d.has("weapon"):
		slot = "melee" if d["weapon"]["type"] == "melee" else "firearm"
	elif d.has("clothing"):
		slot = str(d["clothing"].get("slot", "body"))
	if slot == "":
		return ""
	equipment[slot] = 0 if int(equipment.get(slot, 0)) == uid else uid
	inventory.changed.emit()
	return slot


func is_equipped(uid: int) -> bool:
	return equipment.values().has(uid)


func insulation() -> float:
	var d := equipped_def("body")
	return float(d.get("clothing", {}).get("insulation", 0.0)) if not d.is_empty() else 0.0


func rain_protection() -> float:
	var d := equipped_def("body")
	return float(d.get("clothing", {}).get("rain_protection", 0.0)) if not d.is_empty() else 0.0


## Uses a consumable stack. Returns a message for the UI ("" if not usable).
func use_item(uid: int) -> String:
	var s := inventory.find(uid)
	if s.is_empty() or not s.get("available", true):
		return ""
	var d := inventory.def_of(s)
	if not d.has("use"):
		return ""
	var use: Dictionary = d["use"].duplicate()
	# spoiled food is less nutritious and may make you sick
	var cond := float(s["condition"])
	if d.has("spoil_hours") and cond < 0.25:
		for k in ["hunger", "thirst"]:
			if use.has(k):
				use[k] = float(use[k]) * 0.5
		use["sickness_chance"] = maxf(float(use.get("sickness_chance", 0.0)), 0.6 - cond)
	var msg := survival.apply_use(use)
	inventory.remove_uid(uid, 1)
	EventBus.item_used.emit(str(d["id"]))
	return "%s%s" % [d["name"], (": " + msg) if msg != "" else ""]


func drop(uid: int) -> void:
	for slot in equipment:
		if int(equipment[slot]) == uid:
			equipment[slot] = 0
	inventory.remove_uid(uid, int(inventory.find(uid).get("qty", 1)))


# --- persistence -------------------------------------------------------------

func save_key() -> String:
	return "player"


func schema_sql() -> PackedStringArray:
	return [
		"CREATE TABLE IF NOT EXISTS player (id INTEGER PRIMARY KEY, name TEXT, location_id TEXT, pos_x REAL, pos_y REAL, pos_z REAL, has_position INTEGER, flashlight INTEGER, kills INTEGER, survival_json TEXT, equipment_json TEXT)",
		"CREATE TABLE IF NOT EXISTS inventory_items (owner TEXT, uid INTEGER, item TEXT, qty INTEGER, quality REAL, condition REAL, ammo INTEGER, PRIMARY KEY (owner, uid))",
	]


func save_to_db(db: AfDatabase) -> void:
	db.exec("INSERT OR REPLACE INTO player VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		[name, location_id, position.x, position.y, position.z, 1 if has_position else 0, 1 if flashlight_on else 0, kills,
		JSON.stringify(survival.to_dict()), JSON.stringify(equipment)])
	db.exec("DELETE FROM inventory_items WHERE owner = 'player'")
	for s in inventory.stacks:
		db.exec("INSERT INTO inventory_items VALUES ('player', ?, ?, ?, ?, ?, ?)",
			[s["uid"], s["item"], s["qty"], s["quality"], s["condition"], s.get("ammo", 0)])


func load_from_db(db: AfDatabase) -> void:
	var rows := db.select("SELECT * FROM player WHERE id = 1")
	if rows.is_empty():
		new_game()
		return
	var r: Dictionary = rows[0]
	name = str(r["name"])
	location_id = str(r["location_id"])
	position = Vector3(float(r["pos_x"]), float(r["pos_y"]), float(r["pos_z"]))
	has_position = int(r["has_position"]) == 1
	flashlight_on = int(r["flashlight"]) == 1
	kills = int(r["kills"])
	var sv: Variant = JSON.parse_string(str(r["survival_json"]))
	survival.from_dict(sv if typeof(sv) == TYPE_DICTIONARY else {})
	var eq: Variant = JSON.parse_string(str(r["equipment_json"]))
	equipment = {"melee": 0, "firearm": 0, "body": 0}
	if typeof(eq) == TYPE_DICTIONARY:
		for k in eq:
			equipment[k] = int(eq[k])
	inventory.load_rows(db.select("SELECT * FROM inventory_items WHERE owner = 'player' ORDER BY uid"))
