class_name AfSaveMigrations
extends RefCounted
## Ordered save-format migrations. STEPS[n] upgrades a save from format n to
## n+1. A migration runs on a copy of the save database (the original stays in
## the slot's backups) and must be idempotent-safe SQL.

const STEPS := {
	# v1 -> v2: journal entries gained a category column.
	1: [
		"ALTER TABLE journal ADD COLUMN category TEXT DEFAULT 'misc'",
	],
}


## Returns "" on success or an error text.
static func migrate(db: AfDatabase, from_version: int) -> String:
	var v := from_version
	while v < AfPaths.SAVE_FORMAT_VERSION:
		if not STEPS.has(v):
			return "нет миграции сохранения с версии %d" % v
		db.begin()
		for sql in STEPS[v]:
			if not db.exec(sql):
				db.rollback()
				return "ошибка миграции %d→%d: %s" % [v, v + 1, db.last_error]
		db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('format_version', ?)", [str(v + 1)])
		db.commit()
		Log.i("saves", "migrated save format %d -> %d" % [v, v + 1])
		v += 1
	return ""
