extends Node
## Watches frame time and, when adaptive quality is enabled, lowers the 3D
## render scale step by step if the device can't keep its target frame rate for
## a sustained period (a proxy for thermal throttling, which Godot doesn't expose
## directly). Restores quality slowly when there's headroom again.
## Also collects memory statistics for the debug overlay.

const WINDOW_SEC := 6.0
const MIN_SCALE := 0.5

var _accum := 0.0
var _frames := 0
var _slow_windows := 0
var _fast_windows := 0
var current_scale := 1.0
var last_avg_fps := 0.0


func _ready() -> void:
	Settings.profile_applied.connect(func(_n): current_scale = float(Settings.p("render_scale")))
	current_scale = float(Settings.p("render_scale"))


func _process(delta: float) -> void:
	_accum += delta
	_frames += 1
	if _accum < WINDOW_SEC:
		return
	last_avg_fps = _frames / _accum
	_accum = 0.0
	_frames = 0
	if not bool(Settings.get_value("graphics/adaptive_quality")) or DisplayServer.get_name() == "headless":
		return
	var target := float(Settings.p("max_fps"))
	if last_avg_fps < target * 0.8:
		_slow_windows += 1
		_fast_windows = 0
	elif last_avg_fps > target * 0.97:
		_fast_windows += 1
		_slow_windows = 0
	if _slow_windows >= 2 and current_scale > MIN_SCALE:
		current_scale = maxf(MIN_SCALE, current_scale - 0.1)
		get_viewport().scaling_3d_scale = current_scale
		_slow_windows = 0
		Log.i("perf", "adaptive quality: render scale -> %.2f (fps %.1f)" % [current_scale, last_avg_fps])
	elif _fast_windows >= 5 and current_scale < float(Settings.p("render_scale")):
		current_scale = minf(float(Settings.p("render_scale")), current_scale + 0.05)
		get_viewport().scaling_3d_scale = current_scale
		_fast_windows = 0


func stats_text() -> String:
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var objs := Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var draw := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	return "FPS %d | RAM %.0f МБ | узлов %d | объектов %d | draw %d | масштаб %.2f | профиль %s" % [
		Engine.get_frames_per_second(), mem, nodes, objs, draw, current_scale, Settings.active_profile_name]
