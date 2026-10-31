class_name RegistryHelpers
extends RefCounted
## Id resolution for content referenced from inside a package: a short id is
## looked up in the package's own namespace first, then in core.


static func full_id_for(id: String, pkg: String, kind: String = "item") -> String:
	if id.contains(":"):
		return id
	var own := "%s:%s" % [pkg, id]
	if Registry.has_def(kind, own):
		return own
	return "core:" + id
