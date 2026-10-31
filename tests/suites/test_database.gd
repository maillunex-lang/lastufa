extends RefCounted


func test_open_migrate_bind(t) -> void:
	t.ok(AfDatabase.is_available(), "sqlite extension present")
	var dir: String = t.tmp_dir("db")
	var db := AfDatabase.new()
	t.ok(db.open(dir.path_join("a.db")), "open")
	var steps := [["CREATE TABLE x (id INTEGER PRIMARY KEY, name TEXT)"], ["ALTER TABLE x ADD COLUMN v REAL DEFAULT 0"]]
	t.ok(db.migrate(steps), "migrate")
	t.eq(db.user_version(), 2, "user_version")
	t.ok(db.exec("INSERT INTO x (name, v) VALUES (?, ?)", ["Уфа'; DROP TABLE x; --", 1.5]), "insert with binding")
	var rows := db.select("SELECT * FROM x")
	t.eq(rows.size(), 1, "one row")
	t.eq(str(rows[0]["name"]), "Уфа'; DROP TABLE x; --", "binding stored literally")
	t.ok(db.migrate(steps), "migrate idempotent")
	db.close()


func test_transaction_rollback(t) -> void:
	var dir: String = t.tmp_dir("db2")
	var db := AfDatabase.new()
	db.open(dir.path_join("b.db"))
	db.exec("CREATE TABLE y (v INTEGER)")
	db.begin()
	db.exec("INSERT INTO y VALUES (1)")
	db.rollback()
	t.eq(int(db.scalar("SELECT COUNT(*) AS n FROM y")), 0, "rolled back")
	t.ok(not db.exec("THIS IS NOT SQL"), "bad sql returns false")
	t.ok(db.last_error != "", "error message kept")
	db.close()


func test_system_db_ready(t) -> void:
	t.ok(SystemDB.available, "system db available")
	t.ok(SystemDB.db.table_exists("packages"), "packages table")
	t.ok(SystemDB.db.table_exists("downloads"), "downloads table")
	SystemDB.kv_set("k", "значение")
	t.eq(SystemDB.kv_get("k"), "значение", "kv roundtrip")
