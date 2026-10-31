class_name AfWeather
extends RefCounted
## Seasonal weather: hourly Markov transitions weighted by the climate
## definition of the current season, ambient temperature with a daily cycle.
## Effects are exposed as multipliers consumed by survival, AI and rendering.

const NAMES := {"clear": "Ясно", "cloudy": "Облачно", "rain": "Дождь", "fog": "Туман", "snow": "Снег", "storm": "Буря"}
const EFFECTS := {
	#            temp   sight  hearing move  wet
	"clear":  [0.0,   1.0,   1.0,    1.0,  0.0],
	"cloudy": [-1.0,  0.95,  1.0,    1.0,  0.0],
	"rain":   [-2.5,  0.8,   0.65,   0.95, 0.8],
	"fog":    [-1.0,  0.5,   1.0,    1.0,  0.2],
	"snow":   [-3.0,  0.75,  0.85,   0.85, 0.4],
	"storm":  [-4.0,  0.55,  0.5,    0.8,  1.0],
}

var current := "cloudy"
var hours_in_state := 0.0
var temperature := 8.0
var _rng := RandomNumberGenerator.new()


func new_game() -> void:
	_rng.randomize()
	current = "cloudy"
	hours_in_state = 0.0
	update_temperature()


func climate() -> Dictionary:
	for c in Registry.all("climate"):
		if c["season"] == Clock.season():
			return c
	return {"base_temp": 8.0, "daily_amp": 5.0, "weather": {"clear": 1, "cloudy": 1}}


func simulate(dt_minutes: float) -> void:
	var hours := dt_minutes / 60.0
	hours_in_state += hours
	# chance of a change grows with time spent in the current state
	var p_change := clampf(0.08 * hours * (1.0 + hours_in_state / 6.0), 0.0, 0.95)
	if _rng.randf() < p_change:
		var w: Dictionary = climate()["weather"]
		var total := 0.0
		for k in w:
			total += float(w[k])
		var pick := _rng.randf() * total
		for k in w:
			pick -= float(w[k])
			if pick <= 0.0:
				if k != current and NAMES.has(k):
					current = k
					hours_in_state = 0.0
				break
	update_temperature()


func update_temperature() -> void:
	var c := climate()
	var h := Clock.hour_float()
	var daily := sin((h - 9.0) / 24.0 * TAU) * float(c.get("daily_amp", 5.0))
	var t: float = float(c["base_temp"]) + daily + float(EFFECTS[current][0])
	if current == "clear" and Clock.is_night():
		t -= 3.0
	temperature = t


func sight_mult() -> float:
	var night := 0.55 if Clock.is_night() else 1.0
	return EFFECTS[current][1] * night


func hearing_mult() -> float:
	return EFFECTS[current][2]


func move_mult() -> float:
	var m: float = EFFECTS[current][3]
	if temperature < -2.0 and current in ["rain", "snow"]:
		m *= 0.9 # ice
	return m


func wetness() -> float:
	return EFFECTS[current][4]


func is_icy() -> bool:
	return temperature < 0.0 and current in ["rain", "snow", "storm"]


func label() -> String:
	return "%s %+.0f°C" % [NAMES.get(current, current), temperature]


func save_key() -> String:
	return "weather"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS weather (id INTEGER PRIMARY KEY, current TEXT, hours_in_state REAL, temperature REAL)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("INSERT OR REPLACE INTO weather VALUES (1, ?, ?, ?)", [current, hours_in_state, temperature])


func load_from_db(db: AfDatabase) -> void:
	_rng.randomize()
	var rows := db.select("SELECT * FROM weather WHERE id = 1")
	if rows.size() > 0:
		current = str(rows[0]["current"]) if NAMES.has(str(rows[0]["current"])) else "cloudy"
		hours_in_state = float(rows[0]["hours_in_state"])
		temperature = float(rows[0]["temperature"])
