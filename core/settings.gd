extends Node
## Persistent user settings + device performance profiles + input map.

signal changed(key: String)
signal profile_applied(profile_name: String)

const PATH := "user://settings.cfg"

## Performance profiles. Every heavy system reads its budget from here instead of
## hard-coding values, so the simulation scales with the device.
const PROFILES := {
	"low": {
		"label": "Низкий",
		"max_active_zombies": 10,
		"ai_far_think_interval": 6,
		"sim_budget_ms": 2.0,
		"sim_interval_mult": 2.0,
		"shadows": false,
		"shadow_size": 1024,
		"render_scale": 0.7,
		"particles": false,
		"max_fps": 30,
		"msaa": 0,
		"dynamic_lights": 2,
		"prop_visibility_range": 35.0,
		"asset_cache_mb": 96,
		"occluders": false,
	},
	"medium": {
		"label": "Средний",
		"max_active_zombies": 20,
		"ai_far_think_interval": 4,
		"sim_budget_ms": 3.0,
		"sim_interval_mult": 1.5,
		"shadows": true,
		"shadow_size": 2048,
		"render_scale": 0.85,
		"particles": true,
		"max_fps": 30,
		"msaa": 0,
		"dynamic_lights": 4,
		"prop_visibility_range": 55.0,
		"asset_cache_mb": 192,
		"occluders": true,
	},
	"high": {
		"label": "Высокий",
		"max_active_zombies": 36,
		"ai_far_think_interval": 2,
		"sim_budget_ms": 4.0,
		"sim_interval_mult": 1.0,
		"shadows": true,
		"shadow_size": 4096,
		"render_scale": 1.0,
		"particles": true,
		"max_fps": 60,
		"msaa": 2,
		"dynamic_lights": 8,
		"prop_visibility_range": 90.0,
		"asset_cache_mb": 384,
		"occluders": true,
	},
}

const DEFAULTS := {
	"graphics/profile": "auto",
	"graphics/show_fps": false,
	"graphics/adaptive_quality": true,
	"game/autosave_minutes": 120,
	"game/camera_zoom": 22.0,
	"audio/master": 0.8,
	"content/wifi_only": true,
	"content/auto_check_updates": true,
	"content/max_parallel_downloads": 2,
	"content/server_override": "",
	"content/channel": "stable",
}

var _cfg := ConfigFile.new()
var active_profile_name := "medium"
var profile: Dictionary = PROFILES["medium"]


func _enter_tree() -> void:
	AfPaths.ensure_dirs()
	_cfg.load(PATH)
	_setup_input_map()
	apply_profile()


func get_value(key: String) -> Variant:
	var parts := key.split("/")
	return _cfg.get_value(parts[0], parts[1], DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	var parts := key.split("/")
	_cfg.set_value(parts[0], parts[1], value)
	_cfg.save(PATH)
	changed.emit(key)
	if key == "graphics/profile":
		apply_profile()


func detect_profile() -> String:
	var cores := OS.get_processor_count()
	var mem: Dictionary = OS.get_memory_info()
	var physical_gb := float(mem.get("physical", 0)) / 1073741824.0
	if OS.get_name() != "Android":
		return "high" if cores >= 4 else "medium"
	if physical_gb > 0.0 and physical_gb < 4.5 or cores < 6:
		return "low"
	if physical_gb >= 7.5 and cores >= 8:
		return "high"
	return "medium"


func apply_profile() -> void:
	var wanted := str(get_value("graphics/profile"))
	if wanted == "auto" or not PROFILES.has(wanted):
		wanted = detect_profile()
	active_profile_name = wanted
	profile = PROFILES[wanted].duplicate()
	Engine.max_fps = int(profile["max_fps"])
	if not DisplayServer.get_name() == "headless":
		var vp := get_viewport()
		if vp:
			vp.scaling_3d_scale = float(profile["render_scale"])
			vp.msaa_3d = int(profile["msaa"]) as Viewport.MSAA
		RenderingServer.directional_shadow_atlas_set_size(int(profile["shadow_size"]), true)
	profile_applied.emit(wanted)


func p(key: String) -> Variant:
	return profile.get(key)


func _setup_input_map() -> void:
	var binds := {
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT],
		"sneak": [KEY_C],
		"attack": [KEY_SPACE],
		"fire": [KEY_F],
		"reload": [KEY_R],
		"interact": [KEY_E],
		"flashlight": [KEY_L],
		"inventory": [KEY_I, KEY_TAB],
		"map": [KEY_M],
		"character": [KEY_K],
		"menu": [KEY_ESCAPE],
		"zoom_in": [KEY_EQUAL, KEY_KP_ADD],
		"zoom_out": [KEY_MINUS, KEY_KP_SUBTRACT],
		"speed_pause": [KEY_P],
		"speed_1": [KEY_1],
		"speed_2": [KEY_2],
		"speed_3": [KEY_3],
		"quick_save": [KEY_F5],
	}
	for action in binds:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in binds[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
