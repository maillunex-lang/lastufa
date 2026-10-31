class_name AfFs
extends RefCounted
## File-system helpers used by the package installer, save manager and downloader.


static func sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(65536))
	f.close()
	return ctx.finish().hex_encode()


static func file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


static func remove_recursive(path: String) -> bool:
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path) == OK
	if not DirAccess.dir_exists_absolute(path):
		return true
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	dir.include_hidden = true
	for f in dir.get_files():
		if DirAccess.remove_absolute(path.path_join(f)) != OK:
			return false
	for sub in dir.get_directories():
		if not remove_recursive(path.path_join(sub)):
			return false
	return DirAccess.remove_absolute(path) == OK


static func copy_recursive(src: String, dst: String) -> bool:
	if not DirAccess.dir_exists_absolute(src):
		return false
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return false
	dir.include_hidden = true
	for f in dir.get_files():
		if DirAccess.copy_absolute(src.path_join(f), dst.path_join(f)) != OK:
			return false
	for sub in dir.get_directories():
		if not copy_recursive(src.path_join(sub), dst.path_join(sub)):
			return false
	return true


## Lists files relative to root, recursively, using forward slashes.
static func list_files_recursive(root: String, rel: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(root.path_join(rel) if rel != "" else root)
	if dir == null:
		return out
	dir.include_hidden = true
	for f in dir.get_files():
		out.append(f if rel == "" else rel + "/" + f)
	for sub in dir.get_directories():
		out.append_array(list_files_recursive(root, sub if rel == "" else rel + "/" + sub))
	return out


static func dir_size(root: String) -> int:
	var total := 0
	for rel in list_files_recursive(root):
		total += maxi(0, file_size(root.path_join(rel)))
	return total


static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var parser := JSON.new()
	if parser.parse(text) != OK:
		Log.w("fs", "JSON parse error in %s:%d %s" % [path, parser.get_error_line(), parser.get_error_message()])
		return null
	return parser.data


## Atomic write: temp file + rename so a crash never leaves a half-written file.
static func write_text_atomic(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.flush()
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path) == OK


static func write_json_atomic(path: String, data: Variant) -> bool:
	return write_text_atomic(path, JSON.stringify(data, "\t"))


static func space_left(path: String = "user://") -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return -1
	return dir.get_space_left()


static func human_size(bytes: int) -> String:
	if bytes < 0:
		return "?"
	if bytes < 1024:
		return "%d Б" % bytes
	if bytes < 1024 * 1024:
		return "%.1f КБ" % (bytes / 1024.0)
	if bytes < 1024 * 1024 * 1024:
		return "%.1f МБ" % (bytes / 1048576.0)
	return "%.2f ГБ" % (bytes / 1073741824.0)
