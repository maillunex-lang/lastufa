class_name AfUI
extends RefCounted
## Small factory helpers so panels stay readable.


static func label(text: String, size: int = 19, color: Color = AfTheme.TEXT, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func button(text: String, cb: Callable = Callable(), min_w: int = 0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, AfTheme.MIN_TOUCH)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func accent_button(text: String, cb: Callable = Callable(), min_w: int = 0) -> Button:
	var b := button(text, cb, min_w)
	b.add_theme_stylebox_override("normal", AfTheme.box(AfTheme.ACCENT.darkened(0.25), 10))
	b.add_theme_stylebox_override("hover", AfTheme.box(AfTheme.ACCENT.darkened(0.1), 10))
	b.add_theme_color_override("font_color", Color("1a1410"))
	b.add_theme_color_override("font_hover_color", Color("1a1410"))
	return b


static func hbox(sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func vbox(sep: int = 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


static func bar(value: float, color: Color, height: int = 10) -> ProgressBar:
	var p := ProgressBar.new()
	p.max_value = 100.0
	p.value = value
	p.show_percentage = false
	p.custom_minimum_size = Vector2(0, height)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("fill", AfTheme.box(color, 5, Color(0, 0, 0, 0), 0))
	return p


static func card(margin: int = 14, bg: Color = AfTheme.PANEL_SOFT) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", AfTheme.box(bg, 12, AfTheme.LINE, margin))
	return p


static func scroll(child: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
	return s


static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


static func eta_text(seconds: float) -> String:
	if seconds < 0.0:
		return "—"
	if seconds < 60.0:
		return "%d с" % int(seconds)
	if seconds < 3600.0:
		return "%d мин %d с" % [int(seconds / 60.0), int(fmod(seconds, 60.0))]
	return "%d ч %d мин" % [int(seconds / 3600.0), int(fmod(seconds, 3600.0) / 60.0)]
