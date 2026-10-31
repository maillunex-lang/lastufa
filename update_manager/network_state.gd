class_name AfNetworkState
extends RefCounted
## Network type detection for the "download only over Wi-Fi" setting.
## On Android it queries ConnectivityManager through Godot's JNI bridge
## (JavaClassWrapper / AndroidRuntime plugin, Godot 4.4+). If the query is not
## possible the result is "unknown"; the update manager then treats the
## connection as metered when Wi-Fi-only is enabled (safe default).
## NOTE: verified only on desktop; the Android path needs on-device testing.

const TRANSPORT_WIFI := 1
const TRANSPORT_ETHERNET := 3


## Returns "unmetered", "metered" or "unknown".
static func connection_kind() -> String:
	if OS.get_name() != "Android":
		return "unmetered"
	if not Engine.has_singleton("AndroidRuntime"):
		return "unknown"
	var runtime: Object = Engine.get_singleton("AndroidRuntime")
	if runtime == null or not runtime.has_method("getApplicationContext"):
		return "unknown"
	var context: Object = runtime.call("getApplicationContext")
	if context == null:
		return "unknown"
	var cm: Object = context.call("getSystemService", "connectivity")
	if cm == null:
		return "unknown"
	var network: Object = cm.call("getActiveNetwork")
	if network == null:
		return "unknown"
	var caps: Object = cm.call("getNetworkCapabilities", network)
	if caps == null:
		return "unknown"
	if caps.call("hasTransport", TRANSPORT_WIFI) or caps.call("hasTransport", TRANSPORT_ETHERNET):
		return "unmetered"
	return "metered"


static func downloads_allowed(wifi_only: bool) -> bool:
	if not wifi_only:
		return true
	return connection_kind() == "unmetered"
