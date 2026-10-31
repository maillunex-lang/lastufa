class_name AfManifest
extends RefCounted
## Package manifest validation, path safety rules and signature verification.

const TYPES := ["ENGINE", "SYSTEM", "REGION", "ASSET", "AUDIO", "QUEST", "LOCALIZATION", "MOD", "DLC"]
const TYPE_LABELS := {
	"ENGINE": "Движок", "SYSTEM": "Система", "REGION": "Регион", "ASSET": "Ресурсы",
	"AUDIO": "Аудио", "QUEST": "Задания", "LOCALIZATION": "Локализация", "MOD": "Мод", "DLC": "DLC",
}
const MANIFEST_NAMES := ["manifest.json", "mod.json"]

## Catalog groups (order = display order). Authors set "category" in the
## manifest; otherwise it is inferred from the package type and its files.
const CATEGORIES := {
	"system": "Обновления игры",
	"locations": "Локации и регионы",
	"items": "Предметы и оружие",
	"zombies": "Заражённые",
	"quests": "Задания и сюжет",
	"gameplay": "Геймплей и баланс",
	"graphics": "Графика",
	"audio": "Звук и музыка",
	"localization": "Языки",
	"other": "Прочее",
}
const ID_REGEX := "^[a-z0-9][a-z0-9_.\\-]{2,63}$"

## Versions of game systems that packages may declare compatibility with.
const SYSTEM_VERSIONS := {
	"content": "1.0.0",
	"rules": "1.0.0",
	"world_map": "1.0.0",
	"survival": "1.0.0",
	"locations": "1.0.0",
	"zombies": "1.0.0",
	"items": "1.0.0",
}

const ALLOWED_EXT := ["json", "png", "jpg", "jpeg", "webp", "glb", "gltf", "bin", "ogg", "wav", "mp3",
	"md", "txt", "csv", "po", "ttf", "otf", "pck"]
const ALLOWED_TOP_DIRS := ["data", "assets", "scripts", "locale", "code"]
const ALLOWED_ROOT_FILES := ["manifest.json", "mod.json", "preview.png", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE.md", "LICENSE.txt"]
## Executable payloads are never accepted, regardless of signature.
const FORBIDDEN_EXT := ["gd", "gdc", "gde", "cs", "so", "dll", "dylib", "dex", "jar", "apk", "aab", "exe", "sh", "bat", "py", "js", "wasm"]
const MAX_FILES := 20000
const MAX_PACKAGE_BYTES := 4 * 1024 * 1024 * 1024


static func category_of(d: Dictionary) -> String:
	var c := str(d.get("category", ""))
	if CATEGORIES.has(c):
		return c
	match str(d.get("type", "")):
		"SYSTEM", "ENGINE": return "system"
		"REGION": return "locations"
		"ASSET": return "graphics"
		"AUDIO": return "audio"
		"QUEST": return "quests"
		"LOCALIZATION": return "localization"
	var paths := PackedStringArray()
	for f in d.get("files", []):
		paths.append(str(f.get("path", "")).to_lower())
	return infer_category(paths)


## Guess from file names: data/location*.json → locations, data/items*.json → items…
static func infer_category(paths: PackedStringArray) -> String:
	var score := {}
	for p in paths:
		var c := ""
		if p.begins_with("data/") and (p.contains("location") or p.contains("region") or p.contains("map")):
			c = "locations"
		elif p.begins_with("data/") and (p.contains("item") or p.contains("weapon") or p.contains("loot")):
			c = "items"
		elif p.begins_with("data/") and p.contains("zombie"):
			c = "zombies"
		elif p.begins_with("data/") and (p.contains("quest") or p.contains("story")):
			c = "quests"
		elif p.begins_with("assets/") and p.get_extension() in ["ogg", "wav", "mp3"]:
			c = "audio"
		elif p.begins_with("assets/"):
			c = "graphics"
		elif p.begins_with("locale/"):
			c = "localization"
		elif p.begins_with("scripts/") or p.begins_with("data/"):
			c = "gameplay"
		if c != "":
			score[c] = int(score.get(c, 0)) + 1
	var best := "other"
	var n := 0
	for c in score:
		if int(score[c]) > n:
			n = int(score[c])
			best = c
	return best


## Returns "" when the relative path is safe, else a reason.
static func check_path(rel: String) -> String:
	if rel.is_empty() or rel.length() > 200:
		return "недопустимая длина пути"
	if rel.begins_with("/") or rel.contains("\\") or rel.contains(":") or rel.contains("\u0000"):
		return "абсолютный или некорректный путь: " + rel
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9_\\-./]+$")
	if re.search(rel) == null:
		return "недопустимые символы в пути: " + rel
	var segments := rel.split("/")
	for s in segments:
		if s == "" or s == "." or s == "..":
			return "выход за пределы пакета: " + rel
	var ext := rel.get_extension().to_lower()
	if FORBIDDEN_EXT.has(ext):
		return "исполняемый файл запрещён: " + rel
	if segments.size() == 1:
		if not ALLOWED_ROOT_FILES.has(rel):
			return "файл вне разрешённых каталогов: " + rel
		return ""
	if not ALLOWED_TOP_DIRS.has(segments[0]):
		return "каталог не разрешён: " + segments[0]
	if not ALLOWED_EXT.has(ext):
		return "тип файла не разрешён: " + rel
	return ""


## Validates manifest structure. Returns list of errors (empty = valid).
## require_files: when true, a file list with checksums is mandatory.
static func validate(m: Variant, require_files: bool) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(m) != TYPE_DICTIONARY:
		return PackedStringArray(["манифест не является JSON-объектом"])
	var d: Dictionary = m
	var re := RegEx.new()
	re.compile(ID_REGEX)
	if re.search(str(d.get("id", ""))) == null:
		errors.append("некорректный id пакета")
	if str(d.get("id", "")) == "core":
		errors.append("id 'core' зарезервирован")
	if str(d.get("name", "")).strip_edges().is_empty():
		errors.append("нет названия")
	if not TYPES.has(str(d.get("type", ""))):
		errors.append("неизвестный тип пакета: %s" % d.get("type", ""))
	if not AfVersion.is_valid(str(d.get("version", ""))):
		errors.append("некорректная версия")
	if d.has("min_game_version") and not AfVersion.is_valid(str(d["min_game_version"])):
		errors.append("некорректная min_game_version")
	if d.has("dependencies") and typeof(d["dependencies"]) != TYPE_DICTIONARY:
		errors.append("dependencies должен быть объектом {id: ограничение}")
	if d.has("conflicts") and typeof(d["conflicts"]) != TYPE_ARRAY:
		errors.append("conflicts должен быть массивом")
	if d.has("files"):
		if typeof(d["files"]) != TYPE_ARRAY:
			errors.append("files должен быть массивом")
		else:
			var files: Array = d["files"]
			if files.size() > MAX_FILES:
				errors.append("слишком много файлов")
			var seen := {}
			var total := 0
			for f in files:
				if typeof(f) != TYPE_DICTIONARY or not f.has("path") or not f.has("sha256"):
					errors.append("запись файла без path/sha256")
					continue
				var why := check_path(str(f["path"]))
				if why != "":
					errors.append(why)
				if seen.has(f["path"]):
					errors.append("дубликат файла: %s" % f["path"])
				seen[f["path"]] = true
				if str(f["sha256"]).length() != 64:
					errors.append("некорректная контрольная сумма: %s" % f["path"])
				total += int(f.get("size", 0))
			if total > MAX_PACKAGE_BYTES:
				errors.append("пакет слишком большой")
	elif require_files:
		errors.append("нет списка файлов с контрольными суммами")
	return errors


## Compatibility of a valid manifest with this game build.
static func check_compat(d: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var gv := AfPaths.game_version()
	if d.has("min_game_version") and AfVersion.compare(gv, str(d["min_game_version"])) < 0:
		errors.append("требуется версия игры %s (установлена %s)" % [d["min_game_version"], gv])
	if d.has("max_game_version") and AfVersion.compare(gv, str(d["max_game_version"])) > 0:
		errors.append("пакет поддерживает игру до версии %s" % d["max_game_version"])
	var api := int(d.get("api_version", AfPaths.MOD_API_VERSION))
	if api > AfPaths.MOD_API_VERSION or api < 1:
		errors.append("API модов v%d не поддерживается (поддерживается v%d)" % [api, AfPaths.MOD_API_VERSION])
	var systems: Dictionary = d.get("systems", {}) if typeof(d.get("systems", {})) == TYPE_DICTIONARY else {}
	for sys in systems:
		if not SYSTEM_VERSIONS.has(sys):
			errors.append("неизвестная игровая система: %s" % sys)
		elif not AfVersion.satisfies(SYSTEM_VERSIONS[sys], str(systems[sys])):
			errors.append("система %s %s не удовлетворяет %s" % [sys, SYSTEM_VERSIONS[sys], systems[sys]])
	return errors


## Deterministic payload covered by the signature. Mirrors tools/afpkg.py.
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


## Returns key id that verified the signature, or "" if unsigned/invalid.
static func verify_signature(d: Dictionary) -> String:
	var sig_b64 := str(d.get("signature", ""))
	if sig_b64.is_empty():
		return ""
	var sig := Marshalls.base64_to_raw(sig_b64)
	var digest := signing_payload(d).to_utf8_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(digest)
	var hash_bytes := ctx.finish()
	var crypto := Crypto.new()
	for key_info in trusted_keys():
		var key: CryptoKey = key_info["key"]
		if crypto.verify(HashingContext.HASH_SHA256, hash_bytes, sig, key):
			return str(key_info["id"])
	return ""


## Trusted public keys from res://config/trusted_keys. Keys whose file name
## starts with "dev_" are only trusted in debug builds.
static func trusted_keys() -> Array:
	var out := []
	var dir := DirAccess.open("res://config/trusted_keys")
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".pem"):
			continue
		if f.begins_with("dev_") and not OS.is_debug_build():
			continue
		var key := CryptoKey.new()
		if key.load_from_string(FileAccess.get_file_as_string("res://config/trusted_keys/" + f), true) == OK:
			out.append({"id": f.get_basename(), "key": key})
	return out
