class_name AfTheme
extends RefCounted
## Visual language: dark ash panels, ember accent, generous touch targets.

const BG := Color("14161a")
const PANEL := Color(0.075, 0.08, 0.09, 0.94)
const PANEL_SOFT := Color(0.11, 0.115, 0.13, 0.92)
const LINE := Color(1, 1, 1, 0.07)
const TEXT := Color("e6e1d8")
const TEXT_DIM := Color("9c978d")
const ACCENT := Color("d98a3a")
const ACCENT_SOFT := Color("f2c27b")
const GOOD := Color("7fb069")
const WARN := Color("e0b54a")
const DANGER := Color("d0473e")
const INFO := Color("6fa3c7")

const MIN_TOUCH := 56

static var _theme: Theme


static func get_theme() -> Theme:
	if _theme == null:
		_theme = _build()
	return _theme


static func box(bg: Color, radius: int = 12, border: Color = Color(0, 0, 0, 0), margin: int = 14) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	if border.a > 0.0:
		s.set_border_width_all(1)
		s.border_color = border
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.7
	s.content_margin_bottom = margin * 0.7
	s.anti_aliasing = true
	return s


static func _build() -> Theme:
	var th := Theme.new()
	th.default_font_size = 19
	th.set_color("font_color", "Label", TEXT)
	th.set_stylebox("panel", "PanelContainer", box(PANEL, 16, LINE, 18))
	th.set_stylebox("panel", "Panel", box(PANEL, 16, LINE, 18))
	# buttons
	th.set_stylebox("normal", "Button", box(Color(0.15, 0.16, 0.18), 10, LINE))
	th.set_stylebox("hover", "Button", box(Color(0.2, 0.21, 0.24), 10, LINE))
	th.set_stylebox("pressed", "Button", box(ACCENT.darkened(0.45), 10, ACCENT.darkened(0.2)))
	th.set_stylebox("hover_pressed", "Button", box(ACCENT.darkened(0.4), 10, ACCENT.darkened(0.2)))
	th.set_stylebox("disabled", "Button", box(Color(0.11, 0.115, 0.125), 10))
	th.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), 10, ACCENT.darkened(0.3)))
	th.set_color("font_color", "Button", TEXT)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", ACCENT_SOFT)
	th.set_color("font_disabled_color", "Button", TEXT_DIM.darkened(0.3))
	# progress bars
	th.set_stylebox("background", "ProgressBar", box(Color(1, 1, 1, 0.07), 6, Color(0, 0, 0, 0), 0))
	th.set_stylebox("fill", "ProgressBar", box(ACCENT, 6, Color(0, 0, 0, 0), 0))
	th.set_color("font_color", "ProgressBar", TEXT)
	# inputs
	th.set_stylebox("normal", "LineEdit", box(Color(0.1, 0.105, 0.12), 8, LINE))
	th.set_stylebox("focus", "LineEdit", box(Color(0.1, 0.105, 0.12), 8, ACCENT.darkened(0.2)))
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_stylebox("normal", "OptionButton", box(Color(0.15, 0.16, 0.18), 10, LINE))
	th.set_stylebox("hover", "OptionButton", box(Color(0.2, 0.21, 0.24), 10, LINE))
	th.set_stylebox("pressed", "OptionButton", box(Color(0.2, 0.21, 0.24), 10, LINE))
	th.set_stylebox("panel", "PopupMenu", box(PANEL, 10, LINE, 10))
	th.set_constant("separation", "VBoxContainer", 8)
	th.set_constant("separation", "HBoxContainer", 8)
	th.set_stylebox("panel", "TooltipPanel", box(PANEL, 8, LINE, 8))
	th.set_stylebox("grabber_area", "VScrollBar", box(ACCENT.darkened(0.3), 4, Color(0, 0, 0, 0), 0))
	th.set_stylebox("grabber", "VScrollBar", box(Color(1, 1, 1, 0.2), 4, Color(0, 0, 0, 0), 0))
	th.set_stylebox("scroll", "VScrollBar", box(Color(1, 1, 1, 0.03), 4, Color(0, 0, 0, 0), 0))
	return th


static func kind_color(kind: String) -> Color:
	match kind:
		"good": return GOOD
		"warn": return WARN
		"danger": return DANGER
	return INFO
