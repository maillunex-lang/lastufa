class_name AfIsoCamera
extends Node3D
## Isometric orthographic camera rig: smooth follow, zoom (wheel / pinch /
## keys), screen shake and fading of buildings that hide the hero.

const MIN_ZOOM := 12.0
const MAX_ZOOM := 42.0

var target: Node3D
var camera: Camera3D
var zoom := 22.0
var _shake := 0.0
var _touches := {}
var _pinch_start_dist := 0.0
var _pinch_start_zoom := 0.0
var _fade_t := 0.0
var _faded := {}   # MeshInstance3D -> true
var _ray := PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	rotation_degrees = Vector3(0, 45, 0)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.rotation_degrees = Vector3(-35.264, 0, 0)
	camera.position = Vector3(0, 0, 0) + Vector3(0, 0, 70).rotated(Vector3.RIGHT, deg_to_rad(-35.264))
	camera.far = 200.0
	camera.near = 0.5
	add_child(camera)
	zoom = float(Settings.get_value("game/camera_zoom"))
	camera.size = zoom
	camera.current = true
	_ray.collision_mask = AfLocationBuilder.LAYER_WORLD


func _process(delta: float) -> void:
	if target:
		global_position = global_position.lerp(target.global_position, 1.0 - exp(-delta * 8.0))
	camera.size = lerpf(camera.size, zoom, 1.0 - exp(-delta * 10.0))
	if Input.is_action_pressed("zoom_in"):
		set_zoom(zoom - 20.0 * delta)
	if Input.is_action_pressed("zoom_out"):
		set_zoom(zoom + 20.0 * delta)
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta)
		camera.h_offset = randf_range(-1, 1) * _shake * 1.2
		camera.v_offset = randf_range(-1, 1) * _shake * 1.2
	else:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	_fade_t -= delta
	if _fade_t <= 0.0 and target:
		_fade_t = 0.15
		_update_fade()


func set_zoom(z: float) -> void:
	zoom = clampf(z, MIN_ZOOM, MAX_ZOOM)


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_zoom(zoom - 1.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_zoom(zoom + 1.5)
	elif event is InputEventMagnifyGesture:
		set_zoom(zoom / event.factor)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() == 2:
			var pts := _touches.values()
			_pinch_start_dist = (pts[0] as Vector2).distance_to(pts[1])
			_pinch_start_zoom = zoom
	elif event is InputEventScreenDrag and _touches.has(event.index):
		_touches[event.index] = event.position
		if _touches.size() == 2 and _pinch_start_dist > 10.0:
			var pts := _touches.values()
			var dist := (pts[0] as Vector2).distance_to(pts[1])
			set_zoom(_pinch_start_zoom * _pinch_start_dist / maxf(dist, 1.0))


func _update_fade() -> void:
	var space := get_world_3d().direct_space_state
	var from := target.global_position + Vector3(0, 1.0, 0)
	var to := from + camera.global_basis.z * 80.0
	var hit_now := {}
	var excludes: Array[RID] = []
	for i in 3:
		_ray.from = from
		_ray.to = to
		_ray.exclude = excludes
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			break
		excludes.append(hit["rid"])
		for c in (hit["collider"] as Node).get_children():
			if c is MeshInstance3D and c.has_meta("building_name"):
				hit_now[c] = true
	for mi in hit_now:
		if not _faded.has(mi):
			var m: StandardMaterial3D = mi.material_override
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color.a = 0.28
			_faded[mi] = true
	for mi in _faded.keys():
		if not hit_now.has(mi):
			if is_instance_valid(mi):
				var m: StandardMaterial3D = mi.material_override
				m.albedo_color.a = 1.0
				m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			_faded.erase(mi)
