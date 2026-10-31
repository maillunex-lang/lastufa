class_name AfBaseEvents
extends RefCounted
## Settlement events that need the leader's decision. Time stops while the
## decision dialog is open. Options are deliberately ambiguous: every option is
## tagged "harsh", "kind" or "neutral", and each survivor reacts according to
## their traits (pragmatists approve harsh calls, compassionate people don't),
## which changes loyalty and is remembered. Unanswered events resolve
## themselves after a day with consequences of their own.

const AUTO_RESOLVE_HOURS := 24.0

var pending: Array = []        # [{uid, type, t, sid, data}]
var waiting_recruits: Array = []  # survivors met before the base existed
var returns: Array = []        # [{survivor, day}] people expected back
var _uid := 1
var _rng := RandomNumberGenerator.new()
var zulfiya_done := false


func clear() -> void:
	pending.clear()
	waiting_recruits.clear()
	returns.clear()
	_uid = 1
	zulfiya_done = false
	_rng.randomize()


func _push(type: String, sid: int, data: Dictionary) -> Dictionary:
	var e := {"uid": _uid, "type": type, "t": Clock.total_minutes, "sid": sid, "data": data}
	_uid += 1
	pending.append(e)
	EventBus.toast("Убежище: требуется ваше решение", "warn")
	return e


# --- sources ----------------------------------------------------------------------

func on_base_founded() -> void:
	if not zulfiya_done:
		zulfiya_done = true
		var z := Session.survivors.generate({"name": "Зульфия Галимова", "female": true, "age": 52, "profession": "core:paramedic",
			"skills": {"medicine": 7, "building": 1, "engineering": 0, "farming": 3, "cooking": 3, "combat": 1, "scavenging": 2},
			"traits": ["core:compassionate", "core:hardworking"], "infected_hidden": false, "loyalty": 60.0,
			"bio": "Фельдшер скорой с тридцатилетним стажем, соседка по двору на Первомайской. Три дня назад перевязывала первых укушенных.",
			"fear": "больниц", "secret": "Записала в блокнот всё, что видела у первых заражённых, — и боится того, что из этого следует."})
		recruit_event(z, "Соседка, которую вы видели в окне в первый день, стучит в дверь вашего нового убежища.")
	for p in waiting_recruits:
		Session.survivors.add(p)
		Session.journal.add("base", "%s пришёл(ла) в убежище, как и обещал(а).".replace("пришёл(ла)", "пришла" if p["female"] else "пришёл").replace("обещал(а)", "обещала" if p["female"] else "обещал") % p["name"])
	waiting_recruits.clear()


## Chance of meeting a survivor while exploring (search, entering a place).
func maybe_meet(source: String) -> bool:
	var chance := 0.12 if source == "search" else 0.07
	if _rng.randf() >= chance:
		return false
	var p := Session.survivors.generate()
	recruit_event(p, "FIELD" + ("Во время обыска вы встречаете живого человека." if source == "search" else "В глубине здания кто-то прячется — живой."))
	return true


func recruit_event(p: Dictionary, intro: String) -> void:
	var field := intro.begins_with("FIELD")
	_push("recruit", 0, {"candidate": p, "intro": intro.trim_prefix("FIELD"), "field": field})


## Events the hero should face right now (at the base, or a person met in the field).
func immediate() -> Dictionary:
	for e in pending:
		if bool(e["data"].get("field", false)) or Session.base.hero_here():
			return e
	return {}


func queue_bitten(p: Dictionary) -> void:
	_push("bitten", int(p["id"]), {})


func daily() -> void:
	var people := Session.survivors
	var base := Session.base
	var at := people.at_base()
	# people coming back from searching for their families
	for r in returns.duplicate():
		if Clock.day() >= int(r["day"]):
			returns.erase(r)
			var p: Dictionary = r["survivor"]
			if _rng.randf() < 0.6:
				var back := people.find(int(p["id"]))
				if not back.is_empty():
					back["status"] = "base"
					back["loyalty"] = clampf(float(back["loyalty"]) + 25.0, 0.0, 100.0)
					people.remember(back, "Вы отпустили меня к родным — я вернулся(ась).", 8.0)
					Session.journal.add("base", "%s вернулся(ась)! Родных нашёл(ла) не всех, но теперь держится за убежище." .replace("вернулся(ась)", "вернулась" if back["female"] else "вернулся").replace("нашёл(ла)", "нашла" if back["female"] else "нашёл") % back["name"])
	# radio calls survivors
	var radio := base.effect("radio", "recruit", 0.0) * minf(1.0, base.staff_of("radio").size()) * (0.3 + 0.7 * base.power_ratio())
	if radio > 0.0 and _rng.randf() < radio:
		recruit_event(people.generate(), "На позывной радиостанции вышел человек и добрался до ваших ворот.")
	if Session.offline_mode or at.size() < 2:
		return
	if base.food_days() < 1.5 and not _has("food_quarrel") and _rng.randf() < 0.5:
		var a: Dictionary = at[_rng.randi() % at.size()]
		var b: Dictionary = at[(at.find(a) + 1) % at.size()]
		_push("food_quarrel", int(a["id"]), {"other": int(b["id"])})
	var low := at.filter(func(p): return float(p["loyalty"]) < 35.0)
	if not low.is_empty() and _rng.randf() < 0.12 and not _has("theft"):
		var thief: Dictionary = low[_rng.randi() % low.size()]
		var stolen := ""
		for s in base.storage.stacks:
			var d := base.storage.def_of(s)
			if d.get("category") in ["food", "medical", "ammo"]:
				stolen = str(d["name"])
				base.storage.remove_uid(int(s["uid"]), mini(int(s["qty"]), 3))
				break
		if stolen != "":
			_push("theft", int(thief["id"]), {"item": stolen})
	if _rng.randf() < 0.05 and not _has("family"):
		var p: Dictionary = at[_rng.randi() % at.size()]
		var towns := Registry.all("region").filter(func(r): return r["kind"] in ["town", "village"])
		var town: Dictionary = towns[_rng.randi() % towns.size()] if not towns.is_empty() else {"name": "деревню"}
		_push("family", int(p["id"]), {"town": town["name"]})
	# auto-resolve stale events
	for e in pending.duplicate():
		if Clock.total_minutes - float(e["t"]) > AUTO_RESOLVE_HOURS * 60.0:
			resolve(e, -1)


func _has(type: String) -> bool:
	return pending.any(func(e): return e["type"] == type)


# --- presentation ------------------------------------------------------------------

func describe(e: Dictionary) -> Dictionary:
	var people := Session.survivors
	var p := people.find(int(e["sid"]))
	var d: Dictionary = e["data"]
	match str(e["type"]):
		"recruit":
			var c: Dictionary = d["candidate"]
			var txt := "%s\n\n%s, %d лет, %s. Черты: %s.\n%s" % [d["intro"], c["name"], int(c["age"]), people.profession_name(c).to_lower(), people.traits_text(c), people.text_of(c, "bio")]
			var opts := [["Принять в группу", "neutral"], ["Накормить и отпустить", "kind"], ["Прогнать", "harsh"]]
			if not Session.base.exists:
				opts[0] = ["Позвать в будущее убежище", "neutral"]
			if not bool(d.get("checked", false)) and Session.base.exists and people.at_base().any(func(x): return people.skill(x, "medicine") >= 4):
				opts.insert(1, ["Сначала осмотреть на укусы", "neutral"])
			if bool(d.get("checked", false)):
				txt += "\n\nОсмотр: " + ("на предплечье — свежий укус под повязкой." if bool(c.get("infected_hidden", false)) else "следов укусов нет.")
			return {"title": "Выживший", "text": txt, "options": opts}
		"bitten":
			return {"title": "Укус", "text": "%s показывает руку: укус, края почернели. Жар. Все понимают, что это значит, — и все смотрят на вас." % p.get("name", "?"),
				"options": [["Изолировать в подвале и ждать", "neutral"], ["Дать ингибитор «АФ-7» (есть: %d)" % (Session.base.storage.count("antiviral_af7") + Session.player.inventory.count("antiviral_af7")), "kind"],
					["Изгнать, пока не поздно", "harsh"], ["Избавить от мучений", "harsh"]]}
		"food_quarrel":
			var o := people.find(int(d.get("other", 0)))
			return {"title": "Еда на исходе", "text": "Еды на %.1f дня. %s при всех обвиняет %s, что тот(та) ест за двоих. Люди ждут, что скажете вы." % [Session.base.food_days(), p.get("name", "?"), o.get("name", "?")],
				"options": [["Урезать пайки всем поровну", "neutral"], ["Больше еды тем, кто работает", "harsh"], ["Отдать свою долю", "kind"]]}
		"theft":
			return {"title": "Кража со склада", "text": "Пропало: %s. Следы ведут к %s. Отпираться бесполезно." % [d.get("item", "?"), p.get("name", "?")],
				"options": [["Наказать: неделя без пайка", "harsh"], ["Простить и поговорить", "kind"], ["Выгнать из убежища", "harsh"]]}
		"family":
			return {"title": "Просьба", "text": "%s просит отпустить на поиски родных — последний раз их видели в «%s». Одному(ой) туда идти опасно." % [p.get("name", "?"), d.get("town", "?")],
				"options": [["Отпустить и дать припасов", "kind"], ["Отпустить без припасов", "neutral"], ["Запретить: ты нужен(на) здесь", "harsh"]]}
	return {"title": "?", "text": "", "options": [["OK", "neutral"]]}


## Applies an option (index -1 = nobody decided in time). Returns a report line.
func resolve(e: Dictionary, idx: int) -> String:
	var people := Session.survivors
	var base := Session.base
	var p := people.find(int(e["sid"]))
	var d: Dictionary = e["data"]
	var info := describe(e)
	var opts: Array = info["options"]
	var label := "решение не принято" if idx < 0 else str(opts[idx][0])
	var tag := "neutral" if idx < 0 else str(opts[idx][1])
	var out := ""
	pending.erase(e)
	match str(e["type"]):
		"recruit":
			var c: Dictionary = d["candidate"]
			if label.begins_with("Сначала осмотреть"):
				d["checked"] = true
				pending.append(e)
				return "Осмотр займёт минуту."
			if label.begins_with("Принять") or label.begins_with("Позвать"):
				if base.exists:
					people.add(c)
					out = "%s теперь с вами." % c["name"]
				else:
					waiting_recruits.append(c)
					out = "%s придёт, когда у вас появится убежище." % c["name"]
			elif label.begins_with("Накормить"):
				var src := base.storage if base.exists and base.storage.count("crackers") + base.storage.count("canned_meat") > 0 else Session.player.inventory
				for item in ["crackers", "canned_meat", "bread", "vegetables"]:
					if src.remove_item(item, 1) > 0:
						break
				out = "%s благодарит и уходит." % c["name"]
			else:
				out = "%s уходит, не оглядываясь." % c["name"] if idx >= 0 else "%s так и не дождался(ась) ответа и ушёл(ла)." % c["name"]
		"bitten":
			if p.is_empty():
				return ""
			if label.begins_with("Дать") and base.storage.count("antiviral_af7") + Session.player.inventory.count("antiviral_af7") == 0:
				p["job"] = "idle"
				p["infected_hours"] = maxf(0.0, float(p["infected_hours"]))
				out = "Ингибитора нет ни на складе, ни у вас. %s заперли в подвале — больше ничего не сделать." % p["name"]
			elif label.begins_with("Дать"):
				if base.storage.remove_item("antiviral_af7", 1) == 0:
					Session.player.inventory.remove_item("antiviral_af7", 1)
				if _rng.randf() < 0.6:
					p["infected_hours"] = -1.0
					p["injury_hours"] = float(p["injury_hours"]) + 48.0
					people.remember(p, "Мне дали «АФ-7», когда я уже не надеялся(ась).", 12.0)
					out = "Жар спадает. «АФ-7» сработал — на этот раз."
				else:
					p["infected_hours"] = 40.0
					out = "Ингибитор не помог. Осталось недолго."
			elif label.begins_with("Изгнать"):
				p["status"] = "left"
				out = "%s уходит в сторону леса." % p["name"]
			elif label.begins_with("Избавить"):
				p["status"] = "dead"
				base.stats["deaths"] = int(base.stats["deaths"]) + 1
				Session.journal.add("death", "%s. Тихо, во сне." % p["name"])
				out = "Это сделали тихо."
			else:
				p["job"] = "idle"
				p["infected_hours"] = maxf(0.0, float(p["infected_hours"]))
				out = "%s заперт(а) в подвале. Остаётся ждать." % p["name"]
		"food_quarrel":
			if label.begins_with("Урезать"):
				for x in people.at_base():
					x["satiety"] = maxf(0.0, float(x["satiety"]) - 10.0)
					people.remember(x, "Урезали пайки.", -2.0)
				out = "Пайки урезаны. Ворчат, но едят."
			elif label.begins_with("Больше еды"):
				for x in people.at_base():
					var works: bool = x["job"] != "idle"
					x["loyalty"] = clampf(float(x["loyalty"]) + (4.0 if works else -8.0), 0.0, 100.0)
					people.remember(x, "Еду делят по работе.", 2.0 if works else -5.0)
				out = "Работники довольны. Остальные — нет."
			elif label.begins_with("Отдать"):
				Session.player.survival.needs["satiety"] = maxf(5.0, Session.player.survival.need("satiety") - 30.0)
				for x in people.at_base():
					x["loyalty"] = clampf(float(x["loyalty"]) + 4.0, 0.0, 100.0)
				out = "Вы отдали свою долю. Это заметили все."
			else:
				for x in people.at_base():
					x["morale"] = maxf(0.0, float(x["morale"]) - 6.0)
				out = "Ссора переросла в драку — пока вас не было."
		"theft":
			if p.is_empty():
				return ""
			if label.begins_with("Наказать"):
				p["satiety"] = maxf(0.0, float(p["satiety"]) - 40.0)
				p["loyalty"] = clampf(float(p["loyalty"]) - 20.0, 0.0, 100.0)
				people.remember(p, "Меня наказали за кражу.", -10.0)
				out = "%s молча принимает наказание." % p["name"]
			elif label.begins_with("Простить"):
				p["loyalty"] = clampf(float(p["loyalty"]) + 15.0, 0.0, 100.0)
				people.remember(p, "Меня простили.", 8.0)
				out = "%s плачет и обещает, что это не повторится." % p["name"]
			elif label.begins_with("Выгнать"):
				p["status"] = "left"
				out = "%s уходит с пустыми руками." % p["name"]
			else:
				out = "Вора никто не наказал. Склад теперь запирают."
		"family":
			if p.is_empty():
				return ""
			if label.begins_with("Отпустить"):
				p["status"] = "away"
				p["away_until"] = 1e12
				p["job"] = "idle"
				if label.contains("припас"):
					for item in ["canned_meat", "water_bottle", "bandage"]:
						base.storage.remove_item(item, 1)
				returns.append({"survivor": {"id": p["id"]}, "day": Clock.day() + _rng.randi_range(3, 8)})
				out = "%s уходит на рассвете." % p["name"]
			else:
				p["loyalty"] = clampf(float(p["loyalty"]) - 25.0, 0.0, 100.0)
				people.remember(p, "Мне не дали искать родных.", -12.0)
				out = "%s остаётся. Смотрит в сторону." % p["name"]
	if tag != "neutral":
		people.react_to_decision(tag, "%s (%s)" % [label, info["title"]])
	if p.has("name") and idx >= 0:
		people.remember(p, "Решение лидера: %s." % label, 0.0)
	var txt := AfSurvivors.g(out, bool(p.get("female", d.get("candidate", {}).get("female", false))))
	Session.journal.add("decision", "%s — %s. %s" % [info["title"], label, txt])
	return txt


# --- persistence -------------------------------------------------------------------

func save_key() -> String:
	return "base_events"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS base_events (key TEXT PRIMARY KEY, value TEXT)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("INSERT OR REPLACE INTO base_events VALUES ('state', ?)", [JSON.stringify(
		{"pending": pending, "waiting": waiting_recruits, "returns": returns, "uid": _uid, "zulfiya": zulfiya_done})])


func load_from_db(db: AfDatabase) -> void:
	clear()
	if not db.table_exists("base_events"):
		return
	var v: Variant = JSON.parse_string(str(db.scalar("SELECT value FROM base_events WHERE key = 'state'", [], "{}")))
	if typeof(v) != TYPE_DICTIONARY:
		return
	pending = v.get("pending", [])
	waiting_recruits = v.get("waiting", [])
	returns = v.get("returns", [])
	_uid = int(v.get("uid", 1))
	zulfiya_done = bool(v.get("zulfiya", false))
	for e in pending:
		e["sid"] = int(e["sid"])
