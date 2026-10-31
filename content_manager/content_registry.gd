extends Node
## Data-driven content definitions merged from the core package and every
## active package in load order.
##
## Data file format (any *.json under <package>/data/, recursively):
##   { "kind": "item", "defs": [ { "id": "canned_food", ... }, ... ] }
## Ids are namespaced by package: "canned_food" in package "core" becomes
## "core:canned_food". A def with an existing full id replaces it; a def with
## "patch": true is deep-merged into it (mods altering core content).
## Lookups with a short id fall back to the "core:" namespace.

signal reloaded

const SCHEMAS := {
	"item": ["name", "category", "weight"],
	"zombie": ["name", "hp", "speed_walk", "damage"],
	"loot_table": ["entries"],
	"location": ["name", "size"],
	"region": ["name", "lat", "lon", "kind"],
	"river": ["name", "points"],
	"road": ["name", "points"],
	"need": ["name", "max"],
	"climate": ["season", "base_temp", "weather"],
	"rule": ["on", "actions"],
	"border": ["points"],
	"district": ["name", "center", "polygons"],
	"city_district": ["name", "city", "polygons"],
	"place": ["name", "type", "city", "lat", "lon"],
}

var _defs := {}            # kind -> { full_id -> def }
var _origin := {}          # "kind|full_id" -> package id
var _package_paths := {}   # package id -> root path
var overrides: Array = []  # [{kind, id, from, by}]
var load_errors: Array = []
var active_packages: Array = []  # [{id, version, type, name}]


func _ready() -> void:
	reload()


var _runtime := []  # [kind, def] generated at runtime (e.g. procedural locations)


## Registers a generated definition; it survives reload().
func add_runtime_def(kind: String, def: Dictionary) -> void:
	_runtime = _runtime.filter(func(x): return not (x[0] == kind and x[1]["id"] == def["id"]))
	_runtime.append([kind, def])
	_put_runtime(kind, def)


func _put_runtime(kind: String, def: Dictionary) -> void:
	if not _defs.has(kind):
		_defs[kind] = {}
	_defs[kind][str(def["id"])] = def
	_origin[kind + "|" + str(def["id"])] = str(def.get("_package", "core"))


func reload() -> void:
	_defs.clear()
	_origin.clear()
	_package_paths.clear()
	overrides.clear()
	load_errors.clear()
	active_packages.clear()
	_load_package("core", AfPaths.CORE_PACKAGE_DIR, AfPaths.game_version(), "SYSTEM", "Ядро игры")
	for row in Packages.resolve_active():
		var root := str(row["install_path"])
		if not DirAccess.dir_exists_absolute(root):
			load_errors.append("%s: каталог пакета отсутствует" % row["id"])
			continue
		_load_package(str(row["id"]), root, str(row["version"]), str(row["type"]), str(row["name"]))
	for r in _runtime:
		_put_runtime(r[0], r[1])
	for id in Packages.activation_errors:
		load_errors.append("%s: %s" % [id, Packages.activation_errors[id]])
	var total := 0
	for k in _defs:
		total += _defs[k].size()
	Log.i("registry", "loaded %d defs from %d packages (%d overrides, %d errors)" % [total, active_packages.size(), overrides.size(), load_errors.size()])
	reloaded.emit()
	EventBus.content_reloaded.emit()


func _load_package(pkg_id: String, root: String, version: String, type: String, name: String) -> void:
	_package_paths[pkg_id] = root
	active_packages.append({"id": pkg_id, "version": version, "type": type, "name": name})
	var files: PackedStringArray = []
	for rel in AfFs.list_files_recursive(root.path_join("data")):
		if rel.ends_with(".json"):
			files.append("data/" + rel)
	for rel in AfFs.list_files_recursive(root.path_join("scripts")):
		if rel.ends_with(".json"):
			files.append("scripts/" + rel)
	files.sort()
	for rel in files:
		var parsed: Variant = AfFs.read_json(root.path_join(rel))
		if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("kind") or typeof(parsed.get("defs")) != TYPE_ARRAY:
			load_errors.append("%s/%s: ожидается {kind, defs[]}" % [pkg_id, rel])
			continue
		var kind := str(parsed["kind"])
		if not SCHEMAS.has(kind):
			load_errors.append("%s/%s: неизвестный вид данных '%s'" % [pkg_id, rel, kind])
			continue
		for def in parsed["defs"]:
			_add_def(pkg_id, kind, def, rel)


func _add_def(pkg_id: String, kind: String, def: Variant, rel: String) -> void:
	if typeof(def) != TYPE_DICTIONARY or str(def.get("id", "")) == "":
		load_errors.append("%s/%s: определение без id" % [pkg_id, rel])
		return
	var d: Dictionary = (def as Dictionary).duplicate(true)
	var full := full_id(str(d["id"]), pkg_id)
	d["id"] = full
	if not _defs.has(kind):
		_defs[kind] = {}
	var table: Dictionary = _defs[kind]
	var key := kind + "|" + full
	if bool(d.get("patch", false)):
		if not table.has(full):
			load_errors.append("%s/%s: patch для несуществующего %s" % [pkg_id, rel, full])
			return
		d.erase("patch")
		table[full] = _deep_merge(table[full], d)
		overrides.append({"kind": kind, "id": full, "from": _origin[key], "by": pkg_id, "patch": true})
		return
	for field in SCHEMAS[kind]:
		if not d.has(field):
			load_errors.append("%s/%s: %s '%s' без обязательного поля '%s'" % [pkg_id, rel, kind, full, field])
			return
	if table.has(full):
		overrides.append({"kind": kind, "id": full, "from": _origin[key], "by": pkg_id, "patch": false})
	d["_package"] = pkg_id
	table[full] = d
	_origin[key] = pkg_id


static func full_id(id: String, pkg_id: String) -> String:
	return id if id.contains(":") else "%s:%s" % [pkg_id, id]


func _deep_merge(base: Dictionary, patch: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in patch:
		if k == "id":
			continue
		if typeof(out.get(k)) == TYPE_DICTIONARY and typeof(patch[k]) == TYPE_DICTIONARY:
			out[k] = _deep_merge(out[k], patch[k])
		else:
			out[k] = patch[k]
	return out


# --- lookup ------------------------------------------------------------------

func resolve(kind: String, id: String) -> String:
	var table: Dictionary = _defs.get(kind, {})
	if table.has(id):
		return id
	if not id.contains(":") and table.has("core:" + id):
		return "core:" + id
	return ""


func has_def(kind: String, id: String) -> bool:
	return resolve(kind, id) != ""


func get_def(kind: String, id: String) -> Dictionary:
	var r := resolve(kind, id)
	return _defs[kind][r] if r != "" else {}


func all(kind: String) -> Array:
	return _defs.get(kind, {}).values()


func ids(kind: String) -> Array:
	return _defs.get(kind, {}).keys()


func origin(kind: String, id: String) -> String:
	return str(_origin.get(kind + "|" + resolve(kind, id), ""))


func package_root(pkg_id: String) -> String:
	return str(_package_paths.get(pkg_id, ""))


func is_package_active(pkg_id: String) -> bool:
	return _package_paths.has(pkg_id)


## Resolves "pkg:relative/path" (or a path relative to the def's package) to a file path.
func asset_path(ref: String, context_pkg: String = "core") -> String:
	var pkg := context_pkg
	var rel := ref
	var colon := ref.find(":")
	if colon > 0 and not ref.begins_with("res://") and not ref.begins_with("user://"):
		pkg = ref.substr(0, colon)
		rel = ref.substr(colon + 1)
	if ref.begins_with("res://") or ref.begins_with("user://"):
		return ref
	if AfManifest.check_path(rel) != "":
		return ""
	var root := package_root(pkg)
	return "" if root == "" else root.path_join(rel)


func display_name(kind: String, id: String) -> String:
	var d := get_def(kind, id)
	return str(d.get("name", id))
