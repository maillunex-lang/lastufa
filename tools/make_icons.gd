extends SceneTree
## Renders icon.svg into the Android launcher icons (legacy + adaptive layers).
## godot --headless -s res://tools/make_icons.gd

func _init() -> void:
	var svg := FileAccess.get_file_as_string("res://icon.svg")
	var fg := svg.replace('<rect width="256" height="256" rx="40" fill="#15171b"/>', "").replace('viewBox="0 0 256 256"', 'viewBox="-64 -64 384 384"')
	var bg := '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256"><rect width="256" height="256" fill="#15171b"/></svg>'
	DirAccess.make_dir_recursive_absolute("res://android/icons")
	for spec in [["icon_192", 192, svg], ["icon_432_fg", 432, fg], ["icon_432_bg", 432, bg]]:
		var img := Image.new()
		img.load_svg_from_string(spec[2], float(spec[1]) / 256.0)
		img.save_png("res://android/icons/%s.png" % spec[0])
		print("%s %s" % [spec[0], img.get_size()])
	quit()
