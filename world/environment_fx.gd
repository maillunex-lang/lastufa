class_name AfEnvironmentFx
extends Node3D
## Day/night lighting, sky color, fog and precipitation particles driven by
## the clock and the weather system. Updated a few times per second, not per
## frame, to save battery.

var sun: DirectionalLight3D
var env: Environment
var _rain: GPUParticles3D
var _snow: GPUParticles3D
var follow: Node3D
var _t := 0.0


func _ready() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.01
	env.glow_enabled = Settings.active_profile_name == "high"
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = bool(Settings.p("shadows"))
	sun.directional_shadow_max_distance = 60.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(sun)
	if bool(Settings.p("particles")):
		_rain = _make_particles(Color(0.7, 0.75, 0.85, 0.5), Vector2(0.03, 0.7), -38.0, 900 if Settings.active_profile_name == "high" else 450, 0.55)
		_snow = _make_particles(Color(1, 1, 1, 0.9), Vector2(0.09, 0.09), -2.5, 700 if Settings.active_profile_name == "high" else 350, 5.0)
	update_now()


func _make_particles(color: Color, quad: Vector2, gravity: float, amount: int, lifetime: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-25, -20, -25), Vector3(50, 40, 50))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(22, 1, 22)
	pm.gravity = Vector3(1.5 if gravity > -10.0 else 0.0, gravity, 0)
	pm.direction = Vector3(0, -1, 0)
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 2.0
	if gravity > -10.0:
		pm.turbulence_enabled = true
		pm.turbulence_noise_strength = 0.6
	p.process_material = pm
	var qm := QuadMesh.new()
	qm.size = quad
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y if gravity < -10.0 else BaseMaterial3D.BILLBOARD_ENABLED
	qm.material = m
	p.draw_pass_1 = qm
	p.position = Vector3(0, 16, 0)
	add_child(p)
	return p


func _process(delta: float) -> void:
	if follow:
		var fp := follow.global_position
		for p in [_rain, _snow]:
			if p:
				p.global_position = Vector3(fp.x, 16.0, fp.z)
	_t -= delta
	if _t <= 0.0:
		_t = 0.25
		update_now()


func update_now() -> void:
	var h := Clock.hour_float()
	var day := Clock.daylight()
	var w := Session.weather
	var overcast := 0.0
	match w.current:
		"cloudy": overcast = 0.35
		"rain", "snow": overcast = 0.55
		"fog": overcast = 0.45
		"storm": overcast = 0.75
	var elev := clampf(sin((h - 6.0) / 24.0 * TAU), -1.0, 1.0) * 62.0
	sun.rotation_degrees = Vector3(-maxf(elev, 12.0), -30.0 + (h - 12.0) * 9.0, 0)
	sun.light_energy = lerpf(0.06, 1.25, day) * (1.0 - overcast * 0.6)
	sun.light_color = Color("aab8e0").lerp(Color("fff1dc"), day)
	if day < 0.3:
		sun.light_color = sun.light_color.lerp(Color("ff9a60"), (0.3 - day) * 2.0 * float(elev > 0.0))
	var amb_day := Color(0.55, 0.55, 0.52).lerp(Color(0.48, 0.5, 0.54), overcast)
	env.ambient_light_color = Color(0.05, 0.06, 0.1).lerp(amb_day, day)
	env.ambient_light_energy = lerpf(0.35, 0.65, day)
	var sky := Color("0c0e14").lerp(Color("8f98a3").lerp(Color("6f7680"), overcast), day)
	env.background_color = sky
	env.fog_light_color = sky.lightened(0.05)
	var fog := 0.004
	match w.current:
		"fog": fog = 0.045
		"rain": fog = 0.012
		"snow": fog = 0.02
		"storm": fog = 0.025
	env.fog_density = fog
	if _rain:
		_rain.emitting = w.current in ["rain", "storm"] and w.temperature > 0.5
	if _snow:
		_snow.emitting = w.current in ["snow"] or (w.current in ["rain", "storm"] and w.temperature <= 0.5)
