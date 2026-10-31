class_name AfInventory
extends RefCounted
## Weight-limited inventory of item stacks. Each stack carries quality
## (manufacturing/finding quality 0..1) and condition (wear/spoilage 0..1).
## Stacks whose definition is missing (package/mod removed) are kept with
## available = false and saved back unchanged.

signal changed

var max_weight := 28.0
var stacks: Array = []   # [{uid, item, qty, quality, condition, ammo, available}]
var _next_uid := 1


func clear() -> void:
	stacks.clear()
	_next_uid = 1
	changed.emit()


func def_of(stack: Dictionary) -> Dictionary:
	return Registry.get_def("item", str(stack["item"]))


func total_weight() -> float:
	var w := 0.0
	for s in stacks:
		var d := def_of(s)
		w += float(d.get("weight", 0.0)) * int(s["qty"])
	return w


func free_weight() -> float:
	return max_weight - total_weight()


func find(uid: int) -> Dictionary:
	for s in stacks:
		if int(s["uid"]) == uid:
			return s
	return {}


func count(item_id: String) -> int:
	var full := Registry.resolve("item", item_id)
	var n := 0
	for s in stacks:
		if s["item"] == full and s.get("available", true):
			n += int(s["qty"])
	return n


## Adds items; respects weight and stack size. Returns quantity that did NOT fit.
func add(item_id: String, qty: int, quality: float = 1.0, condition: float = 1.0, ignore_weight: bool = false) -> int:
	var full := Registry.resolve("item", item_id)
	if full == "" or qty <= 0:
		return qty
	var d := Registry.get_def("item", full)
	var unit_w := float(d.get("weight", 0.0))
	var stack_max := int(d.get("stack", 1))
	var left := qty
	if not ignore_weight and unit_w > 0.0:
		left = mini(left, int(floor((free_weight() + 0.0001) / unit_w)))
	var overflow := qty - left
	# merge into similar stacks (same item, close quality/condition)
	for s in stacks:
		if left <= 0:
			break
		if s["item"] == full and int(s["qty"]) < stack_max and absf(float(s["condition"]) - condition) < 0.1 and absf(float(s["quality"]) - quality) < 0.15:
			var take := mini(left, stack_max - int(s["qty"]))
			s["qty"] = int(s["qty"]) + take
			left -= take
	while left > 0:
		var take := mini(left, stack_max)
		stacks.append({"uid": _next_uid, "item": full, "qty": take, "quality": quality, "condition": condition, "ammo": 0, "available": true})
		_next_uid += 1
		left -= take
	changed.emit()
	return overflow


func remove_uid(uid: int, qty: int = 1) -> int:
	var s := find(uid)
	if s.is_empty():
		return 0
	var take := mini(qty, int(s["qty"]))
	s["qty"] = int(s["qty"]) - take
	if int(s["qty"]) <= 0:
		stacks.erase(s)
	changed.emit()
	return take


func remove_item(item_id: String, qty: int) -> int:
	var full := Registry.resolve("item", item_id)
	var left := qty
	for s in stacks.duplicate():
		if left <= 0:
			break
		if s["item"] == full and s.get("available", true):
			left -= remove_uid(int(s["uid"]), left)
	return qty - left


## Food/drink spoilage over game time.
func simulate(dt_minutes: float) -> void:
	var any := false
	for s in stacks:
		var d := def_of(s)
		if d.has("spoil_hours") and float(d["spoil_hours"]) > 0.0:
			var before := float(s["condition"])
			s["condition"] = maxf(0.0, before - dt_minutes / (float(d["spoil_hours"]) * 60.0))
			any = any or (before >= 0.25 and float(s["condition"]) < 0.25)
	if any:
		changed.emit()


func mark_availability() -> void:
	for s in stacks:
		s["available"] = Registry.has_def("item", str(s["item"]))


func to_rows() -> Array:
	return stacks


func load_rows(rows: Array) -> void:
	stacks.clear()
	_next_uid = 1
	for r in rows:
		var s := {"uid": int(r["uid"]), "item": str(r["item"]), "qty": int(r["qty"]), "quality": float(r["quality"]),
			"condition": float(r["condition"]), "ammo": int(r.get("ammo", 0)), "available": true}
		stacks.append(s)
		_next_uid = maxi(_next_uid, int(r["uid"]) + 1)
	mark_availability()
	changed.emit()


static func roll_loot(table_id: String, rng: RandomNumberGenerator, scarcity: float = 1.0) -> Array:
	var t := Registry.get_def("loot_table", table_id)
	var out := []
	if t.is_empty():
		return out
	if rng.randf() < float(t.get("empty_chance", 0.0)) + (1.0 - scarcity) * 0.5:
		return out
	var mult := Session.config.p("loot")
	if mult < 1.0 and rng.randf() < (1.0 - mult) * 0.4:
		return out
	var rolls: Array = t.get("rolls", [1, 1])
	var raw := rng.randi_range(int(rolls[0]), int(rolls[1])) * mult
	var n := int(floor(raw)) + (1 if rng.randf() < raw - floor(raw) else 0)
	var entries: Array = t["entries"]
	var total := 0.0
	for e in entries:
		total += float(e.get("weight", 1.0))
	for _i in n:
		var pick := rng.randf() * total
		for e in entries:
			pick -= float(e.get("weight", 1.0))
			if pick <= 0.0:
				var q: Array = e.get("quality", [0.6, 1.0])
				var item_id := str(e["item"])
				if Registry.has_def("item", item_id):
					out.append({"item": Registry.resolve("item", item_id), "qty": rng.randi_range(int(e.get("min", 1)), int(e.get("max", e.get("min", 1)))),
						"quality": rng.randf_range(float(q[0]), float(q[1])), "condition": rng.randf_range(0.7, 1.0)})
				break
	return out
