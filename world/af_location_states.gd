class_name AfLocationStates
extends RefCounted
## Persistent state of detailed (3D) locations: searched containers with their
## remaining contents and surviving zombies. A location never visited has no
## zombie record and is populated from its definition on first entry.

var locations := {}   # location id -> {containers: {cid: {searched, items}}, zombies: Array|null, last_visit: float}


func clear() -> void:
	locations.clear()


func state(loc_id: String) -> Dictionary:
	if not locations.has(loc_id):
		locations[loc_id] = {"containers": {}, "zombies": null, "last_visit": -1.0}
	return locations[loc_id]


func container(loc_id: String, cid: String) -> Dictionary:
	var st := state(loc_id)
	if not st["containers"].has(cid):
		st["containers"][cid] = {"searched": false, "items": []}
	return st["containers"][cid]


func save_key() -> String:
	return "locations"


func schema_sql() -> PackedStringArray:
	return [
		"CREATE TABLE IF NOT EXISTS location_state (location_id TEXT PRIMARY KEY, last_visit REAL, zombies_json TEXT)",
		"CREATE TABLE IF NOT EXISTS container_state (location_id TEXT, container_id TEXT, searched INTEGER, items_json TEXT, PRIMARY KEY (location_id, container_id))",
	]


func save_to_db(db: AfDatabase) -> void:
	db.exec("DELETE FROM location_state")
	db.exec("DELETE FROM container_state")
	for lid in locations:
		var st: Dictionary = locations[lid]
		db.exec("INSERT INTO location_state VALUES (?, ?, ?)", [lid, st["last_visit"], JSON.stringify(st["zombies"])])
		for cid in st["containers"]:
			var c: Dictionary = st["containers"][cid]
			db.exec("INSERT INTO container_state VALUES (?, ?, ?, ?)", [lid, cid, 1 if c["searched"] else 0, JSON.stringify(c["items"])])


func load_from_db(db: AfDatabase) -> void:
	locations.clear()
	for r in db.select("SELECT * FROM location_state"):
		var z: Variant = JSON.parse_string(str(r["zombies_json"]))
		locations[r["location_id"]] = {"containers": {}, "zombies": z if typeof(z) == TYPE_ARRAY else null, "last_visit": float(r["last_visit"])}
	for r in db.select("SELECT * FROM container_state"):
		var items: Variant = JSON.parse_string(str(r["items_json"]))
		state(str(r["location_id"]))["containers"][str(r["container_id"])] = {"searched": int(r["searched"]) == 1, "items": items if typeof(items) == TYPE_ARRAY else []}
