class_name AfResidentNpc
extends Node3D
## A resident walking around the base: goes to their workplace, idles there,
## shows name and job above the head, can be talked to.

var sid := 0
var target := Vector3.ZERO
var _visual: Node3D
var _label: Label3D
var _t := 0.0
var _idle_offset := Vector3.ZERO
var _idle_t := 0.0


func setup(p: Dictionary) -> void:
	sid = int(p["id"])
	_visual = Node3D.new()
	add_child(_visual)
	var palette := [Color("6a7f5a"), Color("7a5a4a"), Color("4f6a8a"), Color("8a7a4a"), Color("5a5a6a"), Color("8a5a6a")]
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.3
	cm.height = 1.45
	body.mesh = cm
	body.material_override = AfLocationBuilder.mat(palette[sid % palette.size()], 0.8)
	body.position = Vector3(0, 0.75, 0)
	_visual.add_child(body)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.19
	sm.height = 0.38
	head.mesh = sm
	head.material_override = AfLocationBuilder.mat(Color("c9a487"))
	head.position = Vector3(0, 1.6, 0)
	_visual.add_child(head)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 34
	_label.pixel_size = 0.01
	_label.outline_size = 8
	_label.position = Vector3(0, 2.25, 0)
	_label.modulate = Color("d8e6c8")
	add_child(_label)
	refresh(p)


func refresh(p: Dictionary) -> void:
	var first := str(p["name"]).get_slice(" ", 0)
	_label.text = "%s · %s" % [first, AfSurvivors.JOBS.get(str(p["job"]), str(p["job"])).to_lower()]
	_label.modulate = Color("e08a6a") if float(p["injury_hours"]) > 0.0 or float(p.get("infected_hours", -1.0)) >= 0.0 else Color("d8e6c8")


func _process(delta: float) -> void:
	_t += delta
	_idle_t -= delta
	if _idle_t <= 0.0:
		_idle_t = randf_range(3.0, 7.0)
		_idle_offset = Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2))
	var goal := target + _idle_offset
	var to := goal - position
	to.y = 0.0
	var speed := 1.6 if to.length() > 4.0 else 0.7
	if to.length() > 0.3:
		position += to.normalized() * minf(speed * delta, to.length())
		_visual.rotation.y = lerp_angle(_visual.rotation.y, atan2(to.x, to.z), 0.15)
		_visual.position.y = absf(sin(_t * 8.0)) * 0.05
	else:
		_visual.position.y = 0.0
		_visual.rotation.x = sin(_t * 2.0 + sid) * 0.04
