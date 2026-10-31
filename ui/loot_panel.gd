class_name AfLootPanel
extends AfPanel
## Searching a container or a corpse. Searching takes real time (with a
## progress bar) and makes some noise; contents are rolled once and persist.

var world: AfGameWorld
var _items: Array = []          # reference to the persistent item list
var _state: Dictionary = {}     # container state (or {} for corpses)
var _container: Node3D
var _corpse: AfZombie
var _search_left := 0.0
var _search_total := 1.0
var _progress: ProgressBar
var _list: VBoxContainer
var _status: Label


func _init() -> void:
	super._init("Обыск")


func setup_container(p_world: AfGameWorld, node: Node3D, cdef: Dictionary, st: Dictionary) -> void:
	world = p_world
	_container = node
	_state = st
	title = str(cdef["name"])
	(header.get_child(0) as Label).text = title
	if not st["searched"]:
		_search_total = float(cdef.get("search_sec", 4.0))
		_search_left = _search_total
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var table := RegistryHelpers.full_id_for(str(cdef.get("loot_table", "residential")), str(world.loc_def.get("_package", "core")), "loot_table")
		st["items"] = AfInventory.roll_loot(table, rng)
		st["searched"] = true
		EventBus.container_looted.emit(str(cdef["id"]), world.zm.location_id)
	_items = st["items"]
	_build()


func setup_corpse(p_world: AfGameWorld, z: AfZombie) -> void:
	world = p_world
	_corpse = z
	(header.get_child(0) as Label).text = "Тело: " + str(z.def.get("name", ""))
	_search_total = 2.0
	_search_left = 2.0
	_items = z.corpse_items
	_build()


func _build() -> void:
	_status = AfUI.label("", 17, AfTheme.TEXT_DIM)
	body.add_child(_status)
	_progress = AfUI.bar(0, AfTheme.ACCENT, 12)
	body.add_child(_progress)
	_list = AfUI.vbox(6)
	body.add_child(AfUI.scroll(_list))
	var row := AfUI.hbox(10)
	row.add_child(AfUI.spacer())
	row.add_child(AfUI.accent_button("Взять всё", _take_all, 200))
	body.add_child(row)
	# searching is time spent in the world: unpause this panel's freeze while searching
	pauses_time = _search_left <= 0.0
	_refresh()


func _process(delta: float) -> void:
	if _search_left > 0.0:
		_search_left -= delta
		_progress.value = (1.0 - _search_left / _search_total) * 100.0
		if world.zm.hunting_count() > 0 and _search_left > 0.2:
			EventBus.toast("Обыск прерван — вас заметили!", "danger")
			if _corpse == null:
				pass  # contents stay rolled; you can come back
			close()
			return
		if _search_left <= 0.0:
			if _corpse:
				_corpse.corpse_searched = _items.is_empty()
			_refresh()
			EventBus.noise_emitted.emit(world.player.global_position, 3.0, "search")


func _refresh() -> void:
	AfUI.clear(_list)
	if _search_left > 0.0:
		_status.text = "Обыскиваете…"
		return
	_progress.visible = false
	_status.text = "Найдено предметов: %d · свободно %.1f кг" % [_items.size(), Session.player.inventory.free_weight()]
	if _items.is_empty():
		_list.add_child(AfUI.label("Ничего полезного.", 18, AfTheme.TEXT_DIM))
	for i in _items.size():
		var it: Dictionary = _items[i]
		var row := AfUI.hbox(10)
		var d := Registry.get_def("item", str(it["item"]))
		row.add_child(AfUI.label("%s ×%d  · %.1f кг" % [d.get("name", it["item"]), int(it["qty"]), float(d.get("weight", 0)) * int(it["qty"])], 18))
		row.add_child(AfUI.spacer())
		row.add_child(AfUI.button("Взять", _take.bind(i), 120))
		_list.add_child(row)
	if _container:
		world.container_updated(_container, _state)


func _take(i: int) -> void:
	if i >= _items.size():
		return
	var it: Dictionary = _items[i]
	var left := Session.player.inventory.add(str(it["item"]), int(it["qty"]), float(it["quality"]), float(it["condition"]))
	if left > 0:
		EventBus.toast("Слишком тяжело", "warn")
		it["qty"] = left
	else:
		_items.remove_at(i)
	if _corpse:
		_corpse.corpse_searched = _items.is_empty()
	_refresh()


func _take_all() -> void:
	if _search_left > 0.0:
		return
	var i := _items.size() - 1
	while i >= 0:
		_take(i)
		i -= 1
