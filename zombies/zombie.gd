class_name AfZombie
extends CharacterBody3D
## One infected. Perception (sight cone + line of sight, hearing via noise
## events, smell at short range), target memory with decay, group alerts,
## behaviour archetypes (shambler, runner, lurker ambush, armoured brute)
## and weather/light modifiers. The manager decides how often think() runs.

enum S { IDLE, WANDER, INVESTIGATE, CHASE, ATTACK, STAGGER, DORMANT, DEAD }

const WINDUP := 0.4

var def: Dictionary = {}
var type_id := ""
var hp := 50.0
var state := S.IDLE
var manager: Node
var player: Node3D

var target_pos := Vector3.ZERO
var memory_t := 0.0
var attack_cd := 0.0
var windup_t := -1.0
var stagger_t := 0.0
var wander_t := 0.0
var home := Vector3.ZERO
var facing := Vector3.FORWARD
var aware_of_player := false
var think_slot := 0
var active := true
var corpse_items: Array = []
var corpse_searched := false
var died_at_msec := 0

var agent: NavigationAgent3D
var _path_refresh := 0.0
var _visual: Node3D
var _body_mi: MeshInstance3D
var _eyes: MeshInstance3D
var _anim_t := 0.0
var _flash_t := 0.0
var _shape: CollisionShape3D

static var _overlay_mat: StandardMaterial3D
static var _eye_idle: StandardMaterial3D
static var _eye_hunt: StandardMaterial3D


func _init() -> void:
	collision_layer = AfLocationBuilder.LAYER_ZOMBIE
	collision_mask = AfLocationBuilder.LAYER_WORLD | AfLocationBuilder.LAYER_PLAYER
	_shape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.75
	_shape.shape = cap
	_shape.position = Vector3(0, 0.875, 0)
	add_child(_shape)
	agent = NavigationAgent3D.new()
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.8
	agent.radius = 0.4
	add_child(agent)
	if _overlay_mat == null:
		_overlay_mat = StandardMaterial3D.new()
		_overlay_mat.albedo_color = Color(1, 0.9, 0.85, 0.65)
		_overlay_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_overlay_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_eye_idle = AfLocationBuilder.mat(Color("3a3a2a"), 0.5, Color("a0a060") * 0.4)
		_eye_hunt = AfLocationBuilder.mat(Color("ff3a20"), 0.5, Color("ff2a10") * 3.0)


func setup(p_def: Dictionary, pos: Vector3, p_hp: float = -1.0) -> void:
	def = p_def
	type_id = str(def["id"])
	hp = float(def["hp"]) if p_hp < 0.0 else p_hp
	position = pos
	home = pos
	facing = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	state = S.DORMANT if def.get("behavior") == "lurker" else S.IDLE
	memory_t = 0.0
	attack_cd = randf() * 1.0
	windup_t = -1.0
	aware_of_player = false
	corpse_items = []
	corpse_searched = false
	collision_layer = AfLocationBuilder.LAYER_ZOMBIE
	_shape.disabled = false
	_anim_t = randf() * 10.0
	_build_visual()


func _build_visual() -> void:
	if _visual:
		_visual.queue_free()
	_visual = Node3D.new()
	add_child(_visual)
	var col := Color(def.get("color", "#6f7a5e"))
	var sc := float(def.get("scale", 1.0))
	_visual.scale = Vector3.ONE * sc
	var body_m := AfLocationBuilder.mat(col)
	_body_mi = MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.32
	cap.height = 1.45
	cap.radial_segments = 10
	cap.rings = 4
	_body_mi.mesh = cap
	_body_mi.material_override = body_m
	_body_mi.position = Vector3(0, 0.75, 0)
	_visual.add_child(_body_mi)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	sm.radial_segments = 8
	sm.rings = 4
	head.mesh = sm
	head.material_override = AfLocationBuilder.mat(col.lightened(0.15))
	head.position = Vector3(0, 1.6, 0.05)
	_visual.add_child(head)
	for sx in [-0.3, 0.3]:
		var arm := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.12, 0.12, 0.6)
		arm.mesh = bm
		arm.material_override = body_m
		arm.position = Vector3(sx, 1.25, 0.3)
		_visual.add_child(arm)
	_eyes = MeshInstance3D.new()
	var em := BoxMesh.new()
	em.size = Vector3(0.22, 0.05, 0.05)
	_eyes.mesh = em
	_eyes.material_override = _eye_idle
	_eyes.position = Vector3(0, 1.63, 0.2)
	_eyes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(_eyes)
	if float(def.get("armor", 0.0)) > 0.3:
		var helmet := MeshInstance3D.new()
		var hb := BoxMesh.new()
		hb.size = Vector3(0.48, 0.28, 0.5)
		helmet.mesh = hb
		helmet.material_override = AfLocationBuilder.mat(Color("1a1e24"), 0.3)
		helmet.position = Vector3(0, 1.72, 0)
		_visual.add_child(helmet)
		var vest := MeshInstance3D.new()
		var vb := BoxMesh.new()
		vb.size = Vector3(0.75, 0.6, 0.5)
		vest.mesh = vb
		vest.material_override = AfLocationBuilder.mat(Color("232a33"), 0.6)
		vest.position = Vector3(0, 1.05, 0)
		_visual.add_child(vest)
	_visual.rotation = Vector3.ZERO
	_visual.position = Vector3.ZERO
	if state == S.DORMANT:
		_visual.scale.y = sc * 0.6
	_face(facing)


func is_dead() -> bool:
	return state == S.DEAD


func is_hunting() -> bool:
	return state == S.CHASE or state == S.ATTACK


# --- perception / decisions --------------------------------------------------

func think(dt: float) -> void:
	if state == S.DEAD or player == null:
		return
	var to_p := player.global_position - global_position
	to_p.y = 0.0
	var dist := to_p.length()
	var pc: AfPlayerController = player
	var sight := float(def.get("sight", 10.0)) * Session.weather.sight_mult()
	if pc.sneaking:
		sight *= 0.6
	if pc.flashlight_on() and Clock.is_night():
		sight *= 1.6 * float(def.get("light_sensitivity", 1.0))
	if pc.dead:
		sight = 0.0
	var fov := deg_to_rad(float(def.get("fov_deg", 110.0)))
	var in_fov := fov >= TAU - 0.01 or facing.angle_to(to_p.normalized()) <= fov * 0.5
	var seen: bool = dist < sight and in_fov and manager.has_los(self, pc)
	var smelled := dist < float(def.get("smell", 2.0)) and not pc.dead
	if state == S.DORMANT:
		# ambush predator: wakes only when prey is very close or loud noise nearby
		if (seen or smelled) and dist < 4.5:
			_wake()
		return
	if seen or smelled:
		target_pos = player.global_position
		memory_t = float(def.get("memory_sec", 12.0))
		if not is_hunting() and state != S.STAGGER:
			_start_chase()
	else:
		memory_t -= dt
		if is_hunting() and memory_t <= 0.0:
			state = S.INVESTIGATE  # go to the last known position
			aware_of_player = false
	match state:
		S.IDLE:
			wander_t -= dt
			if wander_t <= 0.0:
				wander_t = randf_range(4.0, 10.0)
				target_pos = home + Vector3(randf_range(-6, 6), 0, randf_range(-6, 6))
				state = S.WANDER
		S.WANDER, S.INVESTIGATE:
			var d := (target_pos - global_position)
			d.y = 0.0
			if d.length() < 1.2:
				if state == S.INVESTIGATE:
					home = global_position  # stays around where the noise was
				state = S.IDLE
				wander_t = randf_range(2.0, 6.0)


func hear(pos: Vector3, loudness: float) -> void:
	if state == S.DEAD or is_hunting():
		return
	if state == S.DORMANT:
		if global_position.distance_to(pos) < 10.0 and loudness > 20.0:
			_wake()
			target_pos = pos
		return
	target_pos = pos
	state = S.INVESTIGATE
	memory_t = float(def.get("memory_sec", 12.0)) * 0.5


func _wake() -> void:
	_visual.scale.y = float(def.get("scale", 1.0))
	_start_chase()


func _start_chase() -> void:
	state = S.CHASE
	aware_of_player = true
	_eyes.material_override = _eye_hunt
	# groan: alerts nearby infected (group behaviour)
	manager.alert(global_position, 9.0, self)


# --- movement / combat -------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not active or state == S.DEAD:
		return
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_body_mi.material_overlay = null
	attack_cd = maxf(0.0, attack_cd - delta)
	if state == S.STAGGER:
		stagger_t -= delta
		velocity = velocity.lerp(Vector3.ZERO, 0.2)
		move_and_slide()
		if stagger_t <= 0.0:
			state = S.CHASE if aware_of_player else S.IDLE
		_animate(delta, 0.0)
		return
	var speed := 0.0
	var dest := target_pos
	match state:
		S.WANDER, S.INVESTIGATE:
			speed = float(def["speed_walk"]) * (1.25 if state == S.INVESTIGATE else 1.0)
		S.CHASE, S.ATTACK:
			speed = float(def.get("speed_run", def["speed_walk"]))
			dest = player.global_position if memory_t > 0.0 else target_pos
	speed *= Session.weather.move_mult()
	var to_p := player.global_position - global_position
	to_p.y = 0.0
	var dist := to_p.length()
	# attack handling
	if is_hunting() and dist <= float(def.get("attack_range", 1.3)) + 0.2:
		state = S.ATTACK
		_face(to_p.normalized())
		speed = 0.0
		if windup_t < 0.0 and attack_cd <= 0.0:
			windup_t = WINDUP
	elif state == S.ATTACK:
		state = S.CHASE
	if windup_t >= 0.0:
		windup_t -= delta
		if windup_t < 0.0:
			attack_cd = float(def.get("attack_cooldown", 1.4))
			if dist <= float(def.get("attack_range", 1.3)) + 0.5 and not (player as AfPlayerController).dead:
				(player as AfPlayerController).receive_hit(self)
	var dir := Vector3.ZERO
	if speed > 0.0:
		dir = _steer(dest, dist, delta)
		if dir.length() > 0.01:
			_face(dir)
	var sep: Vector3 = manager.separation(self)
	velocity = dir * speed + sep
	velocity.y = 0.0
	move_and_slide()
	global_position.y = 0.0
	_animate(delta, speed)


func _steer(dest: Vector3, dist_to_player: float, delta: float) -> Vector3:
	var straight := dest - global_position
	straight.y = 0.0
	if straight.length() < 0.3:
		return Vector3.ZERO
	# close & visible: direct pursuit is cheaper and looks better
	if not manager.nav_ready or (is_hunting() and dist_to_player < 3.0):
		return straight.normalized()
	_path_refresh -= delta
	if _path_refresh <= 0.0:
		_path_refresh = 0.5 if is_hunting() else 1.5
		agent.target_position = dest
	if agent.is_navigation_finished():
		return straight.normalized()
	var nxt := agent.get_next_path_position() - global_position
	nxt.y = 0.0
	return nxt.normalized() if nxt.length() > 0.05 else straight.normalized()


func _face(dir: Vector3) -> void:
	if dir.length() < 0.01:
		return
	facing = dir.normalized()
	if _visual:
		_visual.rotation.y = atan2(facing.x, facing.z)


func _animate(delta: float, speed: float) -> void:
	if not _visual or not _visual.visible:
		return
	_anim_t += delta * (2.0 + speed * 2.5)
	_visual.position.y = absf(sin(_anim_t)) * 0.06 * minf(speed, 2.0)
	_visual.rotation.z = sin(_anim_t * 0.5) * 0.08
	if windup_t >= 0.0:
		_visual.rotation.x = -0.25
	else:
		_visual.rotation.x = lerpf(_visual.rotation.x, 0.12 if is_hunting() else 0.0, 0.2)


## kind: "melee" | "bullet". Returns true if this hit killed the zombie.
func take_damage(amount: float, from_dir: Vector3, kind: String) -> bool:
	if state == S.DEAD:
		return false
	var armor := float(def.get("armor", 0.0))
	var dmg := amount * (1.0 - armor * (1.0 if kind == "bullet" else 0.6))
	hp -= dmg
	_body_mi.material_overlay = _overlay_mat
	_flash_t = 0.08
	target_pos = player.global_position
	memory_t = float(def.get("memory_sec", 12.0))
	if state == S.DORMANT:
		_wake()
	elif not is_hunting():
		_start_chase()
	if hp <= 0.0:
		_die(from_dir)
		return true
	if kind == "melee" and randf() < (0.6 if armor < 0.3 else 0.15):
		state = S.STAGGER
		stagger_t = 0.5
		windup_t = -1.0
		velocity = from_dir.normalized() * 3.0
	return false


func _die(from_dir: Vector3) -> void:
	state = S.DEAD
	collision_layer = 0
	_shape.disabled = true
	velocity = Vector3.ZERO
	died_at_msec = Time.get_ticks_msec()
	_eyes.material_override = _eye_idle
	_visual.rotation = Vector3(-PI / 2.0, atan2(from_dir.x, from_dir.z) if from_dir.length() > 0.01 else 0.0, 0)
	_visual.position = Vector3(0, 0.3, 0)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var table := RegistryHelpers.full_id_for(str(def.get("loot_table", "zombie_pockets")), str(def.get("_package", "core")), "loot_table")
	corpse_items = AfInventory.roll_loot(table, rng)
	manager.on_zombie_died(self)
	EventBus.zombie_killed.emit(type_id, global_position)


func set_active(on: bool) -> void:
	# inactive infected are frozen (not simulated) but stay visible
	active = on
	set_physics_process(on)
