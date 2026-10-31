class_name AfGameConfig
extends RefCounted
## Per-playthrough rules chosen when starting a new game: difficulty preset
## and which survival needs are simulated. Saved inside the save slot.

const PRESETS := {
	"easy": {"label": "Лёгкая", "desc": "Меньше заражённых и урона, больше припасов, потребности растут медленнее.",
		"zombie_count": 0.6, "zombie_damage": 0.6, "need_rate": 0.6, "loot": 1.5, "infection": 0.5},
	"normal": {"label": "Нормальная", "desc": "Задуманный баланс выживания.",
		"zombie_count": 1.0, "zombie_damage": 1.0, "need_rate": 1.0, "loot": 1.0, "infection": 1.0},
	"hard": {"label": "Тяжёлая", "desc": "Больше заражённых, они бьют сильнее, припасов меньше, голод и жажда быстрее.",
		"zombie_count": 1.3, "zombie_damage": 1.3, "need_rate": 1.25, "loot": 0.75, "infection": 1.3},
	"nightmare": {"label": "Кошмар", "desc": "Город кишит заражёнными, каждый укус опасен, найти еду почти невозможно.",
		"zombie_count": 1.7, "zombie_damage": 1.6, "need_rate": 1.5, "loot": 0.5, "infection": 1.7},
}

var difficulty := "normal"
var hunger_enabled := true
var thirst_enabled := true
## "God game": immortal hero, buildings and items are free and instant.
var god_mode := false


func setup(params: Dictionary) -> void:
	difficulty = str(params.get("difficulty", "normal"))
	if not PRESETS.has(difficulty):
		difficulty = "normal"
	hunger_enabled = bool(params.get("hunger", true))
	thirst_enabled = bool(params.get("thirst", true))
	god_mode = bool(params.get("god", false))


func p(key: String) -> float:
	return float(PRESETS[difficulty].get(key, 1.0))


func label() -> String:
	return str(PRESETS[difficulty]["label"])


## Need ids that are not simulated in this playthrough.
func disabled_needs() -> Array:
	var out := []
	if not hunger_enabled:
		out.append("satiety")
	if not thirst_enabled:
		out.append("hydration")
	return out


func summary() -> String:
	var off := PackedStringArray()
	if not hunger_enabled:
		off.append("без голода")
	if not thirst_enabled:
		off.append("без жажды")
	if god_mode:
		off.append("игра бога")
	return label() + ("" if off.is_empty() else " · " + ", ".join(off))


func save_key() -> String:
	return "config"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS game_config (key TEXT PRIMARY KEY, value TEXT)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("INSERT OR REPLACE INTO game_config VALUES ('rules', ?)",
		[JSON.stringify({"difficulty": difficulty, "hunger": hunger_enabled, "thirst": thirst_enabled, "god": god_mode})])


func load_from_db(db: AfDatabase) -> void:
	setup({})  # saves made before this setting existed play on "normal" with all needs
	if not db.table_exists("game_config"):
		return
	var v: Variant = JSON.parse_string(str(db.scalar("SELECT value FROM game_config WHERE key = 'rules'", [], "{}")))
	if typeof(v) == TYPE_DICTIONARY:
		setup(v)
