class_name AfMapView
extends Control
## Strategic map of Bashkortostan drawn from data: border, rivers, roads and
## region nodes, with fog of war (intel levels). Pan by drag, zoom by pinch
## or wheel; tap a node to select it.

signal region_selected(id: String)

var selected := ""
var _bounds := Rect2()
var _zoom := 1.0
var _pan := Vector2.ZERO
var _touches := {}
var _pinch_d := 0.0
var _pinch_z := 1.0
var _drag_moved := 0.0

const KIND_COLORS := {
	"city": Color("e6e1d8"), "town": Color("c9c3b6"), "village": Color("a8b08f"), "industrial": Color("c9a050"),
	"military": Color("d0473e"), "lab": Color("9f8fd0"), "infrastructure": Color("6fa3c7"), "nature": Color("7fb069"),
}


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_compute_bounds()


func _compute_bounds() -> void:
	var pts := []
	for b in Registry.all("border"):
		pts.append_array(b["points"])
	if pts.is_empty():
		for r in Registry.all("region"):
			pts.append([r["lat"], r["lon"]])
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for p in pts:
		var v := Vector2(float(p[1]), float(p[0]))
		minp = minp.min(v)
		maxp = maxp.max(v)
	_bounds = Rect2(minp, maxp - minp).grow(0.15)


## lat/lon -> local pixels. Longitude is scaled by cos(latitude) to keep shapes.
func project(lat: float, lon: float) -> Vector2:
	var k := cos(deg_to_rad(54.5))
	var w := _bounds.size.x * k
	var h := _bounds.size.y
	var scale := minf(size.x / w, size.y / h) * _zoom
	var center := size * 0.5 + _pan
	var mid := _bounds.get_center()
	return center + Vector2((lon - mid.x) * k * scale, -(lat - mid.y) * scale)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("101318"))
	var wm := Session.world_map
	for b in Registry.all("border"):
		var poly := PackedVector2Array()
		for p in b["points"]:
			poly.append(project(float(p[0]), float(p[1])))
		if poly.size() >= 3:
			draw_colored_polygon(poly, Color("1a1f24"))
			poly.append(poly[0])
			draw_polyline(poly, Color(1, 1, 1, 0.18), 2.0, true)
	for r in Registry.all("river"):
		var line := PackedVector2Array()
		for p in r["points"]:
			line.append(project(float(p[0]), float(p[1])))
		draw_polyline(line, Color("2f5a78"), float(r.get("width", 1.5)) * _zoom + 1.0, true)
	for road in Registry.all("road"):
		var line := PackedVector2Array()
		for p in road["points"]:
			line.append(project(float(p[0]), float(p[1])))
		var col := Color("8a7a5a") if road.get("class") == "federal" else Color("5a5448")
		draw_polyline(line, col, 2.5 if road.get("class") == "federal" else 1.5, true)
	var font := get_theme_default_font()
	var cur := wm.current_region
	for r in Registry.all("region"):
		var id := str(r["id"])
		var pos := project(float(r["lat"]), float(r["lon"]))
		var lvl := wm.intel(id)
		var col: Color = KIND_COLORS.get(str(r["kind"]), Color.WHITE)
		if lvl == 0:
			col = Color(col, 0.28)
		var rad := (9.0 if r["kind"] == "city" else 6.0) * clampf(_zoom, 0.8, 1.6)
		if lvl >= 2:
			var d := wm.density(id)
			draw_circle(pos, rad + 6.0 + d * 10.0, Color(0.8, 0.15, 0.1, 0.12 + d * 0.25))
		draw_circle(pos, rad, col)
		if lvl == 3:
			draw_arc(pos, rad + 3.0, 0, TAU, 24, Color(AfTheme.GOOD, 0.8), 1.5, true)
		if id == selected:
			draw_arc(pos, rad + 7.0, 0, TAU, 32, AfTheme.ACCENT_SOFT, 2.5, true)
		if id == cur:
			var tri := PackedVector2Array([pos + Vector2(0, -rad - 6), pos + Vector2(-8, -rad - 20), pos + Vector2(8, -rad - 20)])
			draw_colored_polygon(tri, AfTheme.ACCENT)
		var fs := 15 if r["kind"] == "city" else 13
		if lvl > 0 or _zoom > 1.3:
			draw_string(font, pos + Vector2(rad + 4, 5), str(r["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, maxf(col.a, 0.6)))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * 1.15, 0.7, 4.0)
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom / 1.15, 0.7, 4.0)
			queue_redraw()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			_drag_moved = 0.0
			if _touches.size() == 2:
				var pts := _touches.values()
				_pinch_d = (pts[0] as Vector2).distance_to(pts[1])
				_pinch_z = _zoom
		else:
			if _touches.size() == 1 and _drag_moved < 12.0:
				_tap(event.position)
			_touches.erase(event.index)
		accept_event()
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_pan += event.relative
			_drag_moved += event.relative.length()
		elif _touches.size() == 2 and _pinch_d > 10.0:
			var pts := _touches.values()
			_zoom = clampf(_pinch_z * (pts[0] as Vector2).distance_to(pts[1]) / _pinch_d, 0.7, 4.0)
			_drag_moved = 99.0
		queue_redraw()
		accept_event()


func _tap(at: Vector2) -> void:
	var best := ""
	var bd := 34.0
	for r in Registry.all("region"):
		var d := project(float(r["lat"]), float(r["lon"])).distance_to(at)
		if d < bd:
			bd = d
			best = str(r["id"])
	if best != "":
		selected = best
		region_selected.emit(best)
		queue_redraw()


func center_on(id: String) -> void:
	var r := Registry.get_def("region", id)
	if r.is_empty():
		return
	_pan = Vector2.ZERO
	var p := project(float(r["lat"]), float(r["lon"]))
	_pan = size * 0.5 - p
	queue_redraw()
