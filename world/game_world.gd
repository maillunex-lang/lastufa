class_name AfGameWorld
extends Node3D
## Root of the game scene. Two modes:
##  - "location": a detailed 3D location with the hero, infected and HUD;
##  - "map": the strategic map of Bashkortostan (travel, area search, rest).

var mode := ""
var loc_def: Dictionary = {}
var player: AfPlayerController
var zm: AfZombieManager
var cam: AfIsoCamera
var fx: AfEnvironmentFx
var hud: AfHud
var ui_layer: CanvasLayer
var containers: Array = []
var exits: Array = []
var _location_root: Node3D
var _tracers: Array[MeshInstance3D] = []
var _tracer_i := 0
var _death_shown := false


func _ready() -> void:
	if not Session.active:
		Session.new_game()
	fx = AfEnvironmentFx.new()
	add_child(fx)
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)
	EventBus.player_died.connect(_on_player_died)
	Saves.before_save.connect(_persist_location)
	Session.player.inventory.mark_availability()
	var loc_id := Session.player.location_id
	if loc_id.begins_with(AfLocationGenerator.PREFIX):
		AfLocationGenerator.ensure_location(loc_id)
	if loc_id != "" and Registry.has_def("location", loc_id):
		enter_location(loc_id)
	else:
		if loc_id != "":
			EventBus.toast("Локация недоступна (нет пакета) — вы на карте района.", "warn")
		show_map_mode()
	_show_load_report.call_deferred()


func _exit_tree() -> void:
	if Saves.before_save.is_connected(_persist_location):
		Saves.before_save.disconnect(_persist_location)


func _show_load_report() -> void:
	var rep: Dictionary = Saves.last_load_report
	Saves.last_load_report = {}
	if rep.is_empty():
		return
	var lines := []
	var off: Dictionary = rep.get("offline", {})
	for e in off.get("entries", []):
		lines.append(str(e["text"]))
	if rep.get("used_backup", false):
		lines.push_front("Основной файл сохранения повреждён — загружена резервная копия.")
	if int(rep.get("migrated_from", 0)) > 0:
		lines.push_front("Сохранение обновлено с формата v%d." % rep["migrated_from"])
	for p in rep.get("missing_packages", []):
		lines.append("Нет пакета %s: его объекты сохранены и вернутся после установки." % p)
	if not lines.is_empty():
		AfDialog.show_in(ui_layer, "Пока вас не было" if float(off.get("minutes", 0.0)) > 0.0 else "Загрузка", "", [["Продолжить", Callable()]], lines)


# --- location mode -------------------------------------------------------------

func enter_location(loc_id: String) -> void:
	_clear_mode()
	mode = "location"
	loc_def = Registry.get_def("location", loc_id)
	Session.player.location_id = loc_id
	_sync_current_place(loc_id)
	var built := AfLocationBuilder.build(loc_def)
	_location_root = built["root"]
	add_child(_location_root)
	containers = built["containers"]
	exits = built["exits"]
	for c in containers:
		var st := Session.locations.container(loc_id, str(c.get_meta("container")["id"]))
		_set_container_glow(c, not (st["searched"] and st["items"].is_empty()))
	zm = AfZombieManager.new()
	zm.location_id = loc_id
	add_child(zm)
	player = AfPlayerController.new()
	player.state = Session.player
	player.zm = zm
	player.world = self
	add_child(player)
	var st := Session.locations.state(loc_id)
	var spawn: Vector3 = built["spawn"]
	if Session.player.has_position and float(st["last_visit"]) >= 0.0 and _inside(Session.player.position):
		spawn = Session.player.position
	player.global_position = spawn
	zm.player = player
	zm.populate(loc_def)
	var nav: NavigationRegion3D = built["nav"]
	nav.bake_finished.connect(func(): zm.nav_ready = true)
	nav.bake_navigation_mesh(true)
	cam = AfIsoCamera.new()
	add_child(cam)
	cam.target = player
	cam.global_position = spawn
	player.camera = cam.camera
	fx.follow = player
	player.shot_fired.connect(_on_shot)
	_make_tracers()
	hud = AfHud.new()
	hud.world = self
	ui_layer.add_child(hud)
	st["last_visit"] = Clock.total_minutes
	Clock.release_pause("map")
	Session.journal.add("location", "Локация: %s." % loc_def.get("name", loc_id))
	EventBus.location_entered.emit(loc_id)


## Keeps the map position in sync with the location the hero is in.
func _sync_current_place(loc_id: String) -> void:
	var wm := Session.world_map
	if loc_def.has("place"):
		wm.current_place = str(loc_def["place"])
		return
	for p in Registry.all("place"):
		if p.has("location") and RegistryHelpers.full_id_for(str(p["location"]), str(p.get("_package", "core")), "location") == loc_id:
			wm.current_place = str(p["id"])
			return


func _inside(p: Vector3) -> bool:
	var s: Array = loc_def["size"]
	return absf(p.x) < float(s[0]) / 2.0 - 1.0 and absf(p.z) < float(s[1]) / 2.0 - 1.0


func _persist_location() -> void:
	if mode != "location" or zm == null:
		return
	var st := Session.locations.state(zm.location_id)
	st["zombies"] = zm.export_state()
	st["last_visit"] = Clock.total_minutes


func leave_to_map() -> void:
	_persist_location()
	Session.player.location_id = ""
	Session.player.has_position = false
	show_map_mode()


func _clear_mode() -> void:
	if _location_root:
		_location_root.queue_free()
		_location_root = null
	for n in [zm, player, cam, hud]:
		if n and is_instance_valid(n):
			n.queue_free()
	zm = null
	player = null
	cam = null
	hud = null
	containers = []
	exits = []
	_tracers.clear()
	for c in ui_layer.get_children():
		c.queue_free()
	Session.threat_nearby = false
	Session.player_exertion = 0.0


func _process(_delta: float) -> void:
	if mode == "location" and zm:
		Session.threat_nearby = zm.hunting_count() > 0
	if Input.is_action_just_pressed("quick_save") and Session.active:
		if Saves.save("quicksave"):
			EventBus.toast("Быстрое сохранение", "good")


func shake(a: float) -> void:
	if cam:
		cam.shake(a)


# --- map mode -------------------------------------------------------------------

func show_map_mode() -> void:
	_clear_mode()
	mode = "map"
	Clock.push_pause("map")  # strategic actions advance time explicitly
	var cam3 := Camera3D.new()
	add_child(cam3)
	cam3.look_at_from_position(Vector3(0, 10, 10), Vector3.ZERO)
	var panel := AfMapPanel.new(true)
	panel.world = self
	ui_layer.add_child(panel)


# --- interaction ----------------------------------------------------------------

func on_interact(target: Dictionary) -> void:
	match str(target.get("kind", "")):
		"container":
			var c: Node3D = target["node"]
			var cdef: Dictionary = c.get_meta("container")
			var st := Session.locations.container(zm.location_id, str(cdef["id"]))
			var panel := AfLootPanel.new()
			panel.setup_container(self, c, cdef, st)
			ui_layer.add_child(panel)
		"corpse":
			var z: AfZombie = target["node"]
			var panel := AfLootPanel.new()
			panel.setup_corpse(self, z)
			ui_layer.add_child(panel)
		"exit":
			var ex: Dictionary = target["node"].get_meta("exit")
			if zm.hunting_count() > 0:
				EventBus.toast("Нельзя уйти, пока вас преследуют", "warn")
				return
			AfDialog.show_in(ui_layer, "Покинуть локацию?", "%s.\nВы выйдете на карту района «%s»." % [ex.get("name", ""), Registry.display_name("region", Session.world_map.current_region)],
				[["Остаться", Callable()], ["Выйти на карту", leave_to_map]])


func _set_container_glow(c: Node3D, has_loot: bool) -> void:
	var glow: MeshInstance3D = c.get_meta("glow")
	glow.visible = has_loot


func container_updated(c: Node3D, st: Dictionary) -> void:
	_set_container_glow(c, not (st["searched"] and st["items"].is_empty()))


# --- effects --------------------------------------------------------------------

func _make_tracers() -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.85, 0.5, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for i in 10:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.03, 0.03, 1.0)
		mi.mesh = bm
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_tracers.append(mi)


func _on_shot(from: Vector3, to: Vector3) -> void:
	if _tracers.is_empty():
		return
	var mi := _tracers[_tracer_i % _tracers.size()]
	_tracer_i += 1
	var len := from.distance_to(to)
	if len < 0.1:
		return
	mi.global_position = (from + to) * 0.5
	mi.look_at(to, Vector3.UP)
	mi.scale = Vector3(1, 1, len)
	mi.visible = true
	var tw := mi.create_tween()
	tw.tween_interval(0.06)
	tw.tween_callback(mi.hide)


func _on_player_died(cause: String) -> void:
	if _death_shown:
		return
	_death_shown = true
	if player:
		player.die()
	Clock.push_pause("death")
	var last := Saves.latest_slot()
	var buttons := [["В главное меню", _to_main_menu]]
	if last != "":
		buttons.append(["Загрузить последнее сохранение", func(): _load_slot(last)])
	AfDialog.show_in(ui_layer, "Вы погибли", "Причина: %s.\nДень %d, %s. Убито заражённых: %d." % [cause, Clock.day(), Clock.time_text(), Session.player.kills], buttons)


func _load_slot(slot: String) -> void:
	Clock.release_pause("death")
	var rep := Saves.load_slot(slot)
	if rep["ok"]:
		get_tree().reload_current_scene()
	else:
		AfDialog.show_in(ui_layer, "Ошибка загрузки", rep["error"])


func _to_main_menu() -> void:
	Session.end_session()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		# Android back button: open the game menu instead of quitting
		if hud and is_instance_valid(hud):
			hud.open_menu()
