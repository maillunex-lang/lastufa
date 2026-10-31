class_name AfZombieManager
extends Node3D
## Owns the infected of the current location: spawning (from definition or
## saved state), object pooling, AI level-of-detail (only the nearest N are
## simulated; far ones think less often), noise propagation, separation,
## corpses and persistence.

const MAX_CORPSES := 12
const NEAR_DIST := 20.0

var player: AfPlayerController
var location_id := ""
var nav_ready := false
var zombies: Array[AfZombie] = []
var corpses: Array[AfZombie] = []
var preserved: Array = []   # saved entries whose type is missing (mod removed)
var _pool: Array[AfZombie] = []
var _lod_timer := 0.0
var _frame := 0
var _space: PhysicsDirectSpaceState3D
var _los_query := PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	EventBus.noise_emitted.connect(_on_noise)
	_los_query.collision_mask = AfLocationBuilder.LAYER_WORLD


func _exit_tree() -> void:
	if EventBus.noise_emitted.is_connected(_on_noise):
		EventBus.noise_emitted.disconnect(_on_noise)


func _acquire() -> AfZombie:
	var z: AfZombie
	if _pool.is_empty():
		z = AfZombie.new()
		add_child(z)
	else:
		z = _pool.pop_back()
		z.visible = true
	z.manager = self
	z.player = player
	z.think_slot = randi() % 8
	return z


func _release(z: AfZombie) -> void:
	z.set_active(false)
	z.visible = false
	z.collision_layer = 0
	z.state = AfZombie.S.DEAD
	_pool.append(z)


func spawn(type_id: String, pos: Vector3, hp: float = -1.0, pkg: String = "core") -> AfZombie:
	var full := RegistryHelpers.full_id_for(type_id, pkg, "zombie")
	var def := Registry.get_def("zombie", full)
	if def.is_empty():
		return null
	var z := _acquire()
	z.setup(def, pos, hp)
	z.set_active(true)
	zombies.append(z)
	return z


## Populates the location from saved state or from its definition.
func populate(loc_def: Dictionary) -> void:
	var st := Session.locations.state(location_id)
	var pkg := str(loc_def.get("_package", "core"))
	var density_factor := _density_factor(loc_def) * Session.config.p("zombie_count")
	if st["zombies"] == null:
		for sp in loc_def.get("zombie_spawns", []):
			var n := maxi(0, roundi(int(sp.get("count", 1)) * density_factor))
			for i in n:
				var r := float(sp.get("radius", 3.0))
				spawn(str(sp["type"]), AfLocationBuilder.v3(sp["pos"]) + Vector3(randf_range(-r, r), 0, randf_range(-r, r)), -1.0, pkg)
	else:
		for e in st["zombies"]:
			var z := spawn(str(e["type"]), Vector3(float(e["x"]), 0, float(e["z"])), float(e["hp"]))
			if z == null:
				preserved.append(e)
		# the region keeps producing infected while the player is away
		var days := (Clock.total_minutes - float(st["last_visit"])) / 1440.0
		if float(st["last_visit"]) >= 0.0 and days >= 1.0:
			var spawns: Array = loc_def.get("zombie_spawns", [])
			var extra := roundi(spawns.size() * 0.8 * minf(days, 4.0) * density_factor)
			for i in extra:
				if spawns.is_empty():
					break
				var sp: Dictionary = spawns[randi() % spawns.size()]
				spawn(str(sp["type"]), AfLocationBuilder.v3(sp["pos"]) + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)), -1.0, pkg)
	Log.i("zombies", "%s: %d infected (density x%.2f)" % [location_id, zombies.size(), density_factor])


func _density_factor(loc_def: Dictionary) -> float:
	var region := Registry.get_def("region", str(loc_def.get("region", "")))
	if region.is_empty():
		return 1.0
	var base := maxf(0.05, float(region.get("danger", 0.5)))
	return clampf(Session.world_map.density(str(region["id"])) / base, 0.4, 1.6)


func export_state() -> Array:
	var out := preserved.duplicate()
	for z in zombies:
		if not z.is_dead():
			out.append({"type": z.type_id, "x": snappedf(z.global_position.x, 0.01), "z": snappedf(z.global_position.z, 0.01), "hp": z.hp})
	return out


func alive_count() -> int:
	return zombies.filter(func(z): return not z.is_dead()).size()


func hunting_count() -> int:
	return zombies.filter(func(z): return z.active and z.is_hunting()).size()


# --- per-frame -----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if player == null:
		return
	_frame += 1
	_space = get_world_3d().direct_space_state
	_lod_timer -= delta
	if _lod_timer <= 0.0:
		_lod_timer = 0.5
		_update_lod()
	var far_every := int(Settings.p("ai_far_think_interval"))
	for z in zombies:
		if not z.active or z.is_dead():
			continue
		var d := z.global_position.distance_to(player.global_position)
		if d < NEAR_DIST:
			z.think(delta)
		elif (_frame + z.think_slot) % far_every == 0:
			z.think(delta * far_every)


func _update_lod() -> void:
	var limit := int(Settings.p("max_active_zombies"))
	var alive := zombies.filter(func(z): return not z.is_dead())
	var ppos := player.global_position
	alive.sort_custom(func(a, b): return a.global_position.distance_squared_to(ppos) < b.global_position.distance_squared_to(ppos))
	for i in alive.size():
		var z: AfZombie = alive[i]
		var want := i < limit
		if z.active != want:
			z.set_active(want)


func has_los(z: AfZombie, target: Node3D) -> bool:
	if _space == null:
		return false
	_los_query.from = z.global_position + Vector3(0, 1.6, 0)
	_los_query.to = target.global_position + Vector3(0, 1.2, 0)
	return _space.intersect_ray(_los_query).is_empty()


func separation(z: AfZombie) -> Vector3:
	var push := Vector3.ZERO
	var p := z.global_position
	for o in zombies:
		if o == z or not o.active or o.is_dead():
			continue
		var d := p - o.global_position
		d.y = 0.0
		var l := d.length()
		if l < 0.9 and l > 0.001:
			push += d / l * (0.9 - l) * 4.0
	return push


func alert(pos: Vector3, radius: float, source: AfZombie) -> void:
	for z in zombies:
		if z != source and not z.is_dead() and z.global_position.distance_to(pos) < radius:
			z.hear(player.global_position if source.is_hunting() else pos, 15.0)


func _on_noise(pos: Vector3, radius: float, _source: String) -> void:
	var r := radius * Session.weather.hearing_mult()
	for z in zombies:
		if z.is_dead():
			continue
		var hr := r * float(z.def.get("hearing", 1.0))
		if z.global_position.distance_to(pos) < hr:
			z.hear(pos, radius)


func on_zombie_died(z: AfZombie) -> void:
	zombies.erase(z)
	corpses.append(z)
	if corpses.size() > MAX_CORPSES:
		_release(corpses.pop_front())


func nearest_corpse(pos: Vector3, max_dist: float) -> AfZombie:
	var best: AfZombie = null
	var bd := max_dist
	for c in corpses:
		if c.corpse_searched:
			continue
		var d := c.global_position.distance_to(pos)
		if d < bd:
			bd = d
			best = c
	return best


## Candidate targets for the player's auto-aim.
func living_in_range(pos: Vector3, max_dist: float) -> Array:
	var out := []
	for z in zombies:
		if z.active and not z.is_dead() and z.global_position.distance_to(pos) <= max_dist:
			out.append(z)
	return out
