class_name AfHud
extends Control
## In-location HUD: time & weather, speed control, vital signs, threat,
## notifications, joystick and action buttons, panel shortcuts.

var world: AfGameWorld
var joystick: AfJoystick
var _time_lbl: Label
var _weather_lbl: Label
var _region_lbl: Label
var _bars := {}
var _status_lbl: Label
var _threat_lbl: Label
var _prompt: Button
var _notes: VBoxContainer
var _fps_lbl: Label
var _speed_btns: Array[Button] = []
var _btn_attack: AfActionButton
var _btn_fire: AfActionButton
var _btn_reload: AfActionButton
var _btn_sprint: AfActionButton
var _btn_sneak: AfActionButton
var _btn_light: AfActionButton
var _hurt: ColorRect
var _t := 0.0


func _init() -> void:
	# anchors must be set before entering the tree (parent is a CanvasLayer)
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = AfTheme.get_theme()
	_build()
	EventBus.notify.connect(_on_notify)
	EventBus.journal_entry.connect(_on_journal)
	world.player.hit_taken.connect(_on_hit)
	world.player.interact_target_changed.connect(_on_prompt)
	_refresh()


func _exit_tree() -> void:
	if EventBus.notify.is_connected(_on_notify):
		EventBus.notify.disconnect(_on_notify)
	if EventBus.journal_entry.is_connected(_on_journal):
		EventBus.journal_entry.disconnect(_on_journal)


func _build() -> void:
	_hurt = ColorRect.new()
	_hurt.color = Color(0.6, 0.0, 0.0, 0.0)
	_hurt.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hurt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hurt)
	joystick = AfJoystick.new()
	joystick.anchor_top = 0.35
	joystick.anchor_bottom = 1.0
	joystick.anchor_right = 0.42
	add_child(joystick)
	# --- top-left: clock
	var tl := AfUI.card(12, Color(0.06, 0.065, 0.075, 0.82))
	tl.position = Vector2(16, 12)
	add_child(tl)
	var tlv := AfUI.vbox(2)
	tl.add_child(tlv)
	var trow := AfUI.hbox(10)
	tlv.add_child(trow)
	_time_lbl = AfUI.label("", 24, AfTheme.TEXT)
	trow.add_child(_time_lbl)
	for i in 4:
		var b := AfUI.button(["❚❚", "1×", "2×", "4×"][i], _on_speed.bind(i), 52)
		b.custom_minimum_size = Vector2(52, 44)
		b.toggle_mode = true
		trow.add_child(b)
		_speed_btns.append(b)
	_weather_lbl = AfUI.label("", 16, AfTheme.TEXT_DIM)
	tlv.add_child(_weather_lbl)
	_region_lbl = AfUI.label("", 15, AfTheme.TEXT_DIM)
	tlv.add_child(_region_lbl)
	# --- left: vitals
	var vit := AfUI.card(12, Color(0.06, 0.065, 0.075, 0.78))
	vit.position = Vector2(16, 140)
	vit.custom_minimum_size = Vector2(230, 0)
	add_child(vit)
	var vv := AfUI.vbox(4)
	vit.add_child(vv)
	for spec in [["health", "Здоровье", AfTheme.DANGER], ["satiety", "Сытость", Color("c9a050")], ["hydration", "Вода", AfTheme.INFO],
			["energy", "Энергия", Color("9f8fd0")], ["stamina", "Выносливость", AfTheme.GOOD], ["stress", "Стресс", Color("b06a8a")]]:
		var row := AfUI.hbox(6)
		var l := AfUI.label(spec[1], 14, AfTheme.TEXT_DIM)
		l.custom_minimum_size = Vector2(96, 0)
		row.add_child(l)
		var b := AfUI.bar(100, spec[2], 9)
		b.custom_minimum_size = Vector2(110, 9)
		row.add_child(b)
		vv.add_child(row)
		_bars[spec[0]] = b
	_status_lbl = AfUI.label("", 14, AfTheme.WARN, true)
	_status_lbl.custom_minimum_size = Vector2(206, 0)
	vv.add_child(_status_lbl)
	# --- top-right: panels
	var tr := AfUI.hbox(8)
	tr.anchor_left = 1.0
	tr.anchor_right = 1.0
	tr.offset_left = -560
	tr.offset_right = -16
	tr.offset_top = 12
	tr.alignment = BoxContainer.ALIGNMENT_END
	add_child(tr)
	for spec in [["Инвентарь", open_inventory], ["Персонаж", open_character], ["Карта", open_map], ["Меню", open_menu]]:
		tr.add_child(AfUI.button(spec[0], spec[1], 120))
	_fps_lbl = AfUI.label("", 13, AfTheme.TEXT_DIM)
	_fps_lbl.anchor_left = 1.0
	_fps_lbl.anchor_right = 1.0
	_fps_lbl.offset_left = -700
	_fps_lbl.offset_right = -16
	_fps_lbl.offset_top = 76
	_fps_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_fps_lbl)
	# --- threat + notifications
	_threat_lbl = AfUI.label("", 20, AfTheme.DANGER)
	_threat_lbl.anchor_left = 0.5
	_threat_lbl.anchor_right = 0.5
	_threat_lbl.offset_left = -200
	_threat_lbl.offset_right = 200
	_threat_lbl.offset_top = 14
	_threat_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_threat_lbl)
	_notes = AfUI.vbox(6)
	_notes.anchor_left = 0.5
	_notes.anchor_right = 0.5
	_notes.offset_left = -260
	_notes.offset_right = 260
	_notes.offset_top = 52
	_notes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_notes)
	_prompt = AfUI.accent_button("", func(): world.player.interact())
	_prompt.anchor_left = 0.5
	_prompt.anchor_right = 0.5
	_prompt.anchor_top = 1.0
	_prompt.anchor_bottom = 1.0
	_prompt.offset_left = -260
	_prompt.offset_right = 260
	_prompt.offset_top = -86
	_prompt.offset_bottom = -26
	_prompt.visible = false
	add_child(_prompt)
	# --- bottom-right: actions
	var area := Control.new()
	area.anchor_left = 1.0
	area.anchor_right = 1.0
	area.anchor_top = 1.0
	area.anchor_bottom = 1.0
	area.offset_left = -360
	area.offset_top = -330
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(area)
	_btn_attack = _action(area, "Удар", Vector2(220, 190), 118.0, false)
	_btn_attack.pressed.connect(func(): world.player.melee())
	_btn_fire = _action(area, "Огонь", Vector2(90, 200), 98.0, false)
	_btn_fire.pressed.connect(func(): world.player.fire())
	_btn_reload = _action(area, "R", Vector2(36, 100), 64.0, false)
	_btn_reload.sub = "перез."
	_btn_reload.pressed.connect(func(): world.player.reload())
	_btn_sprint = _action(area, "Бег", Vector2(260, 96), 72.0, true)
	_btn_sprint.pressed.connect(func():
		world.player.sprinting = _btn_sprint.toggled_on
		if _btn_sprint.toggled_on:
			_btn_sneak.toggled_on = false
			world.player.sneaking = false
			_btn_sneak.queue_redraw())
	_btn_sneak = _action(area, "Тихо", Vector2(176, 70), 72.0, true)
	_btn_sneak.pressed.connect(func():
		world.player.sneaking = _btn_sneak.toggled_on
		if _btn_sneak.toggled_on:
			_btn_sprint.toggled_on = false
			world.player.sprinting = false
			_btn_sprint.queue_redraw())
	_btn_light = _action(area, "☼", Vector2(110, 30), 60.0, true)
	_btn_light.sub = "фонарь"
	_btn_light.toggled_on = Session.player.flashlight_on
	_btn_light.pressed.connect(func(): world.player.toggle_flashlight())


func _action(parent: Control, text: String, pos: Vector2, s: float, toggle: bool) -> AfActionButton:
	var b := AfActionButton.new().setup(text, s, toggle)
	b.position = pos
	parent.add_child(b)
	return b


func _process(delta: float) -> void:
	if world.player == null:
		return
	world.player.input_vec = joystick.output
	_t -= delta
	if _t <= 0.0:
		_t = 0.2
		_refresh()
	if _hurt.color.a > 0.0:
		_hurt.color.a = maxf(0.0, _hurt.color.a - delta * 1.2)
	var rp := world.player.reload_progress()
	_btn_reload.progress = rp
	_btn_reload.queue_redraw()
	if Input.is_action_just_pressed("attack"):
		world.player.melee()
	if Input.is_action_just_pressed("fire"):
		world.player.fire()
	if Input.is_action_just_pressed("reload"):
		world.player.reload()
	if Input.is_action_just_pressed("interact"):
		world.player.interact()
	if Input.is_action_just_pressed("flashlight"):
		world.player.toggle_flashlight()
		_btn_light.toggled_on = Session.player.flashlight_on
		_btn_light.queue_redraw()
	if Input.is_action_just_pressed("inventory"):
		open_inventory()
	if Input.is_action_just_pressed("map"):
		open_map()
	if Input.is_action_just_pressed("character"):
		open_character()
	if Input.is_action_just_pressed("speed_pause"):
		_on_speed(0)
	for i in 3:
		if Input.is_action_just_pressed("speed_%d" % (i + 1)):
			_on_speed(i + 1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu") and not _has_modal():
		get_viewport().set_input_as_handled()
		open_menu()


func _has_modal() -> bool:
	for c in get_parent().get_children():
		if c is AfPanel or c is AfDialog:
			return true
	return false


func _refresh() -> void:
	var s := Session.player.survival
	_time_lbl.text = "День %d · %s" % [Clock.day(), Clock.time_text()]
	_weather_lbl.text = "%s · %s · %s" % [Clock.date_text(), Clock.season_name(), Session.weather.label()]
	_region_lbl.text = str(world.loc_def.get("name", ""))
	_bars["health"].value = s.health
	_bars["satiety"].value = s.need("satiety")
	_bars["hydration"].value = s.need("hydration")
	_bars["energy"].value = s.need("energy")
	_bars["stamina"].value = world.player.stamina
	_bars["stress"].value = s.stress
	var st := PackedStringArray()
	var counts := {}
	for inj in s.injuries:
		var key: String = AfSurvival.INJURY_NAMES.get(inj["type"], inj["type"]) + (" (обраб.)" if inj["treated"] else "")
		counts[key] = int(counts.get(key, 0)) + 1
	for key in counts:
		st.append(key + ("" if counts[key] == 1 else " ×%d" % counts[key]))
	st.append_array(s.symptoms())
	if s.body_temp < 35.5 or s.body_temp > 37.5:
		st.append("%.1f °C" % s.body_temp)
	if Session.player.inventory.total_weight() > Session.player.inventory.max_weight * 0.8:
		st.append("Перегруз")
	_status_lbl.text = "\n".join(st)
	var hunting := world.zm.hunting_count() if world.zm else 0
	_threat_lbl.text = ("⚠ Вас преследуют: %d" % hunting) if hunting > 0 else ""
	var paused_user := Clock.has_pause("user")
	for i in _speed_btns.size():
		_speed_btns[i].set_pressed_no_signal((i == 0 and paused_user) or (i > 0 and not paused_user and Clock.speed_index == i - 1))
	var fd := Session.player.equipped_def("firearm")
	if fd.is_empty():
		_btn_fire.enabled = false
		_btn_fire.sub = ""
	else:
		_btn_fire.enabled = true
		var stck := Session.player.equipped_stack("firearm")
		_btn_fire.sub = "%d/%d" % [int(stck.get("ammo", 0)), Session.player.inventory.count(str(fd["weapon"]["ammo"]))]
		if world.player.jammed:
			_btn_fire.sub = "клин!"
	_btn_fire.queue_redraw()
	var md := Session.player.equipped_def("melee")
	_btn_attack.sub = str(md.get("name", "кулаки")).substr(0, 12)
	_btn_attack.queue_redraw()
	_fps_lbl.text = Perf.stats_text() if bool(Settings.get_value("graphics/show_fps")) else ""


func _on_speed(i: int) -> void:
	if i == 0:
		Clock.toggle_user_pause()
	else:
		Clock.release_pause("user")
		Clock.set_speed(i - 1)
	_refresh()


func _on_prompt(text: String) -> void:
	_prompt.text = text
	_prompt.visible = text != ""


func _on_hit(amount: float) -> void:
	_hurt.color.a = clampf(0.15 + amount / 40.0, 0.15, 0.5)


func _on_notify(text: String, kind: String) -> void:
	var card := AfUI.card(10, Color(0.06, 0.065, 0.075, 0.9))
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := AfUI.label(text, 17, AfTheme.kind_color(kind), true)
	l.custom_minimum_size = Vector2(480, 0)
	card.add_child(l)
	_notes.add_child(card)
	while _notes.get_child_count() > 4:
		_notes.get_child(0).queue_free()
		_notes.remove_child(_notes.get_child(0))
	var tw := card.create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(card, "modulate:a", 0.0, 0.5)
	tw.tween_callback(card.queue_free)


func _on_journal(e: Dictionary) -> void:
	if str(e["category"]) in ["radio", "story", "world", "mod"]:
		_on_notify(str(e["text"]), "info")


func _open(panel: Control) -> void:
	if _has_modal():
		return
	get_parent().add_child(panel)


func open_inventory() -> void:
	_open(AfInventoryPanel.new())


func open_character() -> void:
	_open(AfCharacterPanel.new())


func open_map() -> void:
	var p := AfMapPanel.new(false)
	p.world = world
	_open(p)


func open_menu() -> void:
	var p := AfGameMenu.new()
	p.world = world
	_open(p)
