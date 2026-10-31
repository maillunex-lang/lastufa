class_name AfVersion
extends RefCounted
## Semantic version helpers: parsing, comparison and constraint matching.
## Supported constraints: "*", "1.2.3", "=1.2.3", ">=1.2", ">1.0.0", "<=2", "<2.0.0",
## "^1.2.0" (same major), "~1.2.0" (same major.minor). Several constraints may be
## separated by spaces or commas and must all hold.


static func parse(v: String) -> PackedInt32Array:
	var core := v.strip_edges()
	var cut := core.find("-")
	if cut >= 0:
		core = core.substr(0, cut)
	cut = core.find("+")
	if cut >= 0:
		core = core.substr(0, cut)
	var parts := core.split(".")
	var out := PackedInt32Array([0, 0, 0])
	for idx in range(mini(3, parts.size())):
		if not parts[idx].is_valid_int():
			return PackedInt32Array()
		out[idx] = parts[idx].to_int()
	return out


static func is_valid(v: String) -> bool:
	if v.strip_edges().is_empty():
		return false
	return parse(v).size() == 3


## Returns -1, 0 or 1.
static func compare(a: String, b: String) -> int:
	var pa := parse(a)
	var pb := parse(b)
	if pa.size() != 3 or pb.size() != 3:
		return 0
	for idx in range(3):
		if pa[idx] < pb[idx]:
			return -1
		if pa[idx] > pb[idx]:
			return 1
	return 0


static func satisfies(version: String, constraint: String) -> bool:
	var c := constraint.strip_edges()
	if c.is_empty() or c == "*":
		return true
	for raw in c.replace(",", " ").split(" ", false):
		if not _satisfies_one(version, raw.strip_edges()):
			return false
	return true


static func _satisfies_one(version: String, c: String) -> bool:
	var ops := [">=", "<=", ">", "<", "=", "^", "~"]
	var op := "="
	for candidate in ops:
		if c.begins_with(candidate):
			op = candidate
			c = c.substr(candidate.length())
			break
	if not is_valid(c):
		return false
	var cmp := compare(version, c)
	var pv := parse(version)
	var pc := parse(c)
	match op:
		">=":
			return cmp >= 0
		"<=":
			return cmp <= 0
		">":
			return cmp > 0
		"<":
			return cmp < 0
		"^":
			return cmp >= 0 and pv[0] == pc[0]
		"~":
			return cmp >= 0 and pv[0] == pc[0] and pv[1] == pc[1]
		_:
			return cmp == 0
