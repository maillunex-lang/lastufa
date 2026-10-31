class_name AfPaths
extends RefCounted
## Canonical storage layout. Everything downloadable or user-generated lives in
## user:// so that APK updates never touch it.

const GAME_VERSION := "0.1.0"
## Version of the content/mod API exposed to packages (data schemas + rule engine).
const MOD_API_VERSION := 1
## Save format version. Bump together with a migration in saves/save_migrations.gd.
const SAVE_FORMAT_VERSION := 2

const CORE_PACKAGE_DIR := "res://data/core"
const CONTENT_ROOT := "user://content"
const PACKAGES_DIR := "user://content/packages"
const STAGING_DIR := "user://content/staging"
const BACKUPS_DIR := "user://content/backups"
const DOWNLOADS_DIR := "user://content/downloads"
const CACHE_DIR := "user://content/cache"
const IMPORT_DIR := "user://import"
const SAVES_DIR := "user://saves"
const SYSTEM_DB := "user://system.db"
const SESSION_LOCK := "user://session.lock"


static func ensure_dirs() -> void:
	for d in [CONTENT_ROOT, PACKAGES_DIR, STAGING_DIR, BACKUPS_DIR, DOWNLOADS_DIR, CACHE_DIR, IMPORT_DIR, SAVES_DIR]:
		DirAccess.make_dir_recursive_absolute(d)


static func game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", GAME_VERSION))
