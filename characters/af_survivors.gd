class_name AfSurvivors
extends RefCounted
## The people of the settlement. Each survivor is a persistent individual with
## a profession, skills, traits, biography, fear and a secret, needs, mood,
## loyalty, relationships with others and a memory of what happened to them —
## including the leader's decisions, which drive loyalty over time.

const SKILLS := {
	"medicine": "Медицина", "building": "Строительство", "engineering": "Техника", "farming": "Земледелие",
	"cooking": "Кулинария", "combat": "Бой", "scavenging": "Поиск",
}
const JOBS := {
	"idle": "Отдых", "build": "Стройка", "guard": "Охрана", "scavenge": "Вылазка за припасами",
	"workshop": "Мастерская", "infirmary": "Медпункт", "kitchen": "Кухня", "garden": "Огород", "water": "Водосбор", "radio": "Радиостанция",
}
const JOB_SKILL := {
	"build": "building", "guard": "combat", "scavenge": "scavenging", "workshop": "engineering", "infirmary": "medicine",
	"kitchen": "cooking", "garden": "farming", "water": "engineering", "radio": "engineering",
}
const FEARS := ["темноты", "замкнутых пространств", "остаться одному", "собак", "крови", "высоты", "огня", "больниц", "тишины по ночам", "потерять ещё кого-то"]
const SECRETS := [
	"До катастрофы сидел за кражу и никому об этом не говорит.",
	"Прячет в рюкзаке пистолет, о котором никто не знает.",
	"Видел, как всё началось у НИИ «Агидель-Био», но молчит.",
	"Бросил своих родных в первый день, чтобы спастись.",
	"Был укушен месяц назад — и не заразился. Не понимает почему.",
	"Работал на военном объекте в горах и знает частоты «Иремеля-4».",
	"Ищет брата, который ушёл к стадиону «Нефтяник».",
	"Тайком откладывает еду на чёрный день.",
]
const BIO_STARTS := [
	"До катастрофы жил(а) в %s.", "Родом из %s, в Уфе оказался(ась) на заработках.", "Всю жизнь прожил(а) в %s.",
	"Переехал(а) из %s незадолго до вспышки.",
]
const BIO_ENDS := [
	"Потерял(а) связь с семьёй на второй день.", "Выбрался(ась) из города на попутке, которая так и не доехала.",
	"Неделю прятался(ась) на крыше девятиэтажки.", "Был(а) в эвакуационной колонне, которую разметали заражённые.",
	"Ушёл(ла) из пункта сбора, когда там начали стрелять.", "Держится ради дочери, которая осталась у бабушки в деревне.",
]

var people: Array = []      # survivor dictionaries
var _next_id := 1
var _rng := RandomNumberGenerator.new()


func clear() -> void:
	people.clear()
	_next_id = 1
	_rng.randomize()


func at_base() -> Array:
	return people.filter(func(p): return p["status"] == "base")


func living() -> Array:
	return people.filter(func(p): return p["status"] in ["base", "away"])


func find(id: int) -> Dictionary:
	for p in people:
		if int(p["id"]) == id:
			return p
	return {}


## Generates a new random survivor (not yet in the group).
func generate(overrides: Dictionary = {}) -> Dictionary:
	var female := _rng.randf() < 0.5
	var pool := Registry.get_def("name_pool", "female" if female else "male")
	var name := "%s %s" % [_pick(pool.get("first", ["Безымянный"])), _pick(pool.get("last", [""]))]
	var profs := Registry.all("profession")
	var prof := _weighted(profs)
	var skills := {}
	for s in SKILLS:
		skills[s] = _rng.randi_range(0, 2)
	for s in prof.get("skills", {}):
		skills[s] = clampi(int(prof["skills"][s]) + _rng.randi_range(-1, 1), 0, 10)
	var traits := []
	var all_traits := Registry.all("trait").map(func(t): return str(t["id"]))
	while traits.size() < 2 and not all_traits.is_empty():
		var t: String = all_traits[_rng.randi() % all_traits.size()]
		if not traits.has(t) and not (traits.has("core:optimist") and t == "core:pessimist") and not (traits.has("core:pessimist") and t == "core:optimist") \
				and not (traits.has("core:hardworking") and t == "core:lazy") and not (traits.has("core:lazy") and t == "core:hardworking") \
				and not (traits.has("core:brave") and t == "core:coward") and not (traits.has("core:coward") and t == "core:brave"):
			traits.append(t)
	var towns := Registry.all("region").filter(func(r): return r["kind"] in ["city", "town"]).map(func(r): return str(r["name"]))
	var bio: String = (_pick(BIO_STARTS) % (_pick(towns) if not towns.is_empty() else "Уфе")) + " " + _pick(BIO_ENDS)
	var p := {
		"id": 0, "name": name, "female": female, "age": _rng.randi_range(17, 68), "profession": str(prof.get("id", "")),
		"skills": skills, "traits": traits, "bio": bio, "fear": _pick(FEARS), "secret": _pick(SECRETS),
		"health": 100.0, "satiety": 80.0, "hydration": 80.0, "energy": 90.0, "morale": 62.0, "loyalty": 45.0,
		"injury_hours": 0.0, "infected_hours": -1.0, "status": "new", "job": "idle", "away_until": 0.0, "away_target": "",
		"relations": {}, "memory": [], "joined_day": 0, "infected_hidden": _rng.randf() < 0.08,
	}
	for k in overrides:
		p[k] = overrides[k]
	return p


## Adds a survivor to the group.
func add(p: Dictionary) -> Dictionary:
	p["id"] = _next_id
	_next_id += 1
	p["status"] = "base"
	p["joined_day"] = Clock.day()
	for o in living():
		var base := _rng.randf_range(-10.0, 25.0)
		p["relations"][str(o["id"])] = base
		o["relations"][str(p["id"])] = base
	people.append(p)
	remember(p, "Присоединился(ась) к группе.", 5.0)
	return p


func remember(p: Dictionary, text: String, weight: float) -> void:
	p["memory"].append({"t": Clock.total_minutes, "text": text, "w": weight})
	if p["memory"].size() > 30:
		p["memory"] = p["memory"].slice(p["memory"].size() - 30)


## Sum of remembered weights, fading over ~20 days.
func memory_mood(p: Dictionary) -> float:
	var s := 0.0
	for m in p["memory"]:
		var age_days := (Clock.total_minutes - float(m["t"])) / 1440.0
		s += float(m["w"]) * maxf(0.0, 1.0 - age_days / 20.0)
	return clampf(s, -30.0, 30.0)


func trait_value(p: Dictionary, key: String, default_value: float) -> float:
	var v := default_value
	for t in p["traits"]:
		var d := Registry.get_def("trait", str(t))
		if d.has(key):
			if key in ["work", "appetite", "quarrel", "relation_bonus"]:
				v *= float(d[key])
			else:
				v += float(d[key])
	return v


func skill(p: Dictionary, s: String) -> float:
	var v := float(p["skills"].get(s, 0))
	if s == "combat":
		v += trait_value(p, "combat", 0.0)
	return clampf(v, 0.0, 10.0)


func can_work(p: Dictionary) -> bool:
	return p["status"] == "base" and float(p["injury_hours"]) <= 0.0 and float(p["health"]) > 30.0 and float(p.get("infected_hours", -1.0)) < 0.0


## A leader's decision tagged "harsh"/"kind"/"neutral": each person reacts by character.
func react_to_decision(tag: String, text: String, strength: float = 6.0) -> void:
	for p in living():
		var w := 0.0
		for t in p["traits"]:
			var d := Registry.get_def("trait", str(t))
			if tag in d.get("approves", []):
				w += strength
			if tag in d.get("disapproves", []):
				w -= strength
		if w == 0.0:
			continue
		p["loyalty"] = clampf(float(p["loyalty"]) + w * 0.6, 0.0, 100.0)
		remember(p, ("Одобряет: " if w > 0 else "Не одобряет: ") + text, w)


func traits_text(p: Dictionary) -> String:
	return ", ".join(PackedStringArray(p["traits"].map(func(t): return Registry.display_name("trait", str(t)))))


func profession_name(p: Dictionary) -> String:
	return Registry.display_name("profession", str(p["profession"]))


func mood_text(p: Dictionary) -> String:
	var m := float(p["morale"])
	var f := bool(p.get("female", false))
	if m > 75: return g("воодушевлён(а)", f)
	if m > 55: return g("спокоен(на)", f)
	if m > 35: return g("подавлен(а)", f)
	if m > 15: return "на грани"
	return "в отчаянии"


## Resolves gender markers like "жил(а)", "оказался(ась)", "Ушёл(ла)" for display.
static func g(text: String, female: bool) -> String:
	var out := text.replace("Ушёл(ла)", "Ушла" if female else "Ушёл").replace("спокоен(на)", "спокойна" if female else "спокоен")
	var re := RegEx.new()
	re.compile("(\\S*?)ся\\(ась\\)")
	out = re.sub(out, "$1ась" if female else "$1ся", true)
	return out.replace("(а)", "а" if female else "")


func text_of(p: Dictionary, key: String) -> String:
	return g(str(p.get(key, "")), bool(p.get("female", false)))


func _pick(arr: Array) -> Variant:
	return arr[_rng.randi() % arr.size()] if not arr.is_empty() else ""


func _weighted(defs: Array) -> Dictionary:
	var total := 0.0
	for d in defs:
		total += float(d.get("weight", 1.0))
	var r := _rng.randf() * total
	for d in defs:
		r -= float(d.get("weight", 1.0))
		if r <= 0.0:
			return d
	return defs[0] if not defs.is_empty() else {}


# --- persistence -------------------------------------------------------------

func save_key() -> String:
	return "survivors"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS survivors (id INTEGER PRIMARY KEY, status TEXT, data TEXT)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("DELETE FROM survivors")
	for p in people:
		db.exec("INSERT INTO survivors VALUES (?, ?, ?)", [p["id"], p["status"], JSON.stringify(p)])


func load_from_db(db: AfDatabase) -> void:
	clear()
	if not db.table_exists("survivors"):
		return
	for r in db.select("SELECT data FROM survivors ORDER BY id"):
		var p: Variant = JSON.parse_string(str(r["data"]))
		if typeof(p) == TYPE_DICTIONARY:
			p["id"] = int(p["id"])
			people.append(p)
			_next_id = maxi(_next_id, int(p["id"]) + 1)
