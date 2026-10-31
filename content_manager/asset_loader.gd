extends Node
## Loads assets from res:// (built-in, imported) and from installed packages in
## user:// (raw files: PNG/JPG/WebP, GLB/GLTF, OGG/WAV) with an LRU cache
## bounded by the performance profile. Loading can be synchronous or async
## (worker thread for decoding; scene/texture creation on the main thread).

var _cache := {}          # path -> {res, bytes, used}
var _cache_bytes := 0
var _use_counter := 0
var _pending := {}        # path -> Array[Callable]
var _threaded_res := {}   # res:// path -> true (ResourceLoader threaded request)
var _worker_results := {} # path -> Variant (Image / GLTFState)
var _mutex := Mutex.new()


func _process(_delta: float) -> void:
	if _pending.is_empty():
		return
	for path in _threaded_res.keys():
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			_threaded_res.erase(path)
			_finish(path, ResourceLoader.load_threaded_get(path))
		elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_threaded_res.erase(path)
			_finish(path, null)
	_mutex.lock()
	var done := _worker_results.duplicate()
	_worker_results.clear()
	_mutex.unlock()
	for path in done:
		_finish(path, _finalize_worker(path, done[path]))


func load_sync(path: String) -> Variant:
	if _cache.has(path):
		return _touch(path)
	var res: Variant = null
	if path.begins_with("res://"):
		res = load(path) if ResourceLoader.exists(path) else null
	else:
		res = _finalize_worker(path, _decode(path))
	if res != null:
		_store(path, res)
	return res


## callback(resource_or_null)
func load_async(path: String, callback: Callable) -> void:
	if _cache.has(path):
		callback.call(_touch(path))
		return
	if _pending.has(path):
		_pending[path].append(callback)
		return
	_pending[path] = [callback]
	if path.begins_with("res://"):
		if ResourceLoader.load_threaded_request(path) == OK:
			_threaded_res[path] = true
		else:
			_finish(path, null)
	else:
		WorkerThreadPool.add_task(func():
			var decoded: Variant = _decode(path)
			_mutex.lock()
			_worker_results[path] = decoded
			_mutex.unlock())


func _decode(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	match path.get_extension().to_lower():
		"png", "jpg", "jpeg", "webp":
			var img := Image.load_from_file(path)
			if img and not img.is_empty() and not img.has_mipmaps():
				img.generate_mipmaps()
			return img
		"glb", "gltf":
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(path, state) != OK:
				return null
			return {"doc": doc, "state": state}
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"mp3":
			var s := AudioStreamMP3.new()
			s.data = FileAccess.get_file_as_bytes(path)
			return s
		"json":
			return AfFs.read_json(path)
	return null


func _finalize_worker(_path: String, decoded: Variant) -> Variant:
	if decoded is Image:
		return ImageTexture.create_from_image(decoded)
	if typeof(decoded) == TYPE_DICTIONARY and decoded.has("doc"):
		var node: Node = decoded["doc"].generate_scene(decoded["state"])
		var packed := PackedScene.new()
		_own_recursive(node, node)
		packed.pack(node)
		node.free()
		return packed
	return decoded


func _own_recursive(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_own_recursive(c, owner_node)


func _finish(path: String, res: Variant) -> void:
	if res != null:
		_store(path, res)
	var cbs: Array = _pending.get(path, [])
	_pending.erase(path)
	for cb in cbs:
		cb.call(res)


func _estimate_bytes(res: Variant) -> int:
	if res is Texture2D:
		return res.get_width() * res.get_height() * 4 * 4 / 3
	if res is AudioStream:
		return 2 * 1024 * 1024
	if res is PackedScene:
		return 4 * 1024 * 1024
	return 64 * 1024


func _store(path: String, res: Variant) -> void:
	_use_counter += 1
	var bytes := _estimate_bytes(res)
	_cache[path] = {"res": res, "bytes": bytes, "used": _use_counter}
	_cache_bytes += bytes
	_evict()


func _touch(path: String) -> Variant:
	_use_counter += 1
	_cache[path]["used"] = _use_counter
	return _cache[path]["res"]


func _evict() -> void:
	var budget := int(Settings.p("asset_cache_mb")) * 1024 * 1024
	while _cache_bytes > budget and _cache.size() > 1:
		var oldest := ""
		var oldest_use := 1 << 62
		for p in _cache:
			if _cache[p]["used"] < oldest_use:
				oldest_use = _cache[p]["used"]
				oldest = p
		_cache_bytes -= int(_cache[oldest]["bytes"])
		_cache.erase(oldest)


func clear() -> void:
	_cache.clear()
	_cache_bytes = 0


func cache_bytes() -> int:
	return _cache_bytes
