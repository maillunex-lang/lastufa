extends Node
## Device-level database (user://system.db): installed packages, their file
## lists, install history and the persistent download queue. Separate from
## per-slot save databases so content management never touches saves.

var db := AfDatabase.new()
var available := false

const MIGRATIONS := [
	[
		"""CREATE TABLE packages (
			id TEXT PRIMARY KEY,
			type TEXT NOT NULL,
			name TEXT NOT NULL,
			version TEXT NOT NULL,
			enabled INTEGER NOT NULL DEFAULT 1,
			load_order INTEGER NOT NULL DEFAULT 100,
			install_path TEXT NOT NULL,
			manifest_json TEXT NOT NULL,
			size_bytes INTEGER NOT NULL DEFAULT 0,
			source TEXT NOT NULL DEFAULT 'manual',
			signed INTEGER NOT NULL DEFAULT 0,
			status TEXT NOT NULL DEFAULT 'ok',
			installed_at INTEGER NOT NULL
		)""",
		"""CREATE TABLE package_files (
			package_id TEXT NOT NULL,
			path TEXT NOT NULL,
			sha256 TEXT NOT NULL,
			size INTEGER NOT NULL,
			PRIMARY KEY (package_id, path)
		)""",
		"""CREATE TABLE package_history (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			package_id TEXT NOT NULL,
			action TEXT NOT NULL,
			from_version TEXT,
			to_version TEXT,
			note TEXT,
			at INTEGER NOT NULL
		)""",
		"""CREATE TABLE downloads (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			job TEXT NOT NULL,
			package_id TEXT NOT NULL,
			version TEXT NOT NULL,
			rel_path TEXT NOT NULL,
			url_path TEXT NOT NULL,
			dest TEXT NOT NULL,
			sha256 TEXT NOT NULL,
			size INTEGER NOT NULL,
			downloaded INTEGER NOT NULL DEFAULT 0,
			priority INTEGER NOT NULL DEFAULT 0,
			state TEXT NOT NULL DEFAULT 'queued',
			attempts INTEGER NOT NULL DEFAULT 0,
			last_error TEXT,
			created_at INTEGER NOT NULL
		)""",
		"CREATE INDEX idx_downloads_job ON downloads(job)",
		"""CREATE TABLE download_jobs (
			job TEXT PRIMARY KEY,
			package_id TEXT NOT NULL,
			version TEXT NOT NULL,
			manifest_json TEXT NOT NULL,
			priority INTEGER NOT NULL DEFAULT 0,
			state TEXT NOT NULL DEFAULT 'queued',
			created_at INTEGER NOT NULL
		)""",
		"CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT)",
	],
]


func _enter_tree() -> void:
	AfPaths.ensure_dirs()
	available = db.open(AfPaths.SYSTEM_DB)
	if not available:
		Log.e("systemdb", "system database unavailable; content management disabled")
		return
	if not db.migrate(MIGRATIONS):
		Log.e("systemdb", "system database migration failed")
		available = false


func kv_get(key: String, default_value: String = "") -> String:
	var v: Variant = db.scalar("SELECT value FROM kv WHERE key = ?", [key], null)
	return default_value if v == null else str(v)


func kv_set(key: String, value: String) -> void:
	db.exec("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [key, value])


func log_history(package_id: String, action: String, from_v: String, to_v: String, note: String = "") -> void:
	db.exec("INSERT INTO package_history (package_id, action, from_version, to_version, note, at) VALUES (?, ?, ?, ?, ?, ?)",
		[package_id, action, from_v, to_v, note, int(Time.get_unix_time_from_system())])


func _exit_tree() -> void:
	db.close()
