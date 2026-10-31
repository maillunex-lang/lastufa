extends Node
## FIRST autoload. Mounts signed game-code packs (.pck) before any other game
## script is loaded, so GDScript, scenes and core data can be updated over the
## network without a new APK.
##
## Must stay self-contained: it may not reference any other project script or
## class_name (those would be loaded from the APK before the pack is mounted
## and stay cached). Godot instantiates autoloads one by one, running _init()
## of each before loading the next script, so mounting in _init() makes every
## later autoload and scene come from the newest verified pack.
##
## Safety:
##  - the pack's manifest must be signed by a trusted NON-dev key
##    (res://config/trusted_keys/*.pem not starting with "dev_");
##  - every .pck must match its signed SHA-256;
##  - the pack must target this engine version and APK build, and be newer
##    than the code built into the APK;
##  - crash guard: a pack version that fails to reach the main menu twice is
##    disabled and the game boots with the previous working code.

const BOOT_FILE := "user://content/boot.json"
const ATTEMPT_FILE := "user://content/boot_attempt.json"
const DISABLED_FILE := "user://content/boot_disabled.json"
const MAX_FAILED_BOOTS := 2

var apk_version := ""
var apk_build := 0
var code_version := ""        # running code version (== apk_version when nothing is mounted)
var mounted: Array = []       # [{id, version}]
var skipped: Array = []       # [{id, version, reason}]
var engine_version := ""


func _init() -> void:
	apk_version = str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	apk_build = int(ProjectSettings.get_setting("application/config/apk_build", 1))
	ProjectSettings.set_setting("application/config/apk_version", apk_version)
	var v := Engine.get_version_info()
	engine_version = "%d.%d.%d" % [v["major"], v["minor"], v["patch"]]
	code_version = apk_version
	_mount_packs()
	if code_version != apk_version:
		ProjectSettings.set_setting("application/config/version", code_version)


func _mount_packs() -> void:
	var boot: Variant = _read_json(BOOT_FILE)
	if typeof(boot) != TYPE_DICTIONARY or typeof(boot.get("packs")) != TYPE_ARRAY:
		return
	var disabled: Variant = _read_json(DISABLED_FILE)
	var disabled_keys: Array = disabled if typeof(disabled) == TYPE_ARRAY else []
	var attempt: Variant = _read_json(ATTEMPT_FILE)
	for entry in boot["packs"]:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var id := str(entry.get("id", ""))
		var dir := str(entry.get("dir", ""))
		var manifest: Variant = _read_json(dir.path_join("manifest.json"))
		if typeof(manifest) != TYPE_DICTIONARY or str(manifest.get("id", "")) != id:
			_skip(id, "?", "манифест не найден")
			continue
		var version := str(manifest.get("version", ""))
		var key := "%s@%s" % [id, version]
		if disabled_keys.has(key):
			_skip(id, version, "отключено после неудачных запусков")
			continue
		if typeof(attempt) == TYPE_DICTIONARY and str(attempt.get("key", "")) == key and int(attempt.get("count", 0)) >= MAX_FAILED_BOOTS:
			disabled_keys.append(key)
			_write_json(DISABLED_FILE, disabled_keys)
			DirAccess.remove_absolute(ATTEMPT_FILE)
			_skip(id, version, "игра дважды не запустилась с этим обновлением — откат на предыдущий код")
			continue
		var why := _check(manifest, dir)
		if why != "":
			_skip(id, version, why)
			continue
		# crash guard: count this attempt until the game reports a healthy start
		var count := 1
		if typeof(attempt) == TYPE_DICTIONARY and str(attempt.get("key", "")) == key:
			count = int(attempt.get("count", 0)) + 1
		_write_json(ATTEMPT_FILE, {"key": key, "count": count})
		var ok := true
		for f in manifest.get("files", []):
			if str(f["path"]).get_extension() == "pck":
				ok = ok and ProjectSettings.load_resource_pack(dir.path_join(str(f["path"])), true)
		if not ok:
			_skip(id, version, "не удалось подключить пакет")
			continue
		mounted.append({"id": id, "version": version})
		if _vcmp(version, code_version) > 0:
			code_version = version
		print("[bootstrap] mounted %s" % key)


func _check(m: Dictionary, dir: String) -> String:
	if not ["SYSTEM", "ENGINE"].has(str(m.get("type", ""))):
		return "код допускается только в системных пакетах"
	if str(m.get("engine", "")) != engine_version:
		return "собран для движка %s, установлен %s" % [m.get("engine", "?"), engine_version]
	if int(m.get("min_apk_build", 1)) > apk_build:
		return "требуется новый APK (сборка %d, установлена %d)" % [int(m.get("min_apk_build", 1)), apk_build]
	if _vcmp(str(m.get("version", "")), apk_version) <= 0:
		return "не новее кода в APK (%s)" % apk_version
	if not _signature_ok(m):
		return "подпись недействительна или ключ не доверен"
	var has_pck := false
	for f in m.get("files", []):
		var rel := str(f.get("path", ""))
		if rel.get_extension() != "pck":
			continue
		has_pck = true
		if rel.contains("..") or rel.begins_with("/"):
			return "недопустимый путь"
		if _sha256(dir.path_join(rel)) != str(f.get("sha256", "")).to_lower():
			return "файл %s повреждён" % rel
	if not has_pck:
		return "нет .pck"
	return ""


## Called once the game reached the main menu: the mounted code works.
func mark_boot_ok() -> void:
	if FileAccess.file_exists(ATTEMPT_FILE):
		DirAccess.remove_absolute(ATTEMPT_FILE)


func is_code_updated() -> bool:
	return not mounted.is_empty()


# --- signature (mirror of AfManifest.signing_payload / tools/afpkg.py) -------

static func signing_payload(d: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("ashenfall-package-v1")
	lines.append(str(d.get("id", "")))
	lines.append(str(d.get("version", "")))
	lines.append(str(d.get("type", "")))
	lines.append(str(d.get("min_game_version", "")))
	var deps: Dictionary = d.get("dependencies", {}) if typeof(d.get("dependencies", {})) == TYPE_DICTIONARY else {}
	var dep_keys := deps.keys()
	dep_keys.sort()
	for k in dep_keys:
		lines.append("dep %s %s" % [k, deps[k]])
	var entries := PackedStringArray()
	for f in d.get("files", []):
		entries.append("file %s %s" % [f["path"], str(f["sha256"]).to_lower()])
	entries.sort()
	lines.append_array(entries)
	return "\n".join(lines)


func _signature_ok(m: Dictionary) -> bool:
	var sig_b64 := str(m.get("signature", ""))
	if sig_b64.is_empty():
		return false
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(signing_payload(m).to_utf8_buffer())
	var digest := ctx.finish()
	var sig := Marshalls.base64_to_raw(sig_b64)
	var crypto := Crypto.new()
	var dir := DirAccess.open("res://config/trusted_keys")
	if dir == null:
		return false
	for f in dir.get_files():
		# development keys are public in the repository: never trusted for code
		if not f.ends_with(".pem") or f.begins_with("dev_"):
			continue
		var key := CryptoKey.new()
		if key.load_from_string(FileAccess.get_file_as_string("res://config/trusted_keys/" + f), true) == OK:
			if crypto.verify(HashingContext.HASH_SHA256, digest, sig, key):
				return true
	return false


# --- helpers ---------------------------------------------------------------------

func _skip(id: String, version: String, reason: String) -> void:
	skipped.append({"id": id, "version": version, "reason": reason})
	print("[bootstrap] skipped %s@%s: %s" % [id, version, reason])


static func _vcmp(a: String, b: String) -> int:
	var pa := a.split("-")[0].split(".")
	var pb := b.split("-")[0].split(".")
	for i in 3:
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func _write_json(path: String, data: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()


static func _sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1 << 20))
	return ctx.finish().hex_encode()
