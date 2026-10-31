extends Node
## Hybrid game time. Time flows while a session is active and not paused.
## Any system can push a pause reason (decision dialogs, menus); time resumes
## only when every reason is released. Large jumps (sleep, travel, offline
## progress) go through Scheduler.fast_forward(), which calls advance() in chunks.

signal advanced(dt_minutes: float)
signal hour_changed(hour: int, day: int)
signal day_changed(day: int)
signal season_changed(season: String)
signal speed_changed(index: int)
signal pause_changed(paused: bool)

## Game minutes per real second at 1x speed (1 real sec = 1 game minute).
const BASE_RATE := 1.0
const SPEEDS := [1.0, 2.0, 4.0]
## Calendar: the outbreak starts on 14 September (day-of-year 257).
const START_DAY_OF_YEAR := 257
const MONTHS := ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
const MONTH_DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const SEASON_NAMES := {"winter": "Зима", "spring": "Весна", "summer": "Лето", "autumn": "Осень"}

var total_minutes := 0.0
var running := false
var speed_index := 0
var _pause_reasons := {}
var _last_hour := -1
var _last_day := -1
var _last_season := ""


func _process(delta: float) -> void:
	if not running or is_paused():
		return
	advance(delta * BASE_RATE * SPEEDS[speed_index])


func start(at_minutes: float) -> void:
	total_minutes = at_minutes
	_last_hour = hour()
	_last_day = day()
	_last_season = season()
	_pause_reasons.clear()
	running = true


func stop() -> void:
	running = false
	_pause_reasons.clear()


func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	total_minutes += dt
	advanced.emit(dt)
	var h := hour()
	var d := day()
	if h != _last_hour or d != _last_day:
		_last_hour = h
		hour_changed.emit(h, d)
	if d != _last_day:
		_last_day = d
		day_changed.emit(d)
		var s := season()
		if s != _last_season:
			_last_season = s
			season_changed.emit(s)


func set_speed(index: int) -> void:
	speed_index = clampi(index, 0, SPEEDS.size() - 1)
	speed_changed.emit(speed_index)


func push_pause(reason: String) -> void:
	var was := is_paused()
	_pause_reasons[reason] = true
	if not was:
		pause_changed.emit(true)


func release_pause(reason: String) -> void:
	var was := is_paused()
	_pause_reasons.erase(reason)
	if was and not is_paused():
		pause_changed.emit(false)


func toggle_user_pause() -> void:
	if _pause_reasons.has("user"):
		release_pause("user")
	else:
		push_pause("user")


func is_paused() -> bool:
	return not _pause_reasons.is_empty()


func has_pause(reason: String) -> bool:
	return _pause_reasons.has(reason)


# --- calendar ---------------------------------------------------------------

func day() -> int:
	return int(floor(total_minutes / 1440.0)) + 1


func hour() -> int:
	return int(floor(fmod(total_minutes, 1440.0) / 60.0))


func minute() -> int:
	return int(fmod(total_minutes, 60.0))


func hour_float() -> float:
	return fmod(total_minutes, 1440.0) / 60.0


func day_of_year() -> int:
	return (START_DAY_OF_YEAR + day() - 2) % 365 + 1


func season() -> String:
	var doy := day_of_year()
	if doy < 60 or doy >= 335:
		return "winter"
	if doy < 152:
		return "spring"
	if doy < 244:
		return "summer"
	return "autumn"


func season_name() -> String:
	return SEASON_NAMES[season()]


func date_text() -> String:
	var doy := day_of_year()
	var m := 0
	while m < 11 and doy > MONTH_DAYS[m]:
		doy -= MONTH_DAYS[m]
		m += 1
	return "%d %s" % [doy, MONTHS[m]]


func time_text() -> String:
	return "%02d:%02d" % [hour(), minute()]


func is_night() -> bool:
	var h := hour_float()
	return h < 6.0 or h >= 21.0


## 0 at midnight, 1 at noon; used for lighting and temperature.
func daylight() -> float:
	return clampf(sin((hour_float() - 6.0) / 24.0 * TAU) * 1.2 + 0.1, 0.0, 1.0)


# --- persistence (Persistable interface) -------------------------------------

func save_key() -> String:
	return "clock"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS clock (id INTEGER PRIMARY KEY, total_minutes REAL, speed_index INTEGER)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("INSERT OR REPLACE INTO clock VALUES (1, ?, ?)", [total_minutes, speed_index])


func load_from_db(db: AfDatabase) -> void:
	var rows := db.select("SELECT * FROM clock WHERE id = 1")
	if rows.size() > 0:
		start(float(rows[0]["total_minutes"]))
		set_speed(int(rows[0]["speed_index"]))
