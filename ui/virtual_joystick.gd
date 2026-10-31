class_name AfJoystick
extends Control
## Floating virtual joystick for touch. Tracks one touch index; mouse works
## too through touch emulation. `output` is a Vector2 in [-1, 1].

var output := Vector2.ZERO
var radius := 90.0
var _touch := -1
var _origin := Vector2.ZERO
var _knob := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _touch == -1:
			_touch = event.index
			_origin = event.position
			_knob = _origin
			accept_event()
		elif not event.pressed and event.index == _touch:
			_touch = -1
			output = Vector2.ZERO
			accept_event()
		queue_redraw()
	elif event is InputEventScreenDrag and event.index == _touch:
		var d: Vector2 = event.position - _origin
		if d.length() > radius:
			d = d.normalized() * radius
		_knob = _origin + d
		output = d / radius
		if output.length() < 0.12:
			output = Vector2.ZERO
		accept_event()
		queue_redraw()


func _draw() -> void:
	var center := _origin if _touch != -1 else Vector2(radius + 30, size.y - radius - 30)
	var knob := _knob if _touch != -1 else center
	draw_circle(center, radius, Color(1, 1, 1, 0.06))
	draw_arc(center, radius, 0, TAU, 48, Color(1, 1, 1, 0.18), 2.0, true)
	draw_circle(knob, 34, Color(AfTheme.ACCENT, 0.55 if _touch != -1 else 0.25))
