class_name AfScroll
extends ScrollContainer
## ScrollContainer that can be dragged by a finger anywhere — also on top of
## buttons and cards. Children that would swallow the touch (MOUSE_FILTER_STOP)
## are switched to MOUSE_FILTER_PASS, so the drag reaches this container; a
## drag beyond the deadzone scrolls and does NOT press the button under the
## finger, while a short tap still presses it (verified on a real renderer).


func _init() -> void:
	scroll_deadzone = 12
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED


func _enter_tree() -> void:
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	_pass_through(self)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n is Control and is_ancestor_of(n):
		_fix(n)


func _pass_through(root: Node) -> void:
	for c in root.get_children():
		if c is Control:
			_fix(c)
		_pass_through(c)


func _fix(c: Control) -> void:
	if c.mouse_filter == Control.MOUSE_FILTER_STOP and not (c is ScrollBar) and not (c is LineEdit):
		c.mouse_filter = Control.MOUSE_FILTER_PASS
