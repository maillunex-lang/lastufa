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
	await _shot("06_map", 15)
	mp.queue_free()
	world.ui_layer.add_child(AfCharacterPanel.new())
	await _shot("07_character", 10)
	for c in world.ui_layer.get_children():
		if c is AfPanel:
			c.queue_free()
	world.ui_layer.add_child(AfContentPanel.new())
	await _shot("08_content", 10)
	Session.end_session()
	get_tree().quit()
