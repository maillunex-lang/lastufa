extends SceneTree
## Compiles every GDScript in the project and reports failures.
## Usage: godot --headless -s res://tools/check_scripts.gd

var _done := false


func _process(_delta: float) -> bool:
	# autoload singletons are registered only once the tree is running
	if _done:
		return false
	_done = true
	_check()
	return false


func _check() -> void:
	var bad := 0
	var n := 0
	for path in _scan("res://"):
		n += 1
		var s: GDScript = load(path)
		if s == null or not s.can_instantiate():
			bad += 1
			printerr("FAILED: " + path)
	print("checked %d scripts, %d failed" % [n, bad])
	quit(1 if bad > 0 else 0)


func _scan(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if sub.begins_with(".") or sub == "addons":
			continue
		out.append_array(_scan(dir.path_join(sub)))
	return out
