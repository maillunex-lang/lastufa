class_name AfDatabase
extends RefCounted
## Thin wrapper over the godot-sqlite GDExtension (class `SQLite`).
## All SQL goes through parameter bindings; callers never build SQL from data.

var _db: Object = null
var path := ""
var last_error := ""


static func is_available() -> bool:
	return ClassDB.class_exists("SQLite")


func open(db_path: String) -> bool:
	if not is_available():
		last_error = "SQLite extension is not available"
		Log.e("db", last_error)
		return false
	path = db_path
	DirAccess.make_dir_recursive_absolute(db_path.get_base_dir())
	_db = ClassDB.instantiate("SQLite")
	_db.set("path", db_path)
	_db.set("verbosity_level", 0)
	_db.set("foreign_keys", true)
	if not _db.call("open_db"):
		last_error = str(_db.get("error_message"))
		Log.e("db", "cannot open %s: %s" % [db_path, last_error])
		_db = null
		return false
	exec("PRAGMA journal_mode = WAL")
	exec("PRAGMA synchronous = NORMAL")
	return true


func is_open() -> bool:
	return _db != null


func close() -> void:
	if _db:
		# Fold the WAL back into the main file so the .db is self-contained
		# (important: saves are copied/hashed as single files).
		exec("PRAGMA wal_checkpoint(TRUNCATE)")
		exec("PRAGMA journal_mode = DELETE")
		_db.call("close_db")
		_db = null


func exec(sql: String, binds: Array = []) -> bool:
	if _db == null:
		last_error = "database not open"
		return false
	var ok: bool = _db.call("query_with_bindings", sql, binds) if not binds.is_empty() else _db.call("query", sql)
	if not ok:
		last_error = str(_db.get("error_message"))
		Log.e("db", "%s | SQL: %s" % [last_error, sql.substr(0, 160)])
	return ok


func select(sql: String, binds: Array = []) -> Array:
	if not exec(sql, binds):
		return []
	var res: Array = _db.get("query_result")
	return res.duplicate(true)


func scalar(sql: String, binds: Array = [], default_value: Variant = null) -> Variant:
	var rows := select(sql, binds)
	if rows.is_empty():
		return default_value
	var row: Dictionary = rows[0]
	return row.values()[0] if row.size() > 0 else default_value


func begin() -> bool:
	return exec("BEGIN IMMEDIATE")


func commit() -> bool:
	return exec("COMMIT")


func rollback() -> bool:
	return exec("ROLLBACK")


func user_version() -> int:
	return int(scalar("PRAGMA user_version", [], 0))


func set_user_version(v: int) -> void:
	exec("PRAGMA user_version = %d" % v)


func table_exists(table: String) -> bool:
	return int(scalar("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name=?", [table], 0)) > 0


func last_insert_id() -> int:
	return int(scalar("SELECT last_insert_rowid() AS id", [], 0))


## Runs ordered schema migrations: steps[i] upgrades from version i to i+1.
func migrate(steps: Array) -> bool:
	var v := user_version()
	while v < steps.size():
		begin()
		for sql in steps[v]:
			if not exec(sql):
				rollback()
				Log.e("db", "migration %d failed on %s" % [v, path])
				return false
		set_user_version(v + 1)
		commit()
		v += 1
	return true
