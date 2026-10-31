class_name AfBasePanel
extends AfPanel
## Settlement management: overview, people, buildings, storage, decisions.

var _tab := "overview"
var _content: VBoxContainer
var _tabs: HBoxContainer
var _dirty := false


func _init() -> void:
	super._init("Убежище")
	_tabs = AfUI.hbox(8)
	body.add_child(_tabs)
	_content = AfUI.vbox(8)
	body.add_child(AfUI.scroll(_content))


func _ready() -> void:
	Session.base.changed.connect(_mark)
	_render()


func _exit_tree() -> void:
	super._exit_tree()
	if Session.base.changed.is_connected(_mark):
		Session.base.changed.disconnect(_mark)


func _mark() -> void:
	_dirty = true


func _process(_d: float) -> void:
	if _dirty:
		_dirty = false
		_render()


func _render() -> void:
	AfUI.clear(_tabs)
	var n := Session.events.pending.size()
	for spec in [["overview", "Обзор"], ["people", "Жители · %d" % Session.survivors.living().size()], ["build", "Постройки"], ["storage", "Склад"], ["decisions", "Решения" + (" · %d" % n if n > 0 else "")]]:
		var b := AfUI.accent_button(spec[1], Callable(), 150) if spec[0] == _tab else AfUI.button(spec[1], Callable(), 150)
		var id: String = spec[0]
		b.pressed.connect(func():
			_tab = id
			_render())
		_tabs.add_child(b)
	AfUI.clear(_content)
	if not Session.base.exists:
		_content.add_child(AfUI.label("Убежища пока нет. Откройте карту, дойдите до подходящего места (двор, школа, завод, село) и нажмите «Основать убежище здесь».", 17, AfTheme.TEXT, true))
		if not Session.events.waiting_recruits.is_empty():
			_content.add_child(AfUI.label("Ждут, когда у вас появится убежище: " + ", ".join(PackedStringArray(Session.events.waiting_recruits.map(func(p): return p["name"]))), 15, AfTheme.TEXT_DIM, true))
		return
	match _tab:
		"overview": _overview()
		"people": _people()
		"build": _buildings()
		"storage": _storage()
		"decisions": _decisions()


# --- overview -------------------------------------------------------------------------

func _overview() -> void:
	var b := Session.base
	var here := b.hero_here()
	_content.add_child(AfUI.label(b.name, 24, AfTheme.ACCENT_SOFT))
	_content.add_child(AfUI.label("%s · основано на %d-й день · %s" % [b.location_name(), b.founded_day, "вы здесь" if here else "вы далеко — связь по рации"], 15, AfTheme.GOOD if here else AfTheme.TEXT_DIM))
	var people := Session.survivors.at_base().size()
	var away := Session.survivors.people.filter(func(p): return p["status"] == "away").size()
	var rows := [
		["Жители", "%d в убежище, %d в отлучке · коек: %d" % [people, away, b.beds()], AfTheme.WARN if people > b.beds() else AfTheme.TEXT],
		["Еда", "на %.1f дн." % b.food_days() if people > 0 else "—", AfTheme.DANGER if b.food_days() < 2.0 and people > 0 else AfTheme.TEXT],
		["Вода", "на %.1f дн." % b.water_days() if people > 0 else "—", AfTheme.DANGER if b.water_days() < 2.0 and people > 0 else AfTheme.TEXT],
		["Электричество", "%.0f из %.0f · топливо: %d канистр" % [b.power_output(), b.power_demand(), b.storage.count("fuel_can")], AfTheme.WARN if b.power_ratio() < 1.0 else AfTheme.TEXT],
		["Оборона", "%.0f · заражённые рядом: %s" % [b.defense(), Session.world_map.density_label(b.region_id)], AfTheme.TEXT],
		["Склад", "%.0f / %.0f кг" % [b.storage.total_weight(), b.storage_capacity()], AfTheme.TEXT],
		["Нападения", "%d, отбито %d · погибших: %d" % [int(b.stats["raids"]), int(b.stats["repelled"]), int(b.stats["deaths"])], AfTheme.TEXT],
	]
	for r in rows:
		var h := AfUI.hbox(10)
		var l := AfUI.label(r[0], 17, AfTheme.TEXT_DIM)
		l.custom_minimum_size = Vector2(170, 0)
		h.add_child(l)
		h.add_child(AfUI.label(r[1], 17, r[2], true))
		_content.add_child(h)
	if not b.queue.is_empty():
		var q: Dictionary = b.queue[0]
		_content.add_child(AfUI.label("Стройка: %s, ур. %d — %.0f из %.0f ч работы%s" % [Registry.display_name("base_module", q["module"]), int(q["level"]), float(q["done"]), float(q["need"]),
			"" if b.queue.size() == 1 else " (ещё в очереди: %d)" % (b.queue.size() - 1)], 16, AfTheme.ACCENT_SOFT, true))
		_content.add_child(AfUI.bar(100.0 * float(q["done"]) / float(q["need"]), AfTheme.ACCENT, 10))
		if here:
			_content.add_child(AfUI.button("Работать на стройке самому (2 ч)", func():
				Scheduler.fast_forward(120.0, 60.0)
				if not b.queue.is_empty():
					b.queue[0]["done"] = float(b.queue[0]["done"]) + 1.6
					if float(b.queue[0]["done"]) >= float(b.queue[0]["need"]):
						b._finish_build(b.queue[0])
				_render(), 380))
	var auto_row := AfUI.hbox(10)
	auto_row.add_child(AfUI.label("Жители сами распределяют работу", 17, AfTheme.TEXT, true))
	var c := CheckButton.new()
	c.button_pressed = b.auto_assign
	c.toggled.connect(func(on): b.auto_assign = on)
	auto_row.add_child(c)
	_content.add_child(auto_row)
	if here:
		_content.add_child(AfUI.button("Отдохнуть в убежище (сон 8 ч)", _rest, 380))


func _rest() -> void:
	var s := Session.player.survival
	s.sleeping = true
	Scheduler.fast_forward(480.0, 60.0)
	s.sleeping = false
	EventBus.toast("Вы выспались. Энергия %d." % int(s.need("energy")), "good")
	_render()


# --- people ----------------------------------------------------------------------------

func _people() -> void:
	var ppl := Session.survivors
	var list := ppl.people.filter(func(p): return p["status"] in ["base", "away"])
	if list.is_empty():
		_content.add_child(AfUI.label("В убежище пока никого. Выжившие встречаются при обысках, а радиостанция зовёт их сама.", 16, AfTheme.TEXT_DIM, true))
	for p in list:
		var card := AfUI.card(12)
		var v := AfUI.vbox(4)
		card.add_child(v)
		var head := AfUI.hbox(10)
		head.add_child(AfUI.label("%s, %d" % [p["name"], int(p["age"])], 19, AfTheme.ACCENT_SOFT))
		head.add_child(AfUI.label("%s · %s" % [ppl.profession_name(p), ppl.mood_text(p)], 15, AfTheme.TEXT_DIM))
		head.add_child(AfUI.spacer())
		head.add_child(AfUI.button("Подробнее", _person_dialog.bind(int(p["id"])), 150))
		v.add_child(head)
		var stat := AfUI.hbox(14)
		stat.add_child(AfUI.label("Здоровье %d" % int(p["health"]), 14, AfTheme.DANGER if float(p["health"]) < 50 else AfTheme.TEXT))
		stat.add_child(AfUI.label("Мораль %d" % int(p["morale"]), 14))
		stat.add_child(AfUI.label("Лояльность %d" % int(p["loyalty"]), 14, AfTheme.WARN if float(p["loyalty"]) < 30 else AfTheme.TEXT))
		if float(p["injury_hours"]) > 0.0:
			stat.add_child(AfUI.label("ранен(а): ~%d ч" % int(p["injury_hours"]), 14, AfTheme.WARN))
		if float(p.get("infected_hours", -1.0)) >= 0.0:
			stat.add_child(AfUI.label("ЗАРАЖЁН(А)", 14, AfTheme.DANGER))
		v.add_child(stat)
		if p["status"] == "away":
			var left := (float(p["away_until"]) - Clock.total_minutes) / 60.0
			v.add_child(AfUI.label("В отлучке: %s" % ("вылазка в «%s», вернётся через ~%d ч" % [Registry.display_name("region", str(p["away_target"])), int(left)] if left < 1000 else "ушёл(ла) искать родных"), 14, AfTheme.TEXT_DIM))
		else:
			var row := AfUI.hbox(8)
			row.add_child(AfUI.label("Работа:", 15, AfTheme.TEXT_DIM))
			var ob := OptionButton.new()
			ob.custom_minimum_size = Vector2(280, 48)
			var jobs := _available_jobs()
			for i in jobs.size():
				ob.add_item(AfSurvivors.JOBS.get(jobs[i], jobs[i]))
				if jobs[i] == p["job"]:
					ob.select(i)
			ob.item_selected.connect(func(i): Session.base.set_job(p, jobs[i]))
			row.add_child(ob)
			var sk: String = AfSurvivors.JOB_SKILL.get(p["job"], "")
			if sk != "":
				row.add_child(AfUI.label("%s: %d" % [AfSurvivors.SKILLS[sk], int(ppl.skill(p, sk))], 14, AfTheme.TEXT_DIM))
			v.add_child(row)
		_content.add_child(card)


func _available_jobs() -> Array:
	var out := ["idle", "build", "guard", "scavenge"]
	for id in ["workshop", "infirmary", "kitchen", "garden", "water", "radio"]:
		if Session.base.level(id) > 0:
			out.append(id)
	return out


func _person_dialog(id: int) -> void:
	var ppl := Session.survivors
	var p := ppl.find(id)
	var lines := []
	lines.append("%s. %s" % [ppl.profession_name(p), ppl.text_of(p, "bio")])
	lines.append("Черты: " + ppl.traits_text(p))
	var sk := PackedStringArray()
	for s in AfSurvivors.SKILLS:
		sk.append("%s %d" % [AfSurvivors.SKILLS[s], int(ppl.skill(p, s))])
	lines.append("Навыки: " + ", ".join(sk))
	lines.append("Боится %s." % p["fear"])
	lines.append("Секрет: " + (str(p["secret"]) if float(p["loyalty"]) >= 70.0 else "пока не доверяет вам настолько."))
	var rel := []
	for k in p["relations"]:
		var o := ppl.find(int(k))
		if not o.is_empty() and o["status"] in ["base", "away"]:
			rel.append([float(p["relations"][k]), str(o["name"])])
	rel.sort_custom(func(a, b): return a[0] > b[0])
	if not rel.is_empty():
		lines.append("Ближе всех: %s (%d)%s" % [rel[0][1], int(rel[0][0]), "" if rel.size() < 2 else " · хуже всех ладит с: %s (%d)" % [rel[-1][1], int(rel[-1][0])]])
	var mem: Array = p["memory"].slice(maxi(0, p["memory"].size() - 6))
	mem.reverse()
	for m in mem:
		lines.append("Помнит: " + AfSurvivors.g(str(m["text"]), bool(p["female"])))
	AfDialog.show_in(self, "%s, %d" % [p["name"], int(p["age"])], "", [], lines)


# --- buildings -----------------------------------------------------------------------

func _buildings() -> void:
	var b := Session.base
	for d in Registry.all("base_module"):
		var id := str(d["id"])
		var lvl := b.level(id)
		var card := AfUI.card(12)
		var v := AfUI.vbox(4)
		card.add_child(v)
		var head := AfUI.hbox(10)
		head.add_child(AfUI.label(str(d["name"]), 19, AfTheme.ACCENT_SOFT if lvl > 0 else AfTheme.TEXT))
		head.add_child(AfUI.label("уровень %d / %d" % [lvl, d["levels"].size()] if lvl > 0 else "не построено", 15, AfTheme.TEXT_DIM))
		v.add_child(head)
		v.add_child(AfUI.label(str(d.get("description", "")), 14, AfTheme.TEXT_DIM, true))
		if lvl > 0:
			var info := PackedStringArray()
			var ld := b.level_def(id)
			if ld.has("staff"):
				info.append("работников %d/%d" % [b.staff_of(id).size(), int(ld["staff"])])
			if ld.has("power"):
				info.append("электричество %d" % int(ld["power"]))
			for k in ["beds", "capacity", "defense", "power_output"]:
				if ld.has(k):
					info.append({"beds": "коек %d", "capacity": "+%d кг", "defense": "оборона %d", "power_output": "даёт %d энергии"}[k] % int(ld[k]))
			info.append("состояние %d%%" % int(b.condition(id) * 100))
			v.add_child(AfUI.label(" · ".join(info), 14))
		var row := AfUI.hbox(8)
		if lvl < d["levels"].size():
			var next: Dictionary = d["levels"][lvl]
			var cost := PackedStringArray()
			for item in next.get("cost", {}):
				cost.append("%s %d/%d" % [Registry.display_name("item", item), b.storage.count(item), int(next["cost"][item])])
			if Session.config.god_mode:
				v.add_child(AfUI.label("Игра бога: бесплатно и сразу", 14, AfTheme.GOOD))
			else:
				v.add_child(AfUI.label(("Построить: " if lvl == 0 else "Улучшить: ") + ", ".join(cost) + " · %d ч работы" % int(next.get("build_hours", 6)), 14, AfTheme.TEXT, true))
			var problem := b.build_problem(id)
			var btn := AfUI.accent_button("Построить" if lvl == 0 else "Улучшить", func():
				var r := b.order_build(id)
				if r != "":
					EventBus.toast(r, "warn")
				_render(), 170)
			btn.disabled = problem != ""
			row.add_child(btn)
			if problem != "" and problem != "уже строится":
				row.add_child(AfUI.label(problem, 13, AfTheme.WARN, true))
			elif problem == "уже строится":
				row.add_child(AfUI.label("строится…", 14, AfTheme.ACCENT_SOFT))
		if lvl > 0 and b.condition(id) < 0.85:
			var rc := {} if Session.config.god_mode else b.repair_cost(id)
			var rtxt := ", ".join(PackedStringArray(rc.keys().map(func(k): return "%s %d" % [Registry.display_name("item", k), rc[k]])))
			row.add_child(AfUI.button("Ремонт (%s)" % rtxt if rtxt != "" else "Ремонт", func():
				var r := b.repair(id)
				if r != "":
					EventBus.toast(r, "warn")
				_render()))
		if lvl > 0:
			row.add_child(AfUI.button("Разобрать", func():
				AfDialog.show_in(self, "Разобрать?", "Вернётся половина материалов последнего уровня.", [["Отмена", Callable()], ["Разобрать", func(): b.demolish(id); _render()]]), 150))
		v.add_child(row)
		_content.add_child(card)


# --- storage --------------------------------------------------------------------------

func _storage() -> void:
	var b := Session.base
	var here := b.hero_here()
	_content.add_child(AfUI.label("Склад: %.0f / %.0f кг%s" % [b.storage.total_weight(), b.storage_capacity(), "" if here else " · обменяться вещами можно только в убежище"], 16, AfTheme.TEXT_DIM))
	if here:
		var row := AfUI.hbox(8)
		row.add_child(AfUI.accent_button("Сдать всё, кроме снаряжения", _deposit_all, 340))
		_content.add_child(row)
	var cols := AfUI.hbox(16)
	_content.add_child(cols)
	var left := AfUI.vbox(4)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	left.add_child(AfUI.label("Склад", 18, AfTheme.ACCENT_SOFT))
	for s in b.storage.stacks:
		var r := AfUI.hbox(6)
		r.add_child(AfUI.label("%s ×%d" % [b.storage.def_of(s).get("name", s["item"]), int(s["qty"])], 15))
		r.add_child(AfUI.spacer())
		if here:
			var uid := int(s["uid"])
			r.add_child(AfUI.button("Взять", func(): _move(b.storage, Session.player.inventory, uid), 110))
		left.add_child(r)
	if here:
		var right := AfUI.vbox(4)
		right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cols.add_child(right)
		right.add_child(AfUI.label("Рюкзак (%.1f / %.0f кг)" % [Session.player.inventory.total_weight(), Session.player.inventory.max_weight], 18, AfTheme.ACCENT_SOFT))
		for s in Session.player.inventory.stacks:
			var r2 := AfUI.hbox(6)
			r2.add_child(AfUI.label("%s ×%d" % [Session.player.inventory.def_of(s).get("name", s["item"]), int(s["qty"])], 15))
			r2.add_child(AfUI.spacer())
			var uid2 := int(s["uid"])
			if not Session.player.is_equipped(uid2):
				r2.add_child(AfUI.button("Сдать", func(): _move(Session.player.inventory, b.storage, uid2), 110))
			right.add_child(r2)
	_content.add_child(AfUI.label("Производство: держать на складе", 18, AfTheme.ACCENT_SOFT))
	for r in Registry.all("recipe"):
		var rid := str(r["id"])
		var h := AfUI.hbox(8)
		var ins := ", ".join(PackedStringArray(r["inputs"].keys().map(func(k): return "%s %d" % [Registry.display_name("item", k), r["inputs"][k]])))
		h.add_child(AfUI.label("%s (%s, %s → %s ×%d)" % [r.get("name", rid), Registry.display_name("base_module", str(r["module"])), ins, Registry.display_name("item", str(r["output"])), int(r.get("qty", 1))], 14, AfTheme.TEXT if b.level(str(r["module"])) > 0 else AfTheme.TEXT_DIM, true))
		var t := int(b.recipe_targets.get(rid, 0))
		h.add_child(AfUI.button("−", func(): b.recipe_targets[rid] = maxi(0, t - 1); _render(), 52))
		h.add_child(AfUI.label("%d" % t, 16))
		h.add_child(AfUI.button("+", func(): b.recipe_targets[rid] = t + 1; _render(), 52))
		_content.add_child(h)


func _move(from: AfInventory, to: AfInventory, uid: int) -> void:
	var s := from.find(uid)
	if s.is_empty():
		return
	var left := to.add(str(s["item"]), int(s["qty"]), float(s["quality"]), float(s["condition"]))
	from.remove_uid(uid, int(s["qty"]) - left)
	if left > 0:
		EventBus.toast("Не помещается: осталось %d" % left, "warn")
	_render()


func _deposit_all() -> void:
	var inv := Session.player.inventory
	for s in inv.stacks.duplicate():
		if Session.player.is_equipped(int(s["uid"])):
			continue
		var cat := str(inv.def_of(s).get("category", ""))
		if cat in ["material", "food", "drink", "ammo", "medical", "clothing", "misc"]:
			var left := Session.base.storage.add(str(s["item"]), int(s["qty"]), float(s["quality"]), float(s["condition"]))
			inv.remove_uid(int(s["uid"]), int(s["qty"]) - left)
	_render()


# --- decisions -----------------------------------------------------------------------

func _decisions() -> void:
	var ev := Session.events
	if ev.pending.is_empty():
		_content.add_child(AfUI.label("Решений не требуется.", 16, AfTheme.TEXT_DIM))
	for e in ev.pending:
		var info := ev.describe(e)
		var card := AfUI.card(12)
		var v := AfUI.vbox(6)
		card.add_child(v)
		v.add_child(AfUI.label(info["title"], 19, AfTheme.ACCENT_SOFT))
		v.add_child(AfUI.label(info["text"], 15, AfTheme.TEXT, true))
		var h := (AfUI.hbox(8))
		v.add_child(AfUI.label("Без ответа решится само через %d ч." % int(maxf(0.0, AfBaseEvents.AUTO_RESOLVE_HOURS - (Clock.total_minutes - float(e["t"])) / 60.0)), 13, AfTheme.TEXT_DIM))
		v.add_child(h)
		h.add_child(AfUI.accent_button("Решить", func(): show_decision(self, e, _render), 160))
		_content.add_child(card)


## Opens the decision dialog for an event (time stops while it is open).
static func show_decision(parent: Node, e: Dictionary, after: Callable = Callable()) -> void:
	var info := Session.events.describe(e)
	var buttons := []
	for i in info["options"].size():
		var idx: int = i
		buttons.append([info["options"][i][0], func():
			var res := Session.events.resolve(e, idx)
			if Session.events.pending.has(e):
				show_decision(parent, e, after)  # e.g. after a medical check
			elif res != "":
				AfDialog.show_in(parent, info["title"], res, [["Продолжить", after]])
			elif after.is_valid():
				after.call()])
	var d := AfDialog.show_in(parent, info["title"], info["text"], buttons)
	d.set_meta("base_event", e["uid"])
