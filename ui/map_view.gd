class_name AfMapView
extends Control
## Multi-level map drawn from data:
##   republic      — all 63 districts / city okrugs of Bashkortostan, rivers, highways, towns
##   district      — one district enlarged: every settlement, roads, rivers, travel links
##   city          — a city (Ufa) with its city districts and main streets
##   city_district — one city district with its significant places
## Pan with a finger/mouse drag, zoom with pinch/wheel, tap to select.

signal selected(kind: String, id: String)
signal level_changed

const KIND_COLORS := {
	"city": Color("e6e1d8"), "town": Color("c9c3b6"), "village": Color("9aa48a"), "industrial": Color("c9a050"),
	"military": Color("d0473e"), "lab": Color("9f8fd0"), "infrastructure": Color("6fa3c7"), "nature": Color("7fb069"),
}
const PLACE_COLORS := {
	"hospital": Color("e05a5a"), "police": Color("5a7ae0"), "fire_station": Color("e07a3a"), "university": Color("b08fe0"),
	"college": Color("a08fd0"), "school": Color("9f9fd0"), "mall": Color("e0c05a"), "supermarket": Color("d0b060"),
	"market": Color("c0a050"), "townhall": Color("c8c8c8"), "prison": Color("8a8a8a"), "bus_station": Color("6fc0a0"),
	"station": Color("6fc0a0"), "industrial": Color("b08a5a"), "power_plant": Color("d09a3a"), "park": Color("7fb069"),
	"stadium": Color("7fb069"), "fuel": Color("e0a03a"), "military": Color("d0473e"), "residential": Color("d98a3a"),
}

var level := "republic"
var focus := ""          # district id / city id / city_district id
var sel_kind := ""
var sel_id := ""

var _zoom := 1.0
var _pan := Vector2.ZERO
var _bounds := Rect2(0, 0, 1, 1)
var _cache := {}         # def id -> Array[PackedVector2Array] in map space
var _touches := {}
var _pinch_d := 0.0
var _pinch_z := 1.0
var _moved := 0.0
var _label_rects: Array[Rect2] = []
var _city_district_ids: Array = []


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


# --- coordinates -------------------------------------------------------------------

const K := 0.5807  # cos(54.5°): keeps shapes undistorted at Bashkortostan's latitude


static func to_map(lat: float, lon: float) -> Vector2:
	return Vector2(lon * K, -lat)


func _scale() -> float:
	return minf(size.x / maxf(_bounds.size.x, 1e-6), size.y / maxf(_bounds.size.y, 1e-6)) * 0.92 * _zoom


func _offset() -> Vector2:
	return size * 0.5 + _pan - _bounds.get_center() * _scale()


func to_screen(m: Vector2) -> Vector2:
	return m * _scale() + _offset()


func screen_of(lat: float, lon: float) -> Vector2:
	return to_screen(to_map(lat, lon))


func _rings(def: Dictionary, key: String = "polygons") -> Array:
	var id := str(def["id"]) + "|" + key
	if not _cache.has(id):
		var out := []
		var src: Array = def.get(key, [])
		if key == "points":
			src = [src]
		for ring in src:
			var pts := PackedVector2Array()
			for p in ring:
				pts.append(to_map(float(p[0]), float(p[1])))
			out.append(pts)
		_cache[id] = out
	return _cache[id]


static func _rect_of(rings: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for ring in rings:
		for p in ring:
			if first:
				r = Rect2(p, Vector2.ZERO)
				first = false
			else:
				r = r.expand(p)
	return r


# --- navigation ------------------------------------------------------------------------

func show_level(p_level: String, p_focus: String = "") -> void:
	level = p_level
	focus = p_focus
	_zoom = 1.0
	_pan = Vector2.ZERO
	match level:
		"republic":
			var r := Rect2()
			for b in Registry.all("border"):
				r = _rect_of(_rings(b, "points"))
			_bounds = r
		"district":
			_bounds = _rect_of(_rings(Registry.get_def("district", focus))).grow(0.04)
		"city":
			var cd := Registry.all("city_district").filter(func(c): return str(c.get("city", "")) == focus)
			var rings := []
			for c in cd:
				rings.append_array(_rings(c))
			_bounds = _rect_of(rings).grow(0.01)
		"city_district":
			_bounds = _rect_of(_rings(Registry.get_def("city_district", focus))).grow(0.004)
	level_changed.emit()
	queue_redraw()


func select(kind: String, id: String) -> void:
	sel_kind = kind
	sel_id = id
	queue_redraw()
	selected.emit(kind, id)


# --- drawing ------------------------------------------------------------------------------

func _draw() -> void:
	_label_rects.clear()
	draw_rect(Rect2(Vector2.ZERO, size), Color("0e1115"))
	var s := _scale()
	draw_set_transform(_offset(), 0.0, Vector2(s, s))
	var px := 1.0 / s   # one screen pixel in map units
	match level:
		"republic", "district":
			_draw_region_levels(px)
		"city", "city_district":
			_draw_city_levels(px)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_labels()


func _draw_region_levels(px: float) -> void:
	var wm := Session.world_map
	var cur_d := wm.district_of(wm.current_region)
	for b in Registry.all("border"):
		for ring in _rings(b, "points"):
			if ring.size() >= 3:
				draw_colored_polygon(ring, Color("161a1f"))
	for d in Registry.all("district"):
		var id := str(d["id"])
		var known := wm.district_intel(id)
		var col := Color("1b2026") if known == 0 else Color("232a31")
		if level == "district" and id != focus:
			col = col.darkened(0.35)
		if id == cur_d:
			col = col.lerp(AfTheme.ACCENT, 0.12)
		if sel_kind == "district" and sel_id == id:
			col = col.lerp(AfTheme.ACCENT_SOFT, 0.22)
		if level == "republic" and known >= 2:
			col = col.lerp(Color(0.7, 0.15, 0.1), wm.district_density(id) * 0.35)
		for ring in _rings(d):
			if ring.size() >= 3:
				draw_colored_polygon(ring, col)
	for d in Registry.all("district"):
		var focus_line := level == "district" and str(d["id"]) == focus
		for ring in _rings(d):
			var closed: PackedVector2Array = ring.duplicate()
			closed.append(ring[0])
			draw_polyline(closed, Color(1, 1, 1, 0.45 if focus_line else 0.13), px * (2.2 if focus_line else 1.0), true)
	for r in Registry.all("river"):
		for line in _rings(r, "points"):
			draw_polyline(line, Color("2f5a78"), px * (float(r.get("width", 1.2)) * (0.6 if level == "republic" else 1.1)), true)
	for road in Registry.all("road"):
		if road.get("hidden", false) or road.has("city"):
			continue
		var fed := str(road.get("class", "")) == "federal"
		if level == "republic" and not fed and _zoom < 1.6:
			continue
		for line in _rings(road, "points"):
			draw_polyline(line, Color("8a7a5a") if fed else Color("5d564a"), px * (2.2 if fed else 1.2), true)
	# travel links from the current settlement
	if level == "district":
		var a := Registry.get_def("region", wm.current_region)
		if not a.is_empty():
			var pa := to_map(float(a["lat"]), float(a["lon"]))
			for n in wm.neighbors(wm.current_region):
				var b := Registry.get_def("region", n)
				draw_dashed_line(pa, to_map(float(b["lat"]), float(b["lon"])), Color(AfTheme.ACCENT, 0.55), px * 1.5, px * 6.0)
	# settlements
	for r in Registry.all("region"):
		var id := str(r["id"])
		var in_focus := level == "district" and str(r.get("district", "")) == focus
		var kind := str(r["kind"])
		if level == "republic" and kind == "village" and id != wm.current_region and _zoom < 2.2:
			continue
		var pos := to_map(float(r["lat"]), float(r["lon"]))
		var lvl := wm.intel(id)
		var col: Color = KIND_COLORS.get(kind, Color.WHITE)
		if lvl == 0:
			col = Color(col, 0.35)
		if level == "district" and not in_focus:
			col = Color(col, 0.25)
		var rad: float = px * float({"city": 7.0, "town": 5.0}.get(kind, 3.5)) * (1.3 if level == "district" else 1.0)
		if lvl >= 2 and (level == "republic" or in_focus):
			draw_circle(pos, rad + px * (4.0 + wm.density(id) * 9.0), Color(0.8, 0.15, 0.1, 0.10 + wm.density(id) * 0.22))
		draw_circle(pos, rad, col)
		if lvl == 3:
			draw_arc(pos, rad + px * 2.5, 0, TAU, 20, Color(AfTheme.GOOD, 0.8), px * 1.4, true)
		if sel_kind == "region" and sel_id == id:
			draw_arc(pos, rad + px * 6.0, 0, TAU, 28, AfTheme.ACCENT_SOFT, px * 2.5, true)
		if id == wm.current_region:
			_marker(pos, rad, px)


func _draw_city_levels(px: float) -> void:
	var wm := Session.world_map
	var city := focus if level == "city" else str(Registry.get_def("city_district", focus).get("city", ""))
	var cur_cd := str(Registry.get_def("place", wm.current_place).get("city_district", ""))
	for cd in Registry.all("city_district"):
		if str(cd.get("city", "")) != city:
			continue
		var id := str(cd["id"])
		var col := Color("1f252b")
		if level == "city_district" and id != focus:
			col = col.darkened(0.4)
		if id == cur_cd and wm.in_city(city):
			col = col.lerp(AfTheme.ACCENT, 0.12)
		if sel_kind == "city_district" and sel_id == id:
			col = col.lerp(AfTheme.ACCENT_SOFT, 0.22)
		for ring in _rings(cd):
			if ring.size() >= 3:
				draw_colored_polygon(ring, col)
		for ring in _rings(cd):
			var closed: PackedVector2Array = ring.duplicate()
			closed.append(ring[0])
			var strong := level == "city_district" and id == focus
			draw_polyline(closed, Color(1, 1, 1, 0.5 if strong else 0.18), px * (2.2 if strong else 1.2), true)
	for r in Registry.all("river"):
		for line in _rings(r, "points"):
			draw_polyline(line, Color("2f5a78"), px * float(r.get("width", 1.2)) * 1.6, true)
	for road in Registry.all("road"):
		if str(road.get("city", "")) != city:
			continue
		var avenue := str(road.get("class", "")) == "avenue"
		for line in _rings(road, "points"):
			draw_polyline(line, Color("6a6255") if avenue else Color("4a463f"), px * (2.0 if avenue else 1.1), true)
	for p in Registry.all("place"):
		if str(p.get("city", "")) != city:
			continue
		var in_focus := level == "city" or str(p["city_district"]) == focus
		var pos := to_map(float(p["lat"]), float(p["lon"]))
		var col: Color = PLACE_COLORS.get(str(p["type"]), Color.WHITE)
		var rad := px * (2.5 if level == "city" else 6.0)
		if not in_focus:
			col = Color(col, 0.2)
		draw_circle(pos, rad, col)
		if level == "city_district" and in_focus:
			draw_arc(pos, rad, 0, TAU, 20, Color(0, 0, 0, 0.6), px * 1.2, true)
		if sel_kind == "place" and sel_id == str(p["id"]):
			draw_arc(pos, rad + px * 6.0, 0, TAU, 28, AfTheme.ACCENT_SOFT, px * 2.5, true)
		if str(p["id"]) == wm.current_place and wm.in_city(city):
			_marker(pos, rad, px)


func _marker(pos: Vector2, rad: float, px: float) -> void:
	var tri := PackedVector2Array([pos + Vector2(0, -rad - px * 4), pos + Vector2(-px * 8, -rad - px * 18), pos + Vector2(px * 8, -rad - px * 18)])
	draw_colored_polygon(tri, AfTheme.ACCENT)


func _draw_labels() -> void:
	var font := get_theme_default_font()
	var wm := Session.world_map
	match level:
		"republic":
			for r in Registry.all("region"):
				var k := str(r["kind"])
				if k in ["city", "town"] or str(r["id"]) == wm.current_region:
					_label(font, screen_of(float(r["lat"]), float(r["lon"])) + Vector2(8, 5), str(r["name"]), 15 if k == "city" else 12, Color(KIND_COLORS.get(k, Color.WHITE), 0.85))
			for d in Registry.all("district"):
				if d["kind"] == "district":
					var c: Array = d["center"]
					var nm := str(d["name"]).replace(" район", "")
					_label(font, screen_of(float(c[0]), float(c[1])) - Vector2(font.get_string_size(nm, 0, -1, 11).x / 2.0, 0), nm, 11, Color(1, 1, 1, 0.32))
		"district":
			var regs := Registry.all("region").duplicate()
			regs.sort_custom(func(a, b): return int(a.get("population", 0)) > int(b.get("population", 0)))
			for r in regs:
				var in_focus := str(r.get("district", "")) == focus
				if not in_focus and str(r["kind"]) == "village":
					continue
				var k := str(r["kind"])
				_label(font, screen_of(float(r["lat"]), float(r["lon"])) + Vector2(9, 5), str(r["name"]), 15 if k == "city" else 13, Color(KIND_COLORS.get(k, Color.WHITE), 0.9 if in_focus else 0.35))
		"city":
			for cd in Registry.all("city_district"):
				if str(cd.get("city", "")) == focus:
					var c: Array = cd["center"]
					var nm := str(cd["name"])
					_label(font, screen_of(float(c[0]), float(c[1])) - Vector2(font.get_string_size(nm, 0, -1, 15).x / 2.0, 0), nm, 15, Color(1, 1, 1, 0.75))
		"city_district":
			for p in Registry.all("place"):
				if str(p.get("city_district", "")) == focus:
					_label(font, screen_of(float(p["lat"]), float(p["lon"])) + Vector2(10, 5), str(p["name"]), 13, Color(PLACE_COLORS.get(str(p["type"]), Color.WHITE), 0.95))


func _label(font: Font, at: Vector2, text: String, fs: int, col: Color) -> void:
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var rect := Rect2(at - Vector2(0, sz.y * 0.8), sz)
	if not Rect2(Vector2.ZERO, size).intersects(rect):
		return
	for r in _label_rects:
		if r.intersects(rect):
			return
	_label_rects.append(rect)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.75))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


# --- input ----------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(1.15, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(1.0 / 1.15, event.position)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_moved = 0.0
			if _touches.size() == 2:
				var pts := _touches.values()
				_pinch_d = (pts[0] as Vector2).distance_to(pts[1])
				_pinch_z = _zoom
		else:
			if _touches.size() == 1 and _moved < 14.0:
				_tap(event.position)
			_touches.erase(event.index)
		accept_event()
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_pan += event.relative
			_moved += event.relative.length()
		elif _touches.size() == 2 and _pinch_d > 10.0:
			var pts := _touches.values()
			var mid: Vector2 = ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5
			var nz := clampf(_pinch_z * (pts[0] as Vector2).distance_to(pts[1]) / _pinch_d, 0.6, 12.0)
			_zoom_at(nz / _zoom, mid)
			_moved = 99.0
		queue_redraw()
		accept_event()


func _zoom_at(factor: float, at: Vector2) -> void:
	var before := (at - _offset()) / _scale()
	_zoom = clampf(_zoom * factor, 0.6, 12.0)
	_pan += at - to_screen(before)
	queue_redraw()


func _tap(at: Vector2) -> void:
	var m := (at - _offset()) / _scale()
	match level:
		"republic":
			var r := _nearest_region(at, 22.0, true)
			if r != "":
				select("region", r)
				return
			var d := _polygon_at(m, "district", "")
			if d != "":
				select("district", d)
		"district":
			var r2 := _nearest_region(at, 30.0, false)
			if r2 != "":
				select("region", r2)
				return
			var d2 := _polygon_at(m, "district", "")
			if d2 != "":
				select("district", d2)
		"city":
			var cd := _polygon_at(m, "city_district", focus)
			if cd != "":
				select("city_district", cd)
		"city_district":
			var best := ""
			var bd := 34.0
			for p in Registry.all("place"):
				if str(p.get("city_district", "")) != focus:
					continue
				var dd := screen_of(float(p["lat"]), float(p["lon"])).distance_to(at)
				if dd < bd:
					bd = dd
					best = str(p["id"])
			if best != "":
				select("place", best)
				return
			var cd2 := _polygon_at(m, "city_district", str(Registry.get_def("city_district", focus).get("city", "")))
			if cd2 != "":
				select("city_district", cd2)


func _nearest_region(at: Vector2, max_px: float, towns_only: bool) -> String:
	var best := ""
	var bd := max_px
	for r in Registry.all("region"):
		if towns_only and str(r["kind"]) == "village" and str(r["id"]) != Session.world_map.current_region and _zoom < 2.2:
			continue
		if level == "district" and str(r.get("district", "")) != focus and str(r["kind"]) == "village":
			continue
		var d := screen_of(float(r["lat"]), float(r["lon"])).distance_to(at)
		if d < bd:
			bd = d
			best = str(r["id"])
	return best


func _polygon_at(m: Vector2, kind: String, city: String) -> String:
	for d in Registry.all(kind):
		if city != "" and str(d.get("city", "")) != city:
			continue
		for ring in _rings(d):
			if ring.size() >= 3 and Geometry2D.is_point_in_polygon(m, ring):
				return str(d["id"])
	return ""
