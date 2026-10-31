class_name AfPlayerController
extends CharacterBody3D
## The hero in a 3D location: movement (camera-relative, touch or keyboard),
## stamina, stealth, noise, melee and firearms (hitscan ballistics with spread,
## falloff, wear, jams, reloads), interaction and receiving damage.

signal hit_taken(amount: float)
signal shot_fired(from: Vector3, to: Vector3)
signal interact_target_changed(text: String)

const WALK := 3.2
const SPRINT := 5.6
const SNEAK := 1.6

var state: AfPlayerState
var zm: AfZombieManager
var world: Node
var input_vec := Vector2.ZERO
var sprinting := false
var sneaking := false
var stamina := 100.0
var dead := false

var melee_cd := 0.0
var fire_cd := 0.0
var reload_t := -1.0
var reload_total := 1.0
var jammed := false
var _step_t := 0.0
var _visual: Node3D
var _flashlight: SpotLight3D
var _muzzle: OmniLight3D
var _muzzle_t := 0.0
var _interact_t := 0.0
var interact_target: Dictionary = {}   # {kind: container|corpse|exit, node, text}
var _ray := PhysicsRayQueryParameters3D.new()
var camera: Camera3D


func _init() -> void:
	collision_layer = AfLocationBuilder.LAYER_PLAYER
	collision_mask = AfLocationBuilder.LAYER_WORLD | AfLocationBuilder.LAYER_ZOMBIE
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	add_child(cs)


func _ready() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.33
	cm.height = 1.5
	body.mesh = cm
	body.material_override = AfLocationBuilder.mat(Color("3e5d6e"), 0.7)
	body.position = Vector3(0, 0.78, 0)
	_visual.add_child(body)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	head.mesh = sm
	head.material_override = AfLocationBuilder.mat(Color("c9a487"))
	head.position = Vector3(0, 1.65, 0)
	_visual.add_child(head)
	var pack := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.45, 0.55, 0.22)
	pack.mesh = bm
	pack.material_override = AfLocationBuilder.mat(Color("5a4a32"))
	pack.position = Vector3(0, 1.05, -0.3)
	_visual.add_child(pack)
	var marker := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.55
	tm.outer_radius = 0.65
	marker.mesh = tm
	marker.material_override = AfLocationBuilder.mat(AfTheme.ACCENT, 0.5, AfTheme.ACCENT * 1.2)
	marker.position = Vector3(0, 0.03, 0)
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(marker)
	_flashlight = SpotLight3D.new()
	_flashlight.spot_range = 16.0
	_flashlight.spot_angle = 28.0
	_flashlight.light_energy = 3.0
	_flashlight.light_color = Color("fff1d6")
	_flashlight.shadow_enabled = bool(Settings.p("shadows"))
	_flashlight.position = Vector3(0, 1.4, 0.3)
	_flashlight.rotation_degrees = Vector3(-12, 180, 0)
	_visual.add_child(_flashlight)
	_muzzle = OmniLight3D.new()
	_muzzle.light_color = Color("ffcf7a")
	_muzzle.omni_range = 7.0
	_muzzle.light_energy = 0.0
	_muzzle.position = Vector3(0, 1.3, 0.6)
	_visual.add_child(_muzzle)
	_flashlight.visible = state.flashlight_on
	_ray.collision_mask = AfLocationBuilder.LAYER_WORLD | AfLocationBuilder.LAYER_ZOMBIE
	_ray.exclude = [get_rid()]


func flashlight_on() -> bool:
	return state.flashlight_on


func toggle_flashlight() -> void:
	state.flashlight_on = not state.flashlight_on
	_flashlight.visible = state.flashlight_on


func facing() -> Vector3:
	return Vector3(sin(_visual.rotation.y), 0, cos(_visual.rotation.y))


func _physics_process(delta: float) -> void:
	melee_cd = maxf(0.0, melee_cd - delta)
	fire_cd = maxf(0.0, fire_cd - delta)
	if _muzzle_t > 0.0:
		_muzzle_t -= delta
		if _muzzle_t <= 0.0:
			_muzzle.light_energy = 0.0
	if dead or Clock.is_paused():
		velocity = Vector3.ZERO
		return
	if reload_t >= 0.0:
		reload_t -= delta
		if reload_t < 0.0:
			_finish_reload()
	var v := input_vec
	if v.length() < 0.05:
		v = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var dir := Vector3.ZERO
	if v.length() > 0.05 and camera:
		var right := camera.global_basis.x
		right.y = 0.0
		var fwd := -camera.global_basis.z
		fwd.y = 0.0
		dir = (right.normalized() * v.x - fwd.normalized() * v.y)
		if dir.length() > 1.0:
			dir = dir.normalized()
	var moving := dir.length() > 0.05
	var sprint_now := (sprinting or Input.is_action_pressed("sprint")) and moving and stamina > 5.0 and not sneaking
	var sneak_now := sneaking or Input.is_action_pressed("sneak")
	var speed := SNEAK if sneak_now else (SPRINT if sprint_now else WALK)
	var weight_ratio := state.inventory.total_weight() / state.inventory.max_weight
	var encumbrance := 1.0 if weight_ratio < 0.8 else clampf(1.0 - (weight_ratio - 0.8) * 1.5, 0.5, 1.0)
	speed *= state.survival.move_multiplier() * Session.weather.move_mult() * encumbrance
	if reload_t >= 0.0:
		speed *= 0.7
	# stamina
	if sprint_now:
		stamina = maxf(0.0, stamina - 14.0 * delta)
	else:
		var regen := 9.0 * (0.5 if state.survival.need("energy") < 25.0 else 1.0)
		stamina = minf(100.0, stamina + regen * delta)
	state.survival.stamina = stamina
	Session.player_exertion = 0.0 if not moving else (2.0 if sprint_now else (0.5 if sneak_now else 1.0))
	velocity = dir * speed
	move_and_slide()
	global_position.y = 0.0
	if moving:
		_visual.rotation.y = lerp_angle(_visual.rotation.y, atan2(dir.x, dir.z), 0.3)
		_step_t -= delta
		if _step_t <= 0.0:
			_step_t = 0.55
			var loud := 2.0 if sneak_now else (12.0 if sprint_now else 6.0)
			EventBus.noise_emitted.emit(global_position, loud, "steps")
		_visual.position.y = absf(sin(Time.get_ticks_msec() * 0.012)) * 0.05
	state.position = global_position
	state.has_position = true
	_interact_t -= delta
	if _interact_t <= 0.0:
		_interact_t = 0.2
		_update_interact_target()


# --- combat ------------------------------------------------------------------

func melee() -> void:
	if dead or melee_cd > 0.0 or Clock.is_paused():
		return
	var d := state.equipped_def("melee")
	var stack := state.equipped_stack("melee")
	var w: Dictionary = d.get("weapon", {"damage": 7.0, "range": 1.3, "arc_deg": 70, "cooldown": 0.6, "stamina": 6, "noise": 3, "wear": 0.0})
	var cond := float(stack.get("condition", 1.0)) if not d.is_empty() else 1.0
	if not d.is_empty() and cond <= 0.0:
		EventBus.toast("%s сломан(а)" % d["name"], "warn")
		w = {"damage": 7.0, "range": 1.3, "arc_deg": 70, "cooldown": 0.6, "stamina": 6, "noise": 3, "wear": 0.0}
		d = {}
	var cost := float(w.get("stamina", 8.0))
	var tired := stamina < cost
	stamina = maxf(0.0, stamina - cost)
	melee_cd = float(w.get("cooldown", 0.7)) * (1.6 if tired else 1.0)
	_auto_face(float(w.get("range", 1.5)) + 1.5)
	var fwd := facing()
	var hits := 0
	for z in zm.living_in_range(global_position, float(w.get("range", 1.5)) + 0.4):
		var to_z: Vector3 = z.global_position - global_position
		to_z.y = 0.0
		if rad_to_deg(fwd.angle_to(to_z.normalized())) <= float(w.get("arc_deg", 80)) * 0.5:
			var quality := float(stack.get("quality", 1.0)) if not d.is_empty() else 1.0
			var dmg := float(w["damage"]) * (0.6 + 0.4 * quality) * (0.5 + 0.5 * cond) * (0.6 if tired else 1.0) * randf_range(0.85, 1.15)
			z.take_damage(dmg, to_z, "melee")
			hits += 1
	if hits > 0 and not d.is_empty():
		stack["condition"] = maxf(0.0, cond - float(w.get("wear", 0.005)) * hits)
	EventBus.noise_emitted.emit(global_position, float(w.get("noise", 4.0)), "melee")
	_swing_anim()


func _swing_anim() -> void:
	var tw := create_tween()
	tw.tween_property(_visual, "rotation:x", 0.25, 0.08)
	tw.tween_property(_visual, "rotation:x", 0.0, 0.15)


func can_fire() -> bool:
	return not state.equipped_def("firearm").is_empty()


func fire() -> void:
	if dead or fire_cd > 0.0 or reload_t >= 0.0 or Clock.is_paused():
		return
	var d := state.equipped_def("firearm")
	if d.is_empty():
		EventBus.toast("Нет огнестрельного оружия", "warn")
		return
	var stack := state.equipped_stack("firearm")
	var w: Dictionary = d["weapon"]
	var cond := float(stack.get("condition", 1.0))
	if cond <= 0.0:
		EventBus.toast("%s неисправен" % d["name"], "warn")
		return
	if jammed:
		EventBus.toast("Заклинило! Перезарядите.", "warn")
		return
	if int(stack.get("ammo", 0)) <= 0:
		EventBus.toast("Пусто. Перезарядка…", "warn")
		reload()
		return
	fire_cd = float(w.get("cooldown", 0.4))
	stack["ammo"] = int(stack["ammo"]) - 1
	stack["condition"] = maxf(0.0, cond - float(w.get("wear", 0.003)))
	if cond < 0.5 and randf() < (0.5 - cond) * 0.3:
		jammed = true
	var rng := float(w.get("range", 25.0))
	var target: AfZombie = _auto_face(rng)
	var origin := global_position + Vector3(0, 1.3, 0)
	var aim_dir := facing()
	if target:
		aim_dir = (target.global_position + Vector3(0, 1.0, 0) - origin).normalized()
	var moving := velocity.length() > 0.5
	var spread := float(w.get("spread_deg", 4.0)) * (1.0 + (0.8 if moving else 0.0) + (0.8 if sprinting else 0.0))
	spread *= 1.0 + (1.0 - cond) + state.survival.stress / 200.0 + (0.3 if state.survival.pain() > 60.0 else 0.0)
	if sneaking and not moving:
		spread *= 0.7
	var space := get_world_3d().direct_space_state
	var pellets := int(w.get("pellets", 1))
	var falloff_start := float(w.get("falloff_start", rng * 0.5))
	for i in pellets:
		var dir := aim_dir.rotated(Vector3.UP, deg_to_rad(randf_range(-spread, spread) * 0.5))
		dir = dir.rotated(dir.cross(Vector3.UP).normalized(), deg_to_rad(randf_range(-spread, spread) * 0.15))
		_ray.from = origin
		_ray.to = origin + dir * rng
		var hit := space.intersect_ray(_ray)
		var end := _ray.to
		if not hit.is_empty():
			end = hit["position"]
			if hit["collider"] is AfZombie:
				var dist := origin.distance_to(end)
				var fall := 1.0 if dist <= falloff_start else clampf(1.0 - (dist - falloff_start) / maxf(1.0, rng - falloff_start) * 0.6, 0.4, 1.0)
				(hit["collider"] as AfZombie).take_damage(float(w["damage"]) * fall * randf_range(0.9, 1.1) * (0.7 + 0.3 * float(stack.get("quality", 1.0))), dir, "bullet")
		shot_fired.emit(origin + dir * 0.5, end)
	_muzzle.light_energy = 4.0
	_muzzle_t = 0.06
	EventBus.noise_emitted.emit(global_position, float(w.get("noise", 30.0)), "gunshot")
	Session.world_map.add_noise(Session.world_map.current_region, 0.0005)
	if world and world.has_method("shake"):
		world.shake(0.15)


func reload() -> void:
	if reload_t >= 0.0 or dead:
		return
	var d := state.equipped_def("firearm")
	if d.is_empty():
		return
	var stack := state.equipped_stack("firearm")
	var w: Dictionary = d["weapon"]
	if int(stack.get("ammo", 0)) >= int(w.get("mag", 1)) and not jammed:
		return
	if state.inventory.count(str(w["ammo"])) <= 0 and not jammed:
		EventBus.toast("Нет патронов: %s" % Registry.display_name("item", str(w["ammo"])), "warn")
		return
	reload_total = float(w.get("reload_time", 1.5))
	reload_t = reload_total
	EventBus.noise_emitted.emit(global_position, 3.0, "reload")


func reload_progress() -> float:
	return -1.0 if reload_t < 0.0 else 1.0 - reload_t / reload_total


func _finish_reload() -> void:
	jammed = false
	var d := state.equipped_def("firearm")
	if d.is_empty():
		return
	var stack := state.equipped_stack("firearm")
	var w: Dictionary = d["weapon"]
	var need := int(w.get("mag", 1)) - int(stack.get("ammo", 0))
	var got := state.inventory.remove_item(str(w["ammo"]), need)
	stack["ammo"] = int(stack.get("ammo", 0)) + got


## Turns toward the best target in range. Returns it (or null).
func _auto_face(max_range: float) -> AfZombie:
	var best: AfZombie = null
	var best_score := INF
	var fwd := facing()
	for z in zm.living_in_range(global_position, max_range):
		var to_z: Vector3 = z.global_position - global_position
		to_z.y = 0.0
		var ang := fwd.angle_to(to_z.normalized())
		if ang > deg_to_rad(75.0) and input_vec.length() > 0.2:
			continue
		if not zm.has_los(z, self):
			continue
		var score := to_z.length() + ang * 4.0
		if score < best_score:
			best_score = score
			best = z
	if best:
		var to_b := best.global_position - global_position
		_visual.rotation.y = atan2(to_b.x, to_b.z)
	return best


func receive_hit(z: AfZombie) -> void:
	if dead:
		return
	var dmg := float(z.def.get("damage", 8.0)) * randf_range(0.8, 1.2) * Session.config.p("zombie_damage")
	if sneaking:
		dmg *= 1.1
	state.survival.take_hit(dmg, z.def.get("name", "заражённый"))
	var limbs := ["left_arm", "right_arm", "torso", "left_leg", "right_leg"]
	var limb: String = limbs[randi() % limbs.size()]
	var notes := PackedStringArray()
	if randf() < float(z.def.get("bleed_chance", 0.2)):
		state.survival.add_injury("bleeding", randf_range(0.2, 0.7), limb)
		notes.append("кровотечение")
	if randf() < float(z.def.get("burn_chance", 0.0)):
		state.survival.add_injury("burn", randf_range(0.2, 0.5), limb)
		notes.append("химический ожог")
	if z.def.get("behavior") == "brute" and randf() < 0.12:
		state.survival.add_injury("fracture", randf_range(0.4, 0.8), limb)
		notes.append("перелом")
	if randf() < 0.1:
		state.survival.add_injury("wound_infection", 0.15, limb)
	state.survival.expose_to_infection(float(z.def.get("infect_chance", 0.05)))
	reload_t = -1.0 if randf() < 0.3 else reload_t
	hit_taken.emit(dmg)
	EventBus.player_damaged.emit(dmg, str(z.def.get("name", "")))
	if not notes.is_empty():
		EventBus.toast("Ранение: " + ", ".join(notes), "danger")
	if world and world.has_method("shake"):
		world.shake(0.25)
	if state.survival.dead:
		die()


func die() -> void:
	if dead:
		return
	dead = true
	_visual.rotation.x = -PI / 2.0
	_visual.position.y = 0.3
	EventBus.player_died.emit(state.survival.death_cause)


# --- interaction ---------------------------------------------------------------

func _update_interact_target() -> void:
	var best := {}
	var bd := 2.4
	for c in world.containers:
		var d := global_position.distance_to(c.global_position)
		if d < bd:
			var cdef: Dictionary = c.get_meta("container")
			var st := Session.locations.container(zm.location_id, str(cdef["id"]))
			bd = d
			best = {"kind": "container", "node": c, "text": ("Обыскано: " if st["searched"] and st["items"].is_empty() else "Обыскать: ") + str(cdef["name"])}
	var corpse := zm.nearest_corpse(global_position, minf(bd, 2.0))
	if corpse:
		best = {"kind": "corpse", "node": corpse, "text": "Обыскать тело: " + str(corpse.def.get("name", ""))}
	if world.compound:
		for s in world.compound.spots:
			if global_position.distance_to(s["node"].global_position) < 3.2:
				best = {"kind": "base_module", "node": s["node"], "text": "Убежище: %s (ур. %d)" % [Registry.display_name("base_module", s["module"]), Session.base.level(s["module"])]}
		for n in world.compound.npcs():
			if global_position.distance_to(n.global_position) < 2.0:
				var p := Session.survivors.find(n.sid)
				best = {"kind": "resident", "node": n, "sid": n.sid, "text": "Поговорить: %s" % p.get("name", "")}
	for e in world.exits:
		var ed: Dictionary = e.get_meta("exit")
		if global_position.distance_to(e.global_position) < float(ed.get("radius", 3.0)):
			best = {"kind": "exit", "node": e, "text": "Уйти: " + str(ed.get("name", "на карту"))}
	var old_text := str(interact_target.get("text", ""))
	interact_target = best
	if str(best.get("text", "")) != old_text:
		interact_target_changed.emit(str(best.get("text", "")))


func interact() -> void:
	if dead or interact_target.is_empty() or Clock.is_paused():
		return
	world.on_interact(interact_target)
