extends Node
## Global decoupled event channel. Systems publish facts here; UI and other
## systems subscribe. Keep payloads plain data (no node references that may be
## freed) so the same events can later be serialized for local co-op sync.

## UI notification: kind is one of "info", "good", "warn", "danger".
signal notify(text: String, kind: String)

## Gameplay facts
signal noise_emitted(position: Vector3, radius: float, source: String)
signal zombie_killed(type_id: String, position: Vector3)
signal player_damaged(amount: float, source: String)
signal player_died(cause: String)
signal item_used(item_id: String)
signal container_looted(container_id: String, location_id: String)
signal location_entered(location_id: String)
signal region_visited(region_id: String)
signal journal_entry(entry: Dictionary)

## Session lifecycle
signal session_started
signal session_ending
signal session_ended
signal game_saved(slot: String, ok: bool)
signal game_loaded(slot: String)

## Content pipeline
signal content_reloaded
signal package_changed(package_id: String)

## Decision moments that freeze time (dialogs, important choices)
signal decision_opened(reason: String)
signal decision_closed(reason: String)


func toast(text: String, kind: String = "info") -> void:
	notify.emit(text, kind)
