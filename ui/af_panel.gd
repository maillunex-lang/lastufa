class_name AfPanel
extends Control
## Full-screen modal panel with a title bar. Opening a panel during a session
## pushes a clock pause (panels are "decision moments"); closing releases it.

signal closed

var title := ""
var pauses_time := true
var body: VBoxContainer
var header: HBoxContainer
var _frame: PanelContainer


func _init(p_title: String = "", p_pauses: bool = true) -> void:
	title = p_title
	pauses_time = p_pauses
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = AfTheme.get_theme()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)
	_frame = PanelContainer.new()
	margin.add_child(_frame)
	var outer := AfUI.vbox(12)
	_frame.add_child(outer)
	header = AfUI.hbox(12)
	outer.add_child(header)
	var t := AfUI.label(title, 26, AfTheme.ACCENT_SOFT)
	header.add_child(t)
	header.add_child(AfUI.spacer())
	header.add_child(AfUI.button("✕  Закрыть", close, 150))
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", AfTheme.LINE)
	outer.add_child(sep)
	body = AfUI.vbox(10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)


func _enter_tree() -> void:
	if pauses_time and Session.active:
		Clock.push_pause("panel:" + str(get_instance_id()))


func _exit_tree() -> void:
	Clock.release_pause("panel:" + str(get_instance_id()))


func close() -> void:
	closed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		get_viewport().set_input_as_handled()
		close()
