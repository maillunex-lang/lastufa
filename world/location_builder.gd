class_name AfLocationBuilder
extends RefCounted
## Builds a playable 3D location from a data definition (core or package).
## Geometry is procedural (primitive meshes) until art packages provide GLB
## models; a building/prop may reference a model via "model": "pkg:assets/x.glb",
## which replaces its primitive mesh when the asset is available.

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_ZOMBIE := 4

static var _mats := {}
static var _window_tex: ImageTexture


static func mat(color: Color, rough: float = 0.9, emissive: Color = Color.BLACK) -> StandardMaterial3D:
	var key := "%s|%.2f|%s" % [color.to_html(), rough, emissive.to_html()]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	if emissive != Color.BLACK:
		m.emission_enabled = true
		m.emission = emissive
	_mats[key] = m
	return m


static func _windows() -> ImageTexture:
	if _window_tex:
		return _window_tex
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	img.fill(Color(0.85, 0.85, 0.85))
	for wx in [8, 36]:
		img.fill_rect(Rect2i(wx, 20, 20, 26), Color(0.22, 0.25, 0.28))
		img.fill_rect(Rect2i(wx + 9, 20, 2, 26), Color(0.6, 0.6, 0.6))
	img.fill_rect(Rect2i(0, 60, 64, 4), Color(0.7, 0.7, 0.7))
	img.generate_mipmaps()
	_window_tex = ImageTexture.create_from_image(img)
	return _window_tex


static func building_material(color: Color, windows: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	if windows:
		m.albedo_texture = _windows()
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(1.0 / 3.2, 1.0 / 3.0, 1.0 / 3.2)
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, m: Material, collide: bool, rot_y: float = 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	var holder: Node3D = mi
	if collide:
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
		body.add_child(mi)
		holder = body
	holder.position = pos
	holder.rotation.y = deg_to_rad(rot_y)
	parent.add_child(holder)
	return mi


static func _cyl(parent: Node3D, radius: float, height: float, pos: Vector3, m: Material, collide: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 14
	mi.mesh = cm
	mi.material_override = m
	var holder: Node3D = mi
	if collide:
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = height
		cs.shape = shape
		body.add_child(cs)
		body.add_child(mi)
		holder = body
	holder.position = pos
	parent.add_child(holder)
	return mi


static func v3(a: Array, y: float = 0.0) -> Vector3:
	return Vector3(float(a[0]), y, float(a[1]))


## Returns {root, nav, spawn, containers[], exits[], buildings[], lights[]}.
static func build(def: Dictionary) -> Dictionary:
	var out := {"containers": [], "exits": [], "buildings": [], "lights": []}
	var root := Node3D.new()
	root.name = "Location"
	var nav := NavigationRegion3D.new()
	nav.name = "Nav"
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = LAYER_WORLD
	nav.navigation_mesh = nm
	root.add_child(nav)
	var size: Array = def["size"]
	var w := float(size[0])
	var d := float(size[1])
	# ground + invisible boundary walls
	_box(nav, Vector3(w, 0.2, d), Vector3(0, -0.1, 0), mat(Color(def.get("ground_color", "#2b2c2a"))), true)
	for side in [[Vector3(w + 2, 4, 1), Vector3(0, 2, -d / 2 - 0.5)], [Vector3(w + 2, 4, 1), Vector3(0, 2, d / 2 + 0.5)],
			[Vector3(1, 4, d + 2), Vector3(-w / 2 - 0.5, 2, 0)], [Vector3(1, 4, d + 2), Vector3(w / 2 + 0.5, 2, 0)]]:
		var wall := _box(nav, side[0], side[1], mat(Color.BLACK), true)
		wall.visible = false
	var outer := _box(root, Vector3(w + 240, 0.1, d + 240), Vector3(0, -0.25, 0), mat(Color(def.get("ground_color", "#2b2c2a")).darkened(0.35)), false)
	outer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for p in def.get("patches", []):
		var ps: Array = p["size"]
		_box(root, Vector3(float(ps[0]), 0.02, float(ps[1])), v3(p["pos"], 0.01), mat(Color(p.get("color", "#333"))), false)
	var use_occluders := bool(Settings.p("occluders"))
	for b in def.get("buildings", []):
		var bs: Array = b["size"]
		var bsize := Vector3(float(bs[0]), float(bs[1]), float(bs[2]))
		var pos := v3(b["pos"], bsize.y / 2.0)
		var color := Color(b.get("color", "#888888"))
		var mi: MeshInstance3D
		if str(b.get("kind", "")) == "tank":
			mi = _cyl(nav, bsize.x / 2.0, bsize.y, pos, building_material(color, false), true)
		else:
			mi = _box(nav, bsize, pos, building_material(color, str(b.get("kind", "")) in ["panel", "office", "industrial"]), true)
			# roof cap
			_box(mi, Vector3(bsize.x + 0.3, 0.3, bsize.z + 0.3), Vector3(0, bsize.y / 2.0 + 0.15, 0), mat(color.darkened(0.45)), false)
		mi.set_meta("building_name", str(b.get("name", "")))
		out["buildings"].append(mi)
		if use_occluders and str(b.get("kind", "")) != "tank":
			var occ := OccluderInstance3D.new()
			var bo := BoxOccluder3D.new()
			bo.size = bsize * 0.98
			occ.occluder = bo
			occ.position = pos
			root.add_child(occ)
	var vis_range := float(Settings.p("prop_visibility_range"))
	for p in def.get("props", []):
		_build_prop(nav, root, p, vis_range)
	var lights_left := int(Settings.p("dynamic_lights"))
	for l in def.get("lights", []):
		var base := v3(l["pos"])
		_cyl(nav, 0.35, 0.9, base + Vector3(0, 0.45, 0), mat(Color("3b3430"), 0.7), true)
		var ember := _cyl(root, 0.3, 0.05, base + Vector3(0, 0.92, 0), mat(Color("ff7a1a"), 0.5, Color("ff6a10") * 2.5), false)
		ember.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if lights_left > 0:
			lights_left -= 1
			var omni := OmniLight3D.new()
			omni.light_color = Color("ff9a4a")
			omni.omni_range = 9.0
			omni.light_energy = 1.8
			omni.shadow_enabled = false
			omni.position = base + Vector3(0, 1.6, 0)
			root.add_child(omni)
			out["lights"].append(omni)
	for c in def.get("containers", []):
		var marker := Node3D.new()
		marker.position = v3(c["pos"])
		var crate := _box(marker, Vector3(0.7, 0.5, 0.5), Vector3(0, 0.25, 0), mat(Color("6b5a44")), false)
		crate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var glow := _box(marker, Vector3(0.18, 0.18, 0.18), Vector3(0, 0.75, 0), mat(AfTheme.ACCENT, 0.4, AfTheme.ACCENT * 1.8), false)
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker.set_meta("container", c)
		marker.set_meta("glow", glow)
		root.add_child(marker)
		out["containers"].append(marker)
	for e in def.get("exits", []):
		var ex := Node3D.new()
		ex.position = v3(e["pos"])
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = float(e.get("radius", 3.0)) - 0.25
		tm.outer_radius = float(e.get("radius", 3.0))
		ring.mesh = tm
		ring.material_override = mat(AfTheme.INFO, 0.4, AfTheme.INFO * 1.2)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ex.add_child(ring)
		var lbl := Label3D.new()
		lbl.text = str(e.get("name", "Выход"))
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.position = Vector3(0, 2.2, 0)
		lbl.font_size = 48
		lbl.pixel_size = 0.01
		lbl.modulate = AfTheme.INFO
		lbl.outline_size = 8
		ex.add_child(lbl)
		ex.set_meta("exit", e)
		root.add_child(ex)
		out["exits"].append(ex)
	out["root"] = root
	out["nav"] = nav
	out["spawn"] = v3(def.get("player_spawn", [0, 0]))
	return out


static func _build_prop(nav: Node3D, root: Node3D, p: Dictionary, vis_range: float) -> void:
	var pos := v3(p["pos"])
	var rot := float(p.get("rot", 0.0))
	var color := Color(p.get("color", "#777777"))
	var holder := Node3D.new()
	holder.position = pos
	holder.rotation.y = deg_to_rad(rot)
	var parts: Array[MeshInstance3D] = []
	match str(p.get("type", "")):
		"car":
			parts.append(_box(holder, Vector3(4.2, 0.8, 1.8), Vector3(0, 0.55, 0), mat(color, 0.5), false))
			parts.append(_box(holder, Vector3(2.2, 0.6, 1.6), Vector3(-0.2, 1.25, 0), mat(Color("20262c"), 0.2), false))
			_collider(nav, Vector3(4.2, 1.6, 1.8), pos + Vector3(0, 0.8, 0), rot)
		"bus":
			parts.append(_box(holder, Vector3(6.0, 2.2, 2.2), Vector3(0, 1.3, 0), mat(color, 0.6), false))
			parts.append(_box(holder, Vector3(5.6, 0.6, 2.25), Vector3(0, 1.8, 0), mat(Color("1d2328"), 0.2), false))
			_collider(nav, Vector3(6.0, 2.4, 2.2), pos + Vector3(0, 1.2, 0), rot)
		"barricade":
			for i in 3:
				parts.append(_box(holder, Vector3(3.0, 0.25, 0.25), Vector3(0, 0.3 + i * 0.35, 0), mat(Color("5a4632")), false))
			parts.append(_box(holder, Vector3(0.25, 1.2, 0.8), Vector3(-1.3, 0.6, 0), mat(Color("4a3a2a")), false))
			parts.append(_box(holder, Vector3(0.25, 1.2, 0.8), Vector3(1.3, 0.6, 0), mat(Color("4a3a2a")), false))
			_collider(nav, Vector3(3.0, 1.2, 0.6), pos + Vector3(0, 0.6, 0), rot)
		"bench":
			parts.append(_box(holder, Vector3(1.8, 0.1, 0.5), Vector3(0, 0.45, 0), mat(Color("6a4a2a")), false))
			parts.append(_box(holder, Vector3(1.8, 0.5, 0.08), Vector3(0, 0.75, -0.22), mat(Color("6a4a2a")), false))
		"swing":
			parts.append(_box(holder, Vector3(0.1, 2.2, 0.1), Vector3(-1.2, 1.1, 0), mat(Color("4c5a6a")), false))
			parts.append(_box(holder, Vector3(0.1, 2.2, 0.1), Vector3(1.2, 1.1, 0), mat(Color("4c5a6a")), false))
			parts.append(_box(holder, Vector3(2.5, 0.1, 0.1), Vector3(0, 2.2, 0), mat(Color("4c5a6a")), false))
		"tree":
			parts.append(_cyl(holder, 0.18, 2.4, Vector3(0, 1.2, 0), mat(Color("4a3b2c")), false))
			var crown := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 1.6
			sm.height = 2.8
			sm.radial_segments = 10
			sm.rings = 6
			crown.mesh = sm
			crown.material_override = mat(Color("3d4a2c") if Clock.season() != "autumn" else Color("7a5a24"))
			crown.position = Vector3(0, 3.2, 0)
			holder.add_child(crown)
			parts.append(crown)
			_collider(nav, Vector3(0.4, 2.0, 0.4), pos + Vector3(0, 1.0, 0), 0.0)
	for mi in parts:
		mi.visibility_range_end = vis_range
	root.add_child(holder)


static func _collider(parent: Node3D, size: Vector3, pos: Vector3, rot_deg: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	body.position = pos
	body.rotation.y = deg_to_rad(rot_deg)
	parent.add_child(body)
