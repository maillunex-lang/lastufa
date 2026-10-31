class_name AfSaveLoadPanel
extends AfPanel
## Slot list for saving (in game) or loading (menu and in game).

var saving := false
var _list: VBoxContainer
var on_loaded: Callable


func _init(p_saving: bool) -> void:
	saving = p_saving
	super._init("Сохранить игру" if saving else "Загрузить игру")
	_list = AfUI.vbox(8)
	body.add_child(AfUI.scroll(_list))


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	AfUI.clear(_list)
	for info in Saves.list_slots():
		var slot: String = info["slot"]
		if saving and slot == "autosave":
			continue
		var card := AfUI.card(12)
		var row := AfUI.hbox(12)
		card.add_child(row)
		var v := AfUI.vbox(2)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		var nice: String = str({"autosave": "Автосохранение", "quicksave": "Быстрое сохранение"}.get(slot, "Слот " + slot.get_slice("_", 1)))
		v.add_child(AfUI.label(nice, 20, AfTheme.ACCENT_SOFT))
		if info["exists"]:
			v.add_child(AfUI.label("День %s, %s · %s · %s · здоровье %s" % [info.get("day", "?"), info.get("time", ""), info.get("season", ""), info.get("region", ""), info.get("health", "?")], 16))
			v.add_child(AfUI.label("%s · v%s" % [str(info.get("saved_text", "")), info.get("game_version", "?")], 14, AfTheme.TEXT_DIM))
		else:
			v.add_child(AfUI.label("Пусто", 16, AfTheme.TEXT_DIM))
		if saving:
			row.add_child(AfUI.accent_button("Сохранить", func():
				if Saves.save(slot):
					EventBus.toast("Сохранено", "good")
				_rebuild(), 160))
		elif info["exists"]:
			row.add_child(AfUI.accent_button("Загрузить", _load.bind(slot), 160))
		if info["exists"] and slot != "autosave":
			row.add_child(AfUI.button("Удалить", func():
				Saves.delete_slot(slot)
				_rebuild(), 120))
		_list.add_child(card)


func _load(slot: String) -> void:
	var rep := Saves.load_slot(slot)
	if not rep["ok"]:
		AfDialog.show_in(self, "Ошибка загрузки", str(rep["error"]))
		return
	Saves.clear_crash_marker()
	var tree := get_tree()
	close()
	if tree.current_scene and tree.current_scene.scene_file_path == "res://scenes/game.tscn":
		tree.reload_current_scene()
	else:
		tree.change_scene_to_file("res://scenes/game.tscn")
