class_name AfBaseCompound
extends Node3D
## 3D view of the settlement inside the location where the base is.
## Every built module gets a visual group that grows with its level (Kenney
## "Survival Kit" CC0 models + a few procedural parts), shows wear, and is
## interactable; queued construction shows scaffolding with progress; the
## defenses level builds a fence ring; residents walk to their workplaces.

const KIT := "res://assets/models/kenney_survival/%s.glb"
const S := 5.0          # kit models are ~0.5 units; 5x gives human-sized props
const SLOT := 6.5       # slot spacing in metres
const ORDER := ["shelter", "kitchen", "storage", "workshop", "infirmary", "garden", "water", "generator", "radio"]

var world: AfGameWorld
var loc_def: Dictionary
var slots := {}         # module short id -> Vector3
var spots: Array = []   # [{node, module}] for interaction
var center := Vector3.ZERO
var radius := 10.0
var _blocked: Array[Rect2] = []
var _bounds := Rect2()
var _npcs := {}         # survivor id -> AfResidentNpc
var _t := 0.0
static var _cache := {}


static func model(name: String) -> Node3D:
	if not _cache.has(name):
		_cache[name] = load(KIT % name) if ResourceLoader.exists(KIT % name) else null
	var ps: PackedScene = _cache[name]
	if ps == null:
		return Node3D.new()
	var n: Node3D = ps.instantiate()
	n.scale = Vector3.ONE * S
	return n


func setup(p_world: AfGameWorld, def: Dictionary) -> void:
	world = p_world
	loc_def = def
	_find_slots()
	rebuild()
	Session.base.changed.connect(_on_changed)


func _exit_tree() -> void:
	if Session.base.changed.is_connected(_on_changed):
		Session.base.changed.disconnect(_on_changed)


var _dirty := false


func _on_changed() -> void:
	_dirty = true


# --- layout --------------------------------------------------------------------------

## Finds free 2D slots (not inside buildings, props, containers or exits) close
## to the player spawn, deterministic for a given location.
func _find_slots() -> void:
	var size: Array = loc_def["size"]
	var hw := float(size[0]) / 2.0 - 4.0
	var hd := float(size[1]) / 2.0 - 4.0
	var blocked: Array[Rect2] = []
	_bounds = Rect2(-hw, -hd, hw * 2.0, hd * 2.0)
	for b in loc_def.get("buildings", []):
		var bs: Array = b["size"]
		var p := AfLocationBuilder.v3(b["pos"])
		blocked.append(Rect2(p.x - float(bs[0]) / 2.0 - 1.5, p.z - float(bs[2]) / 2.0 - 1.5, float(bs[0]) + 3.0, float(bs[2]) + 3.0))
	for p in loc_def.get("props", []):
		var pp := AfLocationBuilder.v3(p["pos"])
		blocked.append(Rect2(pp.x - 3.5, pp.z - 3.5, 7.0, 7.0))
	for c in loc_def.get("containers", []) + loc_def.get("lights", []):
		var cp := AfLocationBuilder.v3(c["pos"])
		blocked.append(Rect2(cp.x - 2.0, cp.z - 2.0, 4.0, 4.0))
	for e in loc_def.get("exits", []):
		var ep := AfLocationBuilder.v3(e["pos"])
		blocked.append(Rect2(ep.x - 6.0, ep.z - 6.0, 12.0, 12.0))
	var spawn := AfLocationBuilder.v3(loc_def.get("player_spawn", [0, 0]))
	var free: Array = []
	var x := -hw
	while x <= hw:
		var z := -hd
		while z <= hd:
			var r := Rect2(x - 2.6, z - 2.6, 5.2, 5.2)
			var ok := true
			for bl in blocked:
				if bl.intersects(r):
					ok = false
					break
			if ok:
				free.append(Vector3(x, 0, z))
			z += SLOT
		x += SLOT
	# anchor: the free point with the most free neighbours near the spawn
	var best := spawn
	var best_score := -INF
	for f in free:
		var n := 0
		for g in free:
			if f.distance_to(g) <= SLOT * 1.6:
				n += 1
		var score: float = n * 10.0 - f.distance_to(spawn) * 0.6
		if score > best_score:
			best_score = score
			best = f
	free.sort_custom(func(a, b): return a.distance_to(best) < b.distance_to(best))
	_blocked = blocked
	for i in mini(ORDER.size(), free.size()):
		slots[ORDER[i]] = free[i]
	center = best
	radius = 6.0
	for k in slots:
		radius = maxf(radius, center.distance_to(slots[k]) + 4.5)


# --- visuals -------------------------------------------------------------------------

func rebuild() -> void:
	for c in get_children():
		if not (c is AfResidentNpc):
			c.queue_free()
	spots.clear()
	var b := Session.base
	for id in ORDER:
		if not slots.has(id):
			continue
		var lvl := b.level(id)
		var building := b.in_queue(id)
		if lvl == 0 and not building:
			continue
		var g := Node3D.new()
		g.position = slots[id]
		g.rotation.y = deg_to_rad(float(hash(id) % 4) * 90.0)
		add_child(g)
		if lvl > 0:
			call("_v_" + id, g, lvl)
			_apply_wear(g, b.condition(id))
		if building:
			_scaffold(g, id)
		var lbl := Label3D.new()
		var title := Registry.display_name("base_module", id)
		lbl.text = title + (" · ур. %d" % lvl if lvl > 0 else "")
		if building:
			var q: Dictionary = b.queue.filter(func(x): return str(x["module"]).ends_with(id))[0]
			lbl.text += "\nстроится %d%%" % int(100.0 * float(q["done"]) / float(q["need"]))
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.font_size = 30
		lbl.pixel_size = 0.01
		lbl.outline_size = 8
		lbl.modulate = AfTheme.ACCENT_SOFT
		lbl.position = Vector3(0, 3.6, 0)
		lbl.no_depth_test = true
		g.add_child(lbl)
		spots.append({"node": g, "module": id})
	if b.level("defenses") > 0:
		_fence(b.level("defenses"), b.condition("defenses"))
	elif b.in_queue("defenses"):
		var g2 := Node3D.new()
		g2.position = center + Vector3(radius, 0, 0)
		add_child(g2)
		_scaffold(g2, "defenses")


func _put(parent: Node3D, name: String, pos: Vector3, rot_deg: float = 0.0, extra_scale: float = 1.0) -> Node3D:
	var m := model(name)
	m.position = pos
	m.rotation.y = deg_to_rad(rot_deg)
	m.scale *= extra_scale
	parent.add_child(m)
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, emissive: Color = Color.BLACK) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = AfLocationBuilder.mat(color, 0.8, emissive)
	mi.position = pos
	parent.add_child(mi)
	return mi


func _v_shelter(g: Node3D, lvl: int) -> void:
	_put(g, "tent", Vector3(-1.2, 0, 0), 15)
	_put(g, "bedroll", Vector3(1.6, 0, 1.2), 80)
	if lvl >= 2:
		_put(g, "tent-canvas", Vector3(1.8, 0, -1.6), -20)
		_put(g, "bedroll", Vector3(-1.5, 0, 2.0), 10)
	if lvl >= 3:
		var hut := _put(g, "structure-metal", Vector3(0, 0, -3.2), 0, 1.15)
		_put(hut, "structure-metal-roof", Vector3(0, 0.5, 0), 0, 0.2)
	_put(g, "campfire-pit", Vector3(0.3, 0, 2.6))
	var fire := OmniLight3D.new()
	fire.light_color = Color("ff9a4a")
	fire.omni_range = 7.0
	fire.light_energy = 1.4
	fire.position = Vector3(0.3, 1.0, 2.6)
	g.add_child(fire)


func _v_storage(g: Node3D, lvl: int) -> void:
	_put(g, "box-large", Vector3(-1.4, 0, 0), 0)
	_put(g, "box", Vector3(0.2, 0, 0.6), 25)
	_put(g, "barrel", Vector3(1.4, 0, -0.6))
	_put(g, "barrel", Vector3(1.9, 0, 0.6))
	if lvl >= 2:
		_put(g, "chest", Vector3(-0.4, 0, -1.6), 180)
		_put(g, "box-large-open", Vector3(-1.4, 0, 1.6), 90)
		_put(g, "resource-planks", Vector3(1.0, 0, 2.0))
	if lvl >= 3:
		_put(g, "structure-canvas", Vector3(0, 0, 0), 0, 1.4)


func _v_workshop(g: Node3D, lvl: int) -> void:
	_put(g, "workbench", Vector3(0, 0, 0))
	_put(g, "tool-hammer", Vector3(-0.3, 1.2, 0.1), 30, 0.7)
	_put(g, "resource-wood", Vector3(1.8, 0, 1.0))
	if lvl >= 2:
		_put(g, "workbench-anvil", Vector3(-1.8, 0, 0.4))
	if lvl >= 3:
		_put(g, "workbench-grind", Vector3(1.6, 0, -1.2))
		_put(g, "structure-metal-roof", Vector3(0, 0, 0), 0, 1.6)


func _v_infirmary(g: Node3D, lvl: int) -> void:
	_put(g, "tent-canvas", Vector3(0, 0, 0), 0, 1.2)
	_put(g, "bedroll-frame", Vector3(1.6, 0, 1.8), 90)
	if lvl >= 2:
		_put(g, "bedroll-frame", Vector3(-1.6, 0, 1.8), 90)
	var sign := Node3D.new()
	sign.position = Vector3(0, 3.0, 1.6)
	g.add_child(sign)
	_box(sign, Vector3(0.9, 0.25, 0.08), Vector3.ZERO, Color("d0473e"), Color("d0473e") * 0.6)
	_box(sign, Vector3(0.25, 0.9, 0.08), Vector3.ZERO, Color("d0473e"), Color("d0473e") * 0.6)


func _v_kitchen(g: Node3D, lvl: int) -> void:
	_put(g, "campfire-stand", Vector3(0, 0, 0))
	_put(g, "bucket", Vector3(1.4, 0, 0.6))
	_put(g, "bottle-large", Vector3(-1.2, 0, 0.8))
	_put(g, "box", Vector3(-1.6, 0, -0.8), 10)
	if lvl >= 2:
		_put(g, "campfire-fishing-stand", Vector3(0.8, 0, -1.6))
	var fire := OmniLight3D.new()
	fire.light_color = Color("ffa050")
	fire.omni_range = 5.0
	fire.light_energy = 1.0
	fire.position = Vector3(0, 0.8, 0)
	g.add_child(fire)


func _v_garden(g: Node3D, lvl: int) -> void:
	var beds := 2 + lvl
	for i in beds:
		var bed := _box(g, Vector3(1.0, 0.25, 3.4), Vector3(-2.0 + i * 1.35, 0.12, 0), Color("4a3524"))
		var sprout_col := Color("5f8a3a") if Clock.season() != "winter" or lvl >= 3 else Color("6d6a5e")
		for k in 3:
			var sp := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.28
			sm.height = 0.4
			sm.radial_segments = 6
			sm.rings = 3
			sp.mesh = sm
			sp.material_override = AfLocationBuilder.mat(sprout_col)
			sp.position = Vector3(0, 0.3, -1.1 + k * 1.1)
			bed.add_child(sp)
	_put(g, "tool-hoe", Vector3(2.4, 0, 1.6), 40, 0.8)
	if lvl >= 3:
		var glass := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(beds * 1.35 + 0.8, 2.4, 4.0)
		glass.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.75, 0.9, 1.0, 0.18)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.1
		glass.material_override = m
		glass.position = Vector3(-2.0 + (beds - 1) * 0.675, 1.2, 0)
		g.add_child(glass)


func _v_water(g: Node3D, lvl: int) -> void:
	_put(g, "barrel-open", Vector3(-0.8, 0, 0))
	_put(g, "barrel-open", Vector3(0.8, 0, 0.3))
	_put(g, "bucket", Vector3(0, 0, 1.4))
	_box(g, Vector3(2.6, 0.08, 2.0), Vector3(0, 2.2, 0), Color("5a6f7a"))  # rain tarp
	for c in [Vector3(-1.2, 1.1, -0.9), Vector3(1.2, 1.1, -0.9), Vector3(-1.2, 1.1, 0.9), Vector3(1.2, 1.1, 0.9)]:
		_box(g, Vector3(0.08, 2.2, 0.08), c, Color("4a3b2c"))
	if lvl >= 2:
		var tank := _box(g, Vector3(1.4, 1.6, 1.4), Vector3(2.4, 0.8, -1.2), Color("6f8a96"))
		tank.name = "tank"


func _v_generator(g: Node3D, _lvl: int) -> void:
	var body := _box(g, Vector3(1.8, 1.1, 1.0), Vector3(0, 0.55, 0), Color("c08a2a"))
	body.name = "engine"
	_box(g, Vector3(0.2, 0.6, 0.2), Vector3(0.6, 1.4, 0.2), Color("2a2a2a"))
	_put(g, "barrel", Vector3(1.6, 0, 0.8))
	_put(g, "barrel", Vector3(-1.6, 0, 0.6))
	_put(g, "metal-panel", Vector3(0, 0, -1.4))


func _v_radio(g: Node3D, lvl: int) -> void:
	var h := 6.0 + lvl * 2.0
	for i in 3:
		var a := TAU * i / 3.0
		var leg := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.04
		cm.bottom_radius = 0.06
		cm.height = h
		leg.mesh = cm
		leg.material_override = AfLocationBuilder.mat(Color("9a9aa0"), 0.4)
		leg.position = Vector3(cos(a) * 0.4, h / 2.0, sin(a) * 0.4)
		g.add_child(leg)
	var tip := _box(g, Vector3(0.25, 0.25, 0.25), Vector3(0, h + 0.1, 0), Color("ff3a2a"), Color("ff3a2a") * 2.0)
	tip.name = "beacon"
	_box(g, Vector3(1.2, 0.9, 0.7), Vector3(1.2, 0.45, 0.8), Color("4b5a3a"))
	_put(g, "signpost-single", Vector3(-1.4, 0, 1.0))


func _scaffold(g: Node3D, id: String) -> void:
	var s := _put(g, "structure", Vector3(0, 0, 0), 0, 1.1)
	s.name = "scaffold_" + id
	_put(g, "resource-planks", Vector3(1.8, 0, 1.2))
	_put(g, "tool-shovel", Vector3(-1.6, 0, 1.4), 60, 0.8)


func _fence(lvl: int, cond: float) -> void:
	var piece := "fence" if lvl == 1 else "fence-fortified"
	var seg := 0.5 * S
	var count := int(TAU * radius / seg)
	var spawn := AfLocationBuilder.v3(loc_def.get("player_spawn", [0, 0]))
	var gate_dir := (spawn - center).normalized() if spawn.distance_to(center) > 0.1 else Vector3.BACK
	var gate_angle := atan2(gate_dir.z, gate_dir.x)
	for i in count:
		var a := TAU * i / count
		if absf(wrapf(a - gate_angle, -PI, PI)) < 0.35:
			continue  # gate opening towards the yard entrance
		if lvl == 1 and i % 3 == 2:
			continue  # first level: gaps between sections
		if cond < 0.5 and hash(i) % 4 == 0:
			continue  # broken sections
		var p := center + Vector3(cos(a), 0, sin(a)) * radius
		var pr := Rect2(p.x - 0.8, p.z - 0.8, 1.6, 1.6)
		if not _bounds.encloses(pr) or _blocked.any(func(bl): return bl.grow(-1.0).intersects(pr)):
			continue  # never run the fence through houses or past the map edge
		var f := _put(self, piece, p, rad_to_deg(-a) + 90.0)
		if lvl >= 3:
			f.scale.y *= 1.4
		var body := StaticBody3D.new()
		body.collision_layer = AfLocationBuilder.LAYER_WORLD
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(seg, 2.0, 0.3)
		cs.shape = shape
		body.add_child(cs)
		body.position = p + Vector3(0, 1.0, 0)
		body.rotation.y = -a + PI / 2.0
		add_child(body)


func _apply_wear(g: Node3D, cond: float) -> void:
	if cond >= 0.6:
		return
	g.rotation.z = deg_to_rad((0.6 - cond) * 12.0)
	for mi in g.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).transparency = 0.0
		(mi as GeometryInstance3D).material_overlay = _wear_mat()


static var _wear: StandardMaterial3D


static func _wear_mat() -> StandardMaterial3D:
	if _wear == null:
		_wear = StandardMaterial3D.new()
		_wear.albedo_color = Color(0.1, 0.08, 0.06, 0.45)
		_wear.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_wear.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _wear


# --- residents & animation ------------------------------------------------------------

## Where a survivor goes for their job.
func station_for(p: Dictionary) -> Vector3:
	var job := str(p["job"])
	var jitter := Vector3(float(int(p["id"]) * 37 % 7) - 3.0, 0, float(int(p["id"]) * 53 % 7) - 3.0) * 0.4
	if slots.has(job) and Session.base.level(job) > 0:
		return slots[job] + Vector3(0, 0, 2.2) + jitter * 0.4
	if job == "build" and not Session.base.queue.is_empty():
		var id := str(Session.base.queue[0]["module"]).get_slice(":", 1)
		if slots.has(id):
			return slots[id] + Vector3(1.5, 0, 1.5) + jitter * 0.3
	if job == "guard":
		var a := float(int(p["id"]) * 97 % 360) * PI / 180.0
		return center + Vector3(cos(a), 0, sin(a)) * (radius - 1.5)
	var rest: Vector3 = slots.get("shelter", center)
	return rest + Vector3(0, 0, 3.0) + jitter


func _process(delta: float) -> void:
	_t += delta
	if _dirty:
		_dirty = false
		rebuild()
		_sync_npcs()
	if int(_t * 2.0) != int((_t - delta) * 2.0):
		_sync_npcs()
	var powered := Session.base.power_output() > 0.0
	for s in spots:
		var g: Node3D = s["node"]
		if s["module"] == "generator" and powered:
			var e := g.get_node_or_null("engine")
			if e:
				e.position.y = 0.55 + sin(_t * 40.0) * 0.015
		elif s["module"] == "radio":
			var b := g.get_node_or_null("beacon")
			if b:
				b.visible = powered and fmod(_t, 1.2) < 0.6


func _sync_npcs() -> void:
	var here := Session.survivors.at_base()
	var ids := {}
	for p in here:
		ids[int(p["id"])] = true
		var npc: AfResidentNpc = _npcs.get(int(p["id"]))
		if npc == null:
			npc = AfResidentNpc.new()
			npc.setup(p)
			npc.position = station_for(p) + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
			add_child(npc)
			_npcs[int(p["id"])] = npc
		npc.target = station_for(p)
		npc.refresh(p)
	for id in _npcs.keys():
		if not ids.has(id):
			_npcs[id].queue_free()
			_npcs.erase(id)


func npcs() -> Array:
	return _npcs.values()
