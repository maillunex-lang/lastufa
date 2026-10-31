class_name AfHttpDownload
extends RefCounted
## Non-blocking resumable HTTP(S) download of one file into `<dest>.part`,
## driven by poll() each frame. Uses a Range request when a partial file
## exists; a 200 reply restarts from zero, 206 appends. Reads at most
## `max_bytes_per_poll` per call so the UI never stalls.

enum State { CONNECTING, REQUESTING, BODY, DONE, FAILED }

var url := ""
var dest := ""
var expected_size := -1
var state := State.CONNECTING
var error := ""
var bytes_done := 0
var max_bytes_per_poll := 512 * 1024
var timeout_sec := 20.0

var _client := HTTPClient.new()
var _file: FileAccess
var _host := ""
var _port := 80
var _tls := false
var _path := "/"
var _idle := 0.0
var _total_size := -1
var _redirects := 0
const MAX_REDIRECTS := 5


func start(p_url: String, p_dest: String, p_expected_size: int = -1) -> bool:
	url = p_url
	dest = p_dest
	expected_size = p_expected_size
	if not _parse_url(url):
		return _fail("некорректный URL: " + url)
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var part := dest + ".part"
	bytes_done = maxi(0, AfFs.file_size(part)) if FileAccess.file_exists(part) else 0
	if expected_size >= 0 and bytes_done > expected_size:
		DirAccess.remove_absolute(part)
		bytes_done = 0
	var err := _client.connect_to_host(_host, _port, TLSOptions.client() if _tls else null)
	if err != OK:
		return _fail("ошибка подключения (%d)" % err)
	state = State.CONNECTING
	return true


func _parse_url(u: String) -> bool:
	var rest := u
	if rest.begins_with("https://"):
		_tls = true
		_port = 443
		rest = rest.substr(8)
	elif rest.begins_with("http://"):
		_tls = false
		_port = 80
		rest = rest.substr(7)
	else:
		return false
	var slash := rest.find("/")
	var hostport := rest if slash < 0 else rest.substr(0, slash)
	_path = "/" if slash < 0 else rest.substr(slash)
	var colon := hostport.rfind(":")
	if colon > 0:
		_host = hostport.substr(0, colon)
		_port = hostport.substr(colon + 1).to_int()
	else:
		_host = hostport
	return _host != ""


## Returns bytes received during this poll.
func poll(delta: float) -> int:
	if state == State.DONE or state == State.FAILED:
		return 0
	_client.poll()
	var st := _client.get_status()
	var received := 0
	match state:
		State.CONNECTING:
			if st == HTTPClient.STATUS_CONNECTED:
				var headers := PackedStringArray(["User-Agent: AshenfallUFA/" + AfPaths.game_version(), "Accept-Encoding: identity"])
				if bytes_done > 0:
					headers.append("Range: bytes=%d-" % bytes_done)
				if _client.request(HTTPClient.METHOD_GET, _path, headers) != OK:
					_fail("ошибка запроса")
				else:
					state = State.REQUESTING
					_idle = 0.0
			elif st in [HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
				_fail("сервер недоступен (%d)" % st)
		State.REQUESTING:
			if st == HTTPClient.STATUS_BODY or (st == HTTPClient.STATUS_CONNECTED and _client.has_response()):
				var code := _client.get_response_code()
				if code in [301, 302, 303, 307, 308]:
					_follow_redirect()
					return 0
				var part := dest + ".part"
				if code == 206 and bytes_done > 0:
					_file = FileAccess.open(part, FileAccess.READ_WRITE)
					if _file:
						_file.seek_end()
				elif code == 200:
					bytes_done = 0
					_file = FileAccess.open(part, FileAccess.WRITE)
				elif code == 416 and expected_size >= 0 and bytes_done == expected_size:
					_complete()
					return 0
				else:
					_fail("HTTP %d" % code)
					return 0
				if _file == null:
					_fail("не удалось открыть файл для записи")
					return 0
				var length := _client.get_response_body_length()
				_total_size = bytes_done + length if length >= 0 else expected_size
				state = State.BODY
				_idle = 0.0
			elif st in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_DISCONNECTED]:
				_fail("соединение потеряно")
		State.BODY:
			if st == HTTPClient.STATUS_BODY:
				while received < max_bytes_per_poll:
					var chunk := _client.read_response_body_chunk()
					if chunk.is_empty():
						break
					_file.store_buffer(chunk)
					received += chunk.size()
					bytes_done += chunk.size()
					_client.poll()
					if _client.get_status() != HTTPClient.STATUS_BODY:
						break
			if _client.get_status() != HTTPClient.STATUS_BODY:
				if _total_size >= 0 and bytes_done < _total_size:
					_fail("загрузка прервана")
				else:
					_complete()
	if received > 0:
		_idle = 0.0
	else:
		_idle += delta
		if _idle > timeout_sec and state != State.DONE and state != State.FAILED:
			_fail("таймаут")
	return received


func _follow_redirect() -> void:
	var location := ""
	for h in _client.get_response_headers():
		if h.to_lower().begins_with("location:"):
			location = h.substr(9).strip_edges()
	_client.close()
	_redirects += 1
	if location == "" or _redirects > MAX_REDIRECTS:
		_fail("ошибка перенаправления")
		return
	if location.begins_with("/"):
		location = ("https://" if _tls else "http://") + _host + ("" if _port in [80, 443] else ":%d" % _port) + location
	url = location
	if not _parse_url(url) or _client.connect_to_host(_host, _port, TLSOptions.client() if _tls else null) != OK:
		_fail("ошибка перенаправления")
		return
	state = State.CONNECTING


func cancel() -> void:
	if _file:
		_file.close()
		_file = null
	_client.close()
	if state != State.DONE:
		state = State.FAILED
		error = "отменено"


func _complete() -> void:
	if _file:
		_file.flush()
		_file.close()
		_file = null
	_client.close()
	if expected_size >= 0 and bytes_done != expected_size:
		_fail("размер не совпадает (%d из %d)" % [bytes_done, expected_size])
		return
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(dest + ".part", dest) != OK:
		_fail("не удалось завершить файл")
		return
	state = State.DONE


func _fail(msg: String) -> bool:
	if _file:
		_file.close()
		_file = null
	_client.close()
	error = msg
	state = State.FAILED
	return false
