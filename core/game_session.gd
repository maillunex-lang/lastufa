extends Node
## The running game: owns all persistent systems, wires them to the clock and
## scheduler, and exposes them to the scene/UI. One session at a time.

var active := false
var offline_mode := false
var slot := ""

var player := AfPlayerState.new()
var world_map := AfWorldMap.new()
var weather := AfWeather.new()
var journal := AfJournal.new()
var locations := AfLocationStates.new()
var rules := AfRuleEngine.new()
## Difficulty and enabled needs of the current playthrough.
var config := AfGameConfig.new()
var survivors := AfSurvivors.new()
var base := AfBase.new()
var events := AfBaseEvents.new()

## Environment inputs written by the 3D scene each frame.
var threat_nearby := false
var player_exertion := 0.0

const NEW_GAME_START_MINUTES := 6.0 * 60.0 + 30.0


func persistables() -> Array:
	return [Clock, config, player, world_map, weather, journal, locations, rules, survivors, base, events]


## params: {difficulty: easy|normal|hard|nightmare, hunger: bool, thirst: bool}
func new_game(params: Dictionary = {}) -> void:
	end_session()
	config.setup(params)
	Clock.start(NEW_GAME_START_MINUTES)
	Clock.set_speed(0)
	player.new_game()
	world_map.new_game()
	weather.new_game()
	journal.clear()
	locations.clear()
	rules.clear()
	survivors.clear()
	base.clear()
	events.clear()
	journal.add("story", "14 сентября. Третий день без связи. Утром соседка с пятого этажа укусила мужа. К обеду весь двор кричал. Надо выбираться из Черниковки.")
	_begin()


func start_from_db(db: AfDatabase) -> void:
	end_session()
	for p in persistables():
		p.load_from_db(db)
	_begin()


func _begin() -> void:
	slot = slot if slot != "" else "slot_1"
	_register_tasks()
	_connect_events()
	active = true
	var lock := FileAccess.open(AfPaths.SESSION_LOCK, FileAccess.WRITE)
	if lock:
		lock.store_string(slot)
		lock.close()
	EventBus.session_started.emit()
	rules.dispatch("session_started", {})


func end_session() -> void:
	if not active:
		return
	EventBus.session_ending.emit()
	Scheduler.clear()
	Clock.stop()
	_disconnect_events()
	active = false
	if FileAccess.file_exists(AfPaths.SESSION_LOCK):
		DirAccess.remove_absolute(AfPaths.SESSION_LOCK)
	EventBus.session_ended.emit()


func _register_tasks() -> void:
	Scheduler.clear()
	Scheduler.register("survival", Scheduler.Tier.LOCAL, 2.0, _tick_survival, 30.0)
	Scheduler.register("inventory_spoilage", Scheduler.Tier.LOCAL, 30.0, func(dt): player.inventory.simulate(dt), 240.0)
	Scheduler.register("weather", Scheduler.Tier.REGIONAL, 60.0, func(dt): weather.simulate(dt), 120.0)
	Scheduler.register("base", Scheduler.Tier.REGIONAL, 60.0, func(dt): base.simulate(dt), 240.0)
	Scheduler.register("zombie_migration", Scheduler.Tier.STRATEGIC, 360.0, func(dt): world_map.simulate(dt), 1440.0)
	Scheduler.register("autosave", Scheduler.Tier.LOCAL, float(Settings.get_value("game/autosave_minutes")), _autosave_tick, 100000.0)


func _tick_survival(dt: float) -> void:
	var s := player.survival
	if s.dead:
		return
	s.ambient_temp = weather.temperature
	s.insulation = player.insulation()
	s.wet = weather.wetness() * (1.0 - player.rain_protection())
	s.exertion = player_exertion
	s.threat_nearby = threat_nearby
	s.protected_floor = 25.0 if offline_mode else -1.0
	s.need_rate_mult = config.p("need_rate")
	s.disabled_needs = config.disabled_needs()
	s.simulate(dt)
	if s.dead:
		journal.add("death", "Погиб: %s." % s.death_cause)
		EventBus.player_died.emit(s.death_cause)


func _autosave_tick(_dt: float) -> void:
	if not offline_mode and not player.survival.dead:
		Saves.request_autosave()


var _connected := false


func _connect_events() -> void:
	if _connected:
		return
	_connected = true
	Clock.day_changed.connect(_on_day)
	Clock.hour_changed.connect(_on_hour)
	EventBus.zombie_killed.connect(_on_zombie_killed)
	EventBus.item_used.connect(_on_item_used)
	EventBus.location_entered.connect(_on_location_entered)
	EventBus.container_looted.connect(_on_container_looted)
	EventBus.region_visited.connect(_on_region_visited)


func _disconnect_events() -> void:
	if not _connected:
		return
	_connected = false
	Clock.day_changed.disconnect(_on_day)
	Clock.hour_changed.disconnect(_on_hour)
	EventBus.zombie_killed.disconnect(_on_zombie_killed)
	EventBus.item_used.disconnect(_on_item_used)
	EventBus.location_entered.disconnect(_on_location_entered)
	EventBus.container_looted.disconnect(_on_container_looted)
	EventBus.region_visited.disconnect(_on_region_visited)


func _on_day(day: int) -> void:
	rules.dispatch("day_passed", {"day": day})


func _on_hour(hour: int, day: int) -> void:
	rules.dispatch("hour_passed", {"hour": hour, "day": day})


func _on_zombie_killed(type_id: String, _pos: Vector3) -> void:
	player.kills += 1
	rules.dispatch("zombie_killed", {"type": type_id, "kills": player.kills})


func _on_item_used(item_id: String) -> void:
	rules.dispatch("item_used", {"item": item_id})


func _on_location_entered(loc: String) -> void:
	rules.dispatch("location_entered", {"location": loc})


func _on_container_looted(cid: String, loc: String) -> void:
	rules.dispatch("container_looted", {"container": cid, "location": loc})


func _on_region_visited(rid: String) -> void:
	rules.dispatch("region_visited", {"region": rid})


## Simulates time that passed while the game was closed. Limited: 1 real
## minute = 1 game minute, at most 24 game hours. The hero is protected:
## needs and health can't drop below 25 while offline.
func apply_offline_progress(real_seconds: float) -> Dictionary:
	var minutes := clampf(real_seconds / 60.0, 0.0, 24.0 * 60.0)
	if minutes < 10.0:
		return {"minutes": 0.0, "entries": []}
	var t0 := Clock.total_minutes
	offline_mode = true
	player.survival.sleeping = false
	Scheduler.fast_forward(minutes, 60.0, [Scheduler.Tier.REGIONAL, Scheduler.Tier.STRATEGIC])
	# needs: run survival once over the whole span in protected mode
	_tick_survival(minutes)
	Scheduler.reset_accumulators([Scheduler.Tier.LOCAL])
	offline_mode = false
	player.survival.protected_floor = -1.0
	journal.add("offline", "Прошло %.1f ч, пока вас не было." % (minutes / 60.0))
	return {"minutes": minutes, "entries": journal.since(t0)}
