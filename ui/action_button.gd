class_name AfActionButton
extends Control
## Round multi-touch action button for the HUD. Reacts to InputEventScreenTouch
## per touch index, so it works while another finger holds the joystick
## (regular Buttons only see the single emulated mouse pointer).

signal pressed
signal released

var text := ""
var sub := ""
var toggled_on := false
var is_toggle := false
var enabled := true
var accent := AfTheme.ACCENT
var progress := -1.0   # 0..1 draws a cooldown/reload ring
var _touch := -1


func setup(p_text: String, p_size: float = 92.0, p_toggle: bool = false) -> AfActionButton:
	text = p_text
	is_toggle = p_toggle
	custom_minimum_size = Vector2(p_size, p_size)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	return self


func _gui_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		if event.pressed and _touch == -1:
			_touch = event.index
			if is_toggle:
				toggled_on = not toggled_on
			pressed.emit()
			accept_event()
			queue_redraw()
		elif not event.pressed and event.index == _touch:
			_touch = -1
			released.emit()
			accept_event()
			queue_redraw()


func is_held() -> bool:
	return _touch != -1


func _draw() -> void:
	var r := minf(size.x, size.y) * 0.5
	var c := size * 0.5
	var active := _touch != -1 or toggled_on
	var bg := Color(accent, 0.55) if active else Color(0.08, 0.085, 0.095, 0.72)
	if not enabled:
		bg = Color(0.08, 0.085, 0.095, 0.35)
	draw_circle(c, r, bg)
	draw_arc(c, r - 1, 0, TAU, 48, Color(accent, 0.8 if active else 0.35), 2.0, true)
	if progress >= 0.0 and progress < 1.0:
		draw_arc(c, r - 5, -PI / 2, -PI / 2 + TAU * progress, 48, Color(1, 1, 1, 0.8), 4.0, true)
	var font := get_theme_default_font()
	var fs := int(r * 0.42) if text.length() <= 2 else int(r * 0.3)
	var col := Color(1, 1, 1, 0.95 if enabled else 0.35)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
	draw_string(font, Vector2(c.x - tw / 2.0, c.y + fs * 0.35 - (6 if sub != "" else 0)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	if sub != "":
		var ss := int(r * 0.24)
		var sw := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_CENTER, -1, ss).x
		draw_string(font, Vector2(c.x - sw / 2.0, c.y + fs * 0.35 + ss + 2), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, ss, Color(col, 0.75))
