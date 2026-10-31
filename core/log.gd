extends Node
## Leveled logger with an in-memory ring buffer (for the in-game debug view)
## and a rotating file sink in user://logs/.

enum Level { DEBUG, INFO, WARN, ERROR }

const BUFFER_MAX := 400
const FILE_MAX_BYTES := 1024 * 1024
const LOG_DIR := "user://logs"
const LOG_FILE := "user://logs/ashenfall.log"

var min_level: int = Level.DEBUG
var echo_to_stdout := true
var _buffer: PackedStringArray = []
var _file: FileAccess
var _error_count := 0

const _NAMES := ["DEBUG", "INFO", "WARN", "ERROR"]


func _enter_tree() -> void:
	DirAccess.make_dir_recursive_absolute(LOG_DIR)
	_rotate_if_needed()
	_file = FileAccess.open(LOG_FILE, FileAccess.READ_WRITE if FileAccess.file_exists(LOG_FILE) else FileAccess.WRITE)
	if _file:
		_file.seek_end()
	i("log", "--- session start %s ---" % Time.get_datetime_string_from_system())


func _rotate_if_needed() -> void:
	if not FileAccess.file_exists(LOG_FILE):
		return
	var f := FileAccess.open(LOG_FILE, FileAccess.READ)
	if f == null:
		return
	var size := f.get_length()
	f.close()
	if size > FILE_MAX_BYTES:
		var old := LOG_FILE + ".1"
		if FileAccess.file_exists(old):
			DirAccess.remove_absolute(old)
		DirAccess.rename_absolute(LOG_FILE, old)


func write(level: int, tag: String, msg: String) -> void:
	if level < min_level:
		return
	var line := "%s [%s] %s: %s" % [Time.get_time_string_from_system(), _NAMES[level], tag, msg]
	_buffer.append(line)
	if _buffer.size() > BUFFER_MAX:
		_buffer = _buffer.slice(_buffer.size() - BUFFER_MAX)
	if echo_to_stdout:
		if level >= Level.ERROR:
			printerr(line)
		else:
			print(line)
	if level >= Level.ERROR:
		_error_count += 1
	if _file:
		_file.store_line(line)
		if level >= Level.WARN:
			_file.flush()


func d(tag: String, msg: String) -> void:
	write(Level.DEBUG, tag, msg)


func i(tag: String, msg: String) -> void:
	write(Level.INFO, tag, msg)


func w(tag: String, msg: String) -> void:
	write(Level.WARN, tag, msg)


func e(tag: String, msg: String) -> void:
	write(Level.ERROR, tag, msg)


func recent(count: int = 50) -> PackedStringArray:
	return _buffer.slice(maxi(0, _buffer.size() - count))


func error_count() -> int:
	return _error_count


func _exit_tree() -> void:
	if _file:
		_file.flush()
		_file.close()
