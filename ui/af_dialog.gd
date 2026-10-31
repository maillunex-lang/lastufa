class_name AfDialog
extends Control
## Modal message / decision dialog. Freezes game time while open.
## Usage: AfDialog.show_in(parent, "Заголовок", "Текст", [["OK", cb], ...])

var _box: VBoxContainer


static func show_in(parent: Node, p_title: String, text: String, buttons: Array = [], lines: Array = []) -> AfDialog:
	var d := AfDialog.new()
	d._build(p_title, text, buttons, lines)
	parent.add_child(d)
	return d


func _build(p_title: String, text: String, buttons: Array, lines: Array) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = AfTheme.get_theme()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(620, 0)
	center.add_child(frame)
	_box = AfUI.vbox(12)
	frame.add_child(_box)
	_box.add_child(AfUI.label(p_title, 26, AfTheme.ACCENT_SOFT))
	if text != "":
		var l := AfUI.label(text, 19, AfTheme.TEXT, true)
		l.custom_minimum_size = Vector2(580, 0)
		_box.add_child(l)
	if not lines.is_empty():
		var list := AfUI.vbox(4)
		for line in lines:
			var l := AfUI.label("• " + str(line), 17, AfTheme.TEXT_DIM, true)
			l.custom_minimum_size = Vector2(560, 0)
			list.add_child(l)
		var sc := AfUI.scroll(list)
		sc.custom_minimum_size = Vector2(580, mini(320, 28 * lines.size() + 10))
		_box.add_child(sc)
	if buttons.is_empty():
		buttons = [["Понятно", Callable()]]
	# 3+ options = a decision: stacked, none highlighted (no "right answer" hint)
	var decision := buttons.size() >= 3
	var row: BoxContainer = AfUI.vbox(8) if decision else AfUI.hbox(10)
	if not decision:
		(row as HBoxContainer).alignment = BoxContainer.ALIGNMENT_END
	_box.add_child(row)
	for i in buttons.size():
		var spec: Array = buttons[i]
		var cb: Callable = spec[1] if spec.size() > 1 else Callable()
		var handler := func():
			queue_free()
			if cb.is_valid():
				cb.call()
		if decision:
			row.add_child(AfUI.button(spec[0], handler))
		else:
			row.add_child(AfUI.accent_button(spec[0], handler, 160) if i == buttons.size() - 1 else AfUI.button(spec[0], handler, 160))


func _enter_tree() -> void:
	if Session.active:
		Clock.push_pause("dialog:" + str(get_instance_id()))
		EventBus.decision_opened.emit("dialog")


func _exit_tree() -> void:
	Clock.release_pause("dialog:" + str(get_instance_id()))
	EventBus.decision_closed.emit("dialog")
