extends RefCounted
## Runs the real game scene headless and drives it through code.

var world: AfGameWorld


func before_each(t) -> void:
	Session.new_game()
	var scene: PackedScene = load("res://scenes/game.tscn")
	world = scene.instantiate()
	t.get_tree().root.add_child(world)
	await _frames(t, 3)


func after_each(t) -> void:
	if is_instance_valid(world):
		world.queue_free()
	await _frames(t, 2)
	Session.end_session()


func _frames(t, n: int) -> void:
	for i in n:
		await t.get_tree().physics_frame


func test_location_builds(t) -> void:
	t.eq(world.mode, "location", "starts inside the location")
	t.ok(world.player != null, "player spawned")
	t.ok(world.containers.size() >= 10, "containers placed (%d)" % world.containers.size())
	t.ok(world.exits.size() >= 1, "exits")
	t.ok(world.zm.alive_count() >= 10, "infected spawned (%d)" % world.zm.alive_count())
	t.ok(world.hud != null, "hud")
	var deadline := Time.get_ticks_msec() + 15000
	while not world.zm.nav_ready and Time.get_ticks_msec() < deadline:
		await _frames(t, 5)
	t.ok(world.zm.nav_ready, "navigation mesh baked")


func test_zombie_hears_gunshot(t) -> void:
	var z := world.zm.spawn("walker", world.player.global_position + Vector3(20, 0, 0))
	z.state = AfZombie.S.IDLE
	z.facing = Vector3(1, 0, 0)  # looking away
	EventBus.noise_emitted.emit(world.player.global_position, 32.0, "gunshot")
	t.eq(z.state, AfZombie.S.INVESTIGATE, "investigates the noise")
	t.ok(z.target_pos.distance_to(world.player.global_position) < 0.1, "remembers the noise position")
	var far := world.zm.spawn("walker", world.player.global_position + Vector3(45, 0, 40))
	far.state = AfZombie.S.IDLE
	EventBus.noise_emitted.emit(world.player.global_position, 6.0, "steps")
	t.eq(far.state, AfZombie.S.IDLE, "quiet footsteps not heard from far away")


func test_zombie_sees_and_attacks(t) -> void:
	_clear_zombies()
	var p := world.player
	p.global_position = Vector3(0, 0, 14)
	var z := world.zm.spawn("runner", p.global_position + Vector3(0, 0, -5))
	z.facing = Vector3(0, 0, 1)
	z.state = AfZombie.S.IDLE
	await _frames(t, 4)
	t.ok(z.is_hunting(), "zombie spotted the hero in its cone of vision")
	var hp0 := Session.player.survival.health
	var deadline := Time.get_ticks_msec() + 6000
	while Session.player.survival.health >= hp0 and Time.get_ticks_msec() < deadline:
		await _frames(t, 3)
	t.ok(Session.player.survival.health < hp0, "zombie reached and hit the hero")


func test_melee_kills_and_corpse_loot(t) -> void:
	_clear_zombies()
	var p := world.player
	var z := world.zm.spawn("walker", p.global_position + p.facing() * 1.2)
	z.hp = 10.0
	var kills0 := Session.player.kills
	p.melee_cd = 0.0
	p.melee()
	t.ok(z.is_dead(), "crowbar kills a weakened walker")
	t.eq(Session.player.kills, kills0 + 1, "kill counted via EventBus")
	t.ok(world.zm.corpses.has(z), "corpse kept")
	var stack := Session.player.equipped_stack("melee")
	t.ok(float(stack["condition"]) < 0.85, "weapon wear applied")


func test_firearm_ammo_and_reload(t) -> void:
	_clear_zombies()
	var inv := Session.player.inventory
	inv.add("makarov", 1, 1.0, 1.0, true)
	inv.add("ammo_9x18", 16, 1.0, 1.0, true)
	var uid := 0
	for s in inv.stacks:
		if s["item"] == "core:makarov":
			uid = int(s["uid"])
	Session.player.equip(uid)
	var p := world.player
	p.reload()
	t.ok(p.reload_t > 0.0, "reloading")
	var deadline := Time.get_ticks_msec() + 4000
	while p.reload_t >= 0.0 and Time.get_ticks_msec() < deadline:
		await _frames(t, 2)
	t.eq(int(Session.player.equipped_stack("firearm")["ammo"]), 8, "magazine loaded")
	t.eq(inv.count("ammo_9x18"), 8, "ammo taken from inventory")
	var z := world.zm.spawn("walker", p.global_position + Vector3(0, 0, 6))
	var heard := {"n": 0}
	var cb := func(_pos, r, src): if src == "gunshot": heard["n"] += 1
	EventBus.noise_emitted.connect(cb)
	var shots := 0
	while not z.is_dead() and shots < 8:
		p.fire_cd = 0.0
		p.jammed = false
		p.fire()
		shots += 1
		await _frames(t, 1)
	EventBus.noise_emitted.disconnect(cb)
	t.ok(z.is_dead(), "shots killed the target (%d shots)" % shots)
	t.eq(heard["n"], shots, "every shot made noise")
	t.eq(int(Session.player.equipped_stack("firearm")["ammo"]), 8 - shots, "ammo spent")


func test_container_search_and_persist(t) -> void:
	_clear_zombies()
	var c: Node3D = world.containers[0]
	var cdef: Dictionary = c.get_meta("container")
	var st := Session.locations.container(world.zm.location_id, str(cdef["id"]))
	var panel := AfLootPanel.new()
	panel.setup_container(world, c, cdef, st)
	world.ui_layer.add_child(panel)
	t.ok(st["searched"], "container marked searched")
	panel._search_left = 0.01
	await _frames(t, 3)
	var before := Session.player.inventory.stacks.size()
	var n: int = st["items"].size()
	panel._take_all()
	t.ok(st["items"].size() < n or n == 0, "items moved")
	t.ok(Session.player.inventory.stacks.size() >= before, "inventory received loot")
	panel.close()
	await _frames(t, 1)


func test_save_inside_location_keeps_zombies(t) -> void:
	_clear_zombies()
	var z := world.zm.spawn("riot", Vector3(5, 0, 5))
	z.hp = 77.0
	t.ok(Saves.save("slot_2"), "saved inside location")
	var st := Session.locations.state(world.zm.location_id)
	var found: Array = st["zombies"].filter(func(e): return e["type"] == "core:riot" and is_equal_approx(float(e["hp"]), 77.0))
	t.eq(found.size(), 1, "live zombie captured into location state before save")
	world.queue_free()
	await _frames(t, 2)
	var rep := Saves.load_slot("slot_2", false)
	t.ok(rep["ok"], "loaded")
	world = (load("res://scenes/game.tscn") as PackedScene).instantiate()
	t.get_tree().root.add_child(world)
	await _frames(t, 3)
	var riots := world.zm.zombies.filter(func(x): return x.type_id == "core:riot" and is_equal_approx(x.hp, 77.0))
	t.eq(riots.size(), 1, "zombie restored with its health")


func test_leave_to_map_and_back(t) -> void:
	_clear_zombies()
	world.leave_to_map()
	await _frames(t, 2)
	t.eq(world.mode, "map", "map mode")
	t.eq(Session.player.location_id, "", "hero on the strategic map")
	t.ok(Clock.has_pause("map"), "time is frozen on the map")
	world.enter_location("core:ufa_chernikovka")
	await _frames(t, 2)
	t.eq(world.mode, "location", "back in location")
	t.ok(not Clock.has_pause("map"), "time flows again")


func test_ai_lod_limits_active(t) -> void:
	for i in 40:
		world.zm.spawn("walker", Vector3(randf_range(-40, 40), 0, randf_range(-40, 40)))
	world.zm._update_lod()
	var active := world.zm.zombies.filter(func(z): return z.active and not z.is_dead()).size()
	t.ok(active <= int(Settings.p("max_active_zombies")), "active AI capped (%d <= %d)" % [active, int(Settings.p("max_active_zombies"))])


func _clear_zombies() -> void:
	for z in world.zm.zombies.duplicate():
		world.zm.zombies.erase(z)
		world.zm._release(z)


func test_base_compound_in_3d(t) -> void:
	var b := Session.base
	b.found(AfWorldMap.START_PLACE, "core:ufa")
	Session.events.resolve(Session.events.pending[0], 0)
	b.modules["core:shelter"] = {"level": 2, "condition": 1.0}
	b.modules["core:workshop"] = {"level": 1, "condition": 0.3}
	b.modules["core:defenses"] = {"level": 1, "condition": 1.0}
	b.queue = [{"module": "core:kitchen", "level": 1, "done": 1.0, "need": 5.0}]
	world.enter_location("core:ufa_chernikovka")
	await _frames(t, 3)
	t.ok(world.compound != null, "compound built in the base location")
	var mods := world.compound.spots.map(func(s): return s["module"])
	t.ok(mods.has("shelter") and mods.has("workshop") and mods.has("kitchen"), "built and queued modules shown: %s" % str(mods))
	t.ok(world.compound.slots.size() >= 8, "enough free slots in the yard (%d)" % world.compound.slots.size())
	var inside := world.zm.zombies.filter(func(z): return Vector2(z.global_position.x, z.global_position.z).distance_to(Vector2(world.compound.center.x, world.compound.center.z)) < world.compound.radius)
	t.eq(inside.size(), 0, "no infected inside the fence")
	await _frames(t, 20)
	t.eq(world.compound.npcs().size(), 1, "resident walks around")
	world.player.global_position = world.compound.slots["shelter"] + Vector3(0, 0, 1)
	world.player._update_interact_target()
	t.eq(str(world.player.interact_target.get("kind", "")), "base_module", "module is interactable")
	world.enter_location("core:ufa_chernikovka")
	await _frames(t, 2)
	t.ok(world.compound != null, "rebuilt on re-entry")
	var gen := AfLocationGenerator.ensure_for_place(Registry.all("place").filter(func(p): return p["type"] == "hospital")[0]["id"])
	world.enter_location(gen)
	await _frames(t, 2)
	t.ok(world.compound == null, "no compound in other locations")
