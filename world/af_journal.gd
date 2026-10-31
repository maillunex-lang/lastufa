class_name AfJournal
extends RefCounted
## Chronicle of events (story, radio, world, combat). Also used to build the
## "while you were away" report after offline progress.

const MAX_ENTRIES := 400

var entries: Array = []   # [{t, category, text}]


func clear() -> void:
	entries.clear()


func add(category: String, text: String) -> void:
	var e := {"t": Clock.total_minutes, "category": category, "text": text}
	entries.append(e)
	if entries.size() > MAX_ENTRIES:
		entries = entries.slice(entries.size() - MAX_ENTRIES)
	EventBus.journal_entry.emit(e)


func since(t: float) -> Array:
	return entries.filter(func(e): return float(e["t"]) >= t)


func save_key() -> String:
	return "journal"


func schema_sql() -> PackedStringArray:
	return ["CREATE TABLE IF NOT EXISTS journal (id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, category TEXT DEFAULT 'misc', text TEXT)"]


func save_to_db(db: AfDatabase) -> void:
	db.exec("DELETE FROM journal")
	for e in entries:
		db.exec("INSERT INTO journal (t, category, text) VALUES (?, ?, ?)", [e["t"], e["category"], e["text"]])


func load_from_db(db: AfDatabase) -> void:
	entries.clear()
	for r in db.select("SELECT t, category, text FROM journal ORDER BY id"):
		entries.append({"t": float(r["t"]), "category": str(r["category"]), "text": str(r["text"])})
