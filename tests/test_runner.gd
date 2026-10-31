extends Node
## Headless test runner. Usage:
##   godot --headless res://tests/test_runner.tscn            (all suites)
##   godot --headless res://tests/test_runner.tscn -- suite=saves
## Exit code 0 = all passed. Each suite is a script with test_* methods that
## receive this runner as `t` for assertions. Run through tests/run_tests.sh,
## which points XDG_DATA_HOME at a temporary directory so user:// is isolated.

const SUITES := [
	"res://tests/suites/test_version.gd",
	"res://tests/suites/test_clock_scheduler.gd",
	"res://tests/suites/test_database.gd",
	"res://tests/suites/test_packages.gd",
	"res://tests/suites/test_registry.gd",
	"res://tests/suites/test_survival.gd",
	"res://tests/suites/test_world.gd",
	"res://tests/suites/test_saves.gd",
	"res://tests/suites/test_rules.gd",
	"res://tests/suites/test_updates.gd",
	"res://tests/suites/test_base.gd",
	"res://tests/suites/test_gameplay.gd",
]

var passed := 0
var failed := 0
var _current := ""
var _failures: PackedStringArray = []


func _ready() -> void:
	Log.echo_to_stdout = false
	# watchdog: a broken test must never hang CI
	var limit := float(OS.get_environment("AF_TEST_TIMEOUT")) if OS.get_environment("AF_TEST_TIMEOUT") != "" else 240.0
	get_tree().create_timer(limit, true, false, true).timeout.connect(func():
		print("TIMEOUT in " + _current)
		get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("suite="):
			only = a.substr(6)
	var t0 := Time.get_ticks_msec()
	for path in SUITES:
		if only != "" and not path.contains(only):
			continue
		_current = path.get_file().get_basename()
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			_fail_raw("cannot load/compile suite " + path)
			continue
		var suite: Object = script.new()
		for m in suite.get_method_list():
			var mname: String = m["name"]
			if not mname.begins_with("test_"):
				continue
			_current = "%s::%s" % [path.get_file().get_basename(), mname]
			if OS.get_environment("AF_TEST_VERBOSE") != "":
				print("  ... " + _current)
			var before := failed
			if suite.has_method("before_each"):
				await suite.call("before_each", self)
			await suite.call(mname, self)
			if suite.has_method("after_each"):
				await suite.call("after_each", self)
			print(("  ok   " if failed == before else "  FAIL ") + _current)
	print("\n%d passed, %d failed in %d ms" % [passed, failed, Time.get_ticks_msec() - t0])
	for f in _failures:
		print("  - " + f)
	if Session.active:
		Session.end_session()
	get_tree().quit(0 if failed == 0 else 1)


func ok(cond: bool, msg: String = "") -> void:
	if cond:
		passed += 1
	else:
		_fail_raw(msg)


func eq(a: Variant, b: Variant, msg: String = "") -> void:
	if typeof(a) == typeof(b) and a == b or (typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT] and is_equal_approx(float(a), float(b))):
		passed += 1
	else:
		_fail_raw("%s: expected %s, got %s" % [msg, str(b), str(a)])


func near(a: float, b: float, eps: float, msg: String = "") -> void:
	ok(absf(a - b) <= eps, "%s: %f not within %f of %f" % [msg, a, eps, b])


func _fail_raw(msg: String) -> void:
	failed += 1
	_failures.append("%s: %s" % [_current, msg])


## Writes a ZIP with the given {path: String|PackedByteArray} entries.
func make_zip(path: String, entries: Dictionary) -> void:
	var z := ZIPPacker.new()
	z.open(path)
	for name in entries:
		z.start_file(name)
		var v: Variant = entries[name]
		z.write_file(v if v is PackedByteArray else str(v).to_utf8_buffer())
		z.close_file()
	z.close()


func tmp_dir(name: String) -> String:
	var p := "user://test_tmp".path_join(name)
	AfFs.remove_recursive(p)
	DirAccess.make_dir_recursive_absolute(p)
	return p
