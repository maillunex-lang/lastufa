class_name AfItemCreatorPanel
extends AfPanel
## God game only: create any item from the registry (core and packages).

var _cat := "all"
var _list: VBoxContainer
var _chips: HFlowContainer
var _to_base := false

const CATS := {"all": "Все", "weapon": "Оружие", "ammo": "Патроны", "food": "Еда", "drink": "Питьё", "medical": "Медицина",
	"material": "Материалы", "clothing": "Одежда", "misc": "Разное"}


func _init() -> void:
	super._init("Создать предмет")
	_chips = HFlowContainer.new()
	_chips.add_theme_constant_override("h_separation", 8)
	_chips.add_theme_constant_override("v_separation", 8)
	body.add_child(_chips)
	if Session.base.exists:
		var row := AfUI.hbox(10)
		row.add_child(AfUI.label("Класть на склад убежища вместо рюкзака", 16, AfTheme.TEXT))
		var c := CheckButton.new()
		c.toggled.connect(func(on): _to_base = on)
		row.add_child(c)
		body.add_child(row)
	_list = AfUI.vbox(6)
	body.add_child(AfUI.scroll(_list))


func _ready() -> void:
	_render()


func _render() -> void:
	AfUI.clear(_chips)
	for k in CATS:
		var id: String = k
		var b := AfUI.accent_button(CATS[k]) if k == _cat else AfUI.button(CATS[k])
		b.custom_minimum_size = Vector2(0, 46)
		b.pressed.connect(func():
			_cat = id
			_render())
		_chips.add_child(b)
	AfUI.clear(_list)
	var items := Registry.all("item").filter(func(d): return _cat == "all" or str(d.get("category", "")) == _cat)
	items.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	for d in items:
		var row := AfUI.hbox(8)
		row.add_child(AfUI.label("%s  ·  %.2f кг" % [d["name"], float(d.get("weight", 0))], 17))
		row.add_child(AfUI.spacer())
		var id := str(d["id"])
		for n in [1, 10]:
			var qty: int = n
			row.add_child(AfUI.button("+%d" % qty, func(): _give(id, qty), 80))
		_list.add_child(row)


func _give(id: String, qty: int) -> void:
	var inv := Session.base.storage if _to_base and Session.base.exists else Session.player.inventory
	inv.add(id, qty, 1.0, 1.0, true)
	EventBus.toast("Создано: %s ×%d" % [Registry.display_name("item", id), qty], "good")
