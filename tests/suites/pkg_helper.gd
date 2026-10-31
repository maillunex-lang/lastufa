class_name TestPkg
extends RefCounted
## Builds package ZIPs for tests (mirrors what tools/afpkg.py produces).


static func manifest(id: String, version: String, type: String, files: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var m := {"id": id, "name": "Test " + id, "type": type, "version": version, "min_game_version": "0.1.0",
		"api_version": 1, "author": "tests", "files": []}
	for path in files:
		var bytes: PackedByteArray = files[path] if files[path] is PackedByteArray else str(files[path]).to_utf8_buffer()
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(bytes)
		m["files"].append({"path": path, "sha256": ctx.finish().hex_encode(), "size": bytes.size()})
	for k in extra:
		m[k] = extra[k]
	return m


static func sign(m: Dictionary) -> void:
	var key := CryptoKey.new()
	key.load("res://tools/keys/dev_private.pem")
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(AfManifest.signing_payload(m).to_utf8_buffer())
	m["signature"] = Marshalls.raw_to_base64(Crypto.new().sign(HashingContext.HASH_SHA256, ctx.finish(), key))


static func zip(t, path: String, m: Dictionary, files: Dictionary, manifest_name: String = "manifest.json") -> void:
	var entries := files.duplicate()
	entries[manifest_name] = JSON.stringify(m)
	t.make_zip(path, entries)


static func data_file(kind: String, defs: Array) -> String:
	return JSON.stringify({"kind": kind, "defs": defs})
