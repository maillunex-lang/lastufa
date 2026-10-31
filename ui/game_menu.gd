class_name AfGameMenu
extends AfPanel
## In-game menu: save/load, settings, content, quit to main menu.

var world: AfGameWorld


func _init() -> void:
	super._init("Меню")
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(center)
	var v := AfUI.vbox(10)
	v.custom_minimum_size = Vector2(420, 0)
	center.add_child(v)
	v.add_child(AfUI.accent_button("Продолжить", close))
	v.add_child(AfUI.button("Сохранить", func(): get_parent().add_child(AfSaveLoadPanel.new(true))))
	v.add_child(AfUI.button("Загрузить", func(): get_parent().add_child(AfSaveLoadPanel.new(false))))
	v.add_child(AfUI.button("Контент и моды", func(): get_parent().add_child(AfContentPanel.new())))
	v.add_child(AfUI.button("Настройки", func(): get_parent().add_child(AfSettingsPanel.new())))
	v.add_child(AfUI.button("Выйти в главное меню", _quit_to_menu))
	var info := AfUI.label("Автосохранение каждые %d игровых минут и при сворачивании игры." % int(Settings.get_value("game/autosave_minutes")), 14, AfTheme.TEXT_DIM, true)
	v.add_child(info)


func _quit_to_menu() -> void:
	var tree := get_tree()
	Saves.save("autosave", "exit")
	Session.end_session()
	tree.change_scene_to_file("res://scenes/main_menu.tscn")
