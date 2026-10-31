extends Node
## Renders key screens to PNG for visual review (needs a display or xvfb).
## godot --rendering-driver opengl3 res://tools/screenshots.tscn -- out=/path

var out_dir := "user://screenshots"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			out_dir = a.substr(4)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _shot(name: String, frames: int = 20) -> void:
	for i in frames:
		await get_tree().process_frame
		if Session.active:
			Session.player.survival.health = 100.0  # keep the hero alive for the shots
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("saved ", name)


func _clear() -> void:
	for c in get_children():
		c.queue_free()
	await get_tree().process_frame


func _run() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var menu: Control = load("res://scenes/main_menu.tscn").instantiate()
	layer.add_child(menu)
	await _shot("01_main_menu")
	var ng := AfNewGamePanel.new()
	layer.add_child(ng)
	ng._pick("hard")
	await _shot("01b_new_game", 10)
	await _clear()
	Session.new_game()
	Clock.start(14.0 * 60.0)
	Session.weather.current = "cloudy"
	var world: AfGameWorld = load("res://scenes/game.tscn").instantiate()
	add_child(world)
	await _shot("02_location_day", 60)
	world.player.global_position = Vector3(-10, 0, -10)
	world.cam.global_position = world.player.global_position
	world.cam.zoom = 16.0
	Session.player.survival.add_injury("bleeding", 0.4, "left_arm")
	EventBus.toast("Ранение: кровотечение", "danger")
	await _shot("03_location_closeup", 40)
	Clock.start(23.0 * 60.0)
	Session.weather.current = "rain"
	Session.player.flashlight_on = true
	world.player._flashlight.visible = true
	world.fx.update_now()
	await _shot("04_location_night_rain", 50)
	world.ui_layer.add_child(AfInventoryPanel.new())
	await _shot("05_inventory", 10)
	for c in world.ui_layer.get_children():
		if c is AfPanel:
			c.queue_free()
	var mp := AfMapPanel.new(false)
	mp.world = world
	world.ui_layer.add_child(mp)
	await _shot("06_map_place", 15)
	mp._view.show_level("city", "ufa")
	mp._view.select("city_district", "core:ufa_kalininskiy")
	await _shot("06b_map_city", 10)
	var rd := Session.world_map.district_of("core:iglino")
	mp._view.show_level("district", rd)
	mp._view.select("region", "core:iglino")
	await _shot("06c_map_district", 10)
	mp._view.show_level("republic")
	mp._view.select("district", rd)
	await _shot("06d_map_republic", 10)
	mp.queue_free()
	world.ui_layer.add_child(AfCharacterPanel.new())
	await _shot("07_character", 10)
	for c in world.ui_layer.get_children():
		if c is AfPanel:
			c.queue_free()
	Updates.catalog = [
		{"id": "game.core", "name": "ASHENFALL: UFA — код игры", "type": "SYSTEM", "version": "0.1.9", "size": 368000, "state": "update", "installed_version": "0.1.2", "description": "Скрипты, сцены и данные ядра.", "changelog": "Многоуровневая карта"},
		{"id": "region.sterlitamak", "name": "Регион: Стерлитамак — содовая промзона", "type": "REGION", "version": "1.0.0", "size": 4357, "state": "available", "description": "Детальная локация у содового завода."},
		{"id": "hd.textures", "name": "HD-текстуры панелек", "type": "ASSET", "version": "1.2.0", "size": 48000000, "state": "available", "description": "Фасады хрущёвок и девятиэтажек."},
		{"id": "example.echpochmak", "name": "Пример мода: Эчпочмак", "type": "MOD", "category": "items", "version": "1.0.0", "size": 1002, "state": "available", "description": "Новый предмет."},
		{"id": "ambient.ufa", "name": "Звуки ночной Уфы", "type": "AUDIO", "version": "0.3.0", "size": 9000000, "state": "available", "description": "Ветер, сирены, лай собак."},
	]
	var cp := AfContentPanel.new()
	world.ui_layer.add_child(cp)
	cp._switch("catalog")
	await _shot("08_content", 10)
	for c in world.ui_layer.get_children():
		if c is AfPanel:
			c.queue_free()
	# --- base
	Session.world_map.current_place = AfWorldMap.START_PLACE
	Session.base.found(AfWorldMap.START_PLACE, "core:ufa")
	Session.events.resolve(Session.events.pending[0], 0)
	for i in 4:
		Session.survivors.add(Session.survivors.generate())
	Session.base.modules["core:shelter"] = {"level": 1, "condition": 1.0}
	Session.base.modules["core:garden"] = {"level": 1, "condition": 0.6}
	Session.base.storage.add("wood_planks", 12, 1.0, 1.0, true)
	Session.base.storage.add("canned_meat", 8, 1.0, 1.0, true)
	Session.base.storage.add("water_bottle", 10, 1.0, 1.0, true)
	Session.base.order_build("defenses")
	var bp := AfBasePanel.new()
	world.ui_layer.add_child(bp)
	await _shot("10_base_overview", 10)
	bp._tab = "people"
	bp._render()
	await _shot("11_base_people", 10)
	bp._tab = "build"
	bp._render()
	await _shot("12_base_build", 10)
	bp.queue_free()
	await get_tree().process_frame
	var victim: Dictionary = Session.survivors.at_base()[1]
	Session.events.queue_bitten(victim)
	AfBasePanel.show_decision(world.ui_layer, Session.events.pending[-1])
	await _shot("13_decision", 10)
	for c in world.ui_layer.get_children():
		if c is AfDialog:
			c.queue_free()
	Session.events.pending.clear()
	# --- base in 3D
	var mods := {"shelter": 2, "storage": 2, "workshop": 2, "infirmary": 1, "kitchen": 1, "garden": 2, "water": 2, "generator": 1, "radio": 1, "defenses": 2}
	for m in mods:
		Session.base.modules["core:" + m] = {"level": mods[m], "condition": 1.0 if m != "water" else 0.4}
	Session.base.storage.add("fuel_can", 3, 1.0, 1.0, true)
	Session.base.queue = [{"module": "core:storage", "level": 3, "done": 5.0, "need": 12.0}]
	Session.base.modules.erase("core:storage")
	var jobs := ["build", "garden", "kitchen", "guard", "infirmary"]
	var ppl := Session.survivors.at_base()
	for i in ppl.size():
		ppl[i]["job"] = jobs[i % jobs.size()]
	Clock.start(12.0 * 60.0)
	Session.weather.current = "clear"
	world.enter_location("core:ufa_chernikovka")
	world.player.global_position = world.compound.center + Vector3(0, 0, world.compound.radius + 3.0)
	world.cam.global_position = world.compound.center
	world.cam.target = null
	world.cam.zoom = 30.0
	world.fx.update_now()
	await _shot("14_base_3d", 60)
	world.cam.global_position = world.compound.slots["kitchen"]
	world.cam.zoom = 15.0
	await _shot("15_base_3d_close", 40)
	world.cam.target = world.player
	Clock.start(13.0 * 60.0)
	Session.weather.current = "clear"
	for pid in ["hospital", "mall", "industrial"]:
		var places := Registry.all("place").filter(func(p): return p["type"] == pid)
		var loc := AfLocationGenerator.ensure_for_place(str(places[0]["id"]))
		world.enter_location(loc)
		world.cam.zoom = 34.0
		await _shot("09_gen_" + pid, 50)
	Session.end_session()
	get_tree().quit()
