extends RefCounted


func test_parse_compare(t) -> void:
	t.eq(AfVersion.compare("1.2.3", "1.2.3"), 0, "equal")
	t.eq(AfVersion.compare("1.10.0", "1.9.9"), 1, "numeric minor")
	t.eq(AfVersion.compare("0.1", "0.1.0"), 0, "short form")
	t.eq(AfVersion.compare("2.0.0-beta", "2.0.0"), 0, "prerelease ignored")
	t.ok(not AfVersion.is_valid("abc"), "invalid")
	t.ok(not AfVersion.is_valid(""), "empty invalid")


func test_constraints(t) -> void:
	t.ok(AfVersion.satisfies("1.4.0", ">=1.2.0"), ">=")
	t.ok(not AfVersion.satisfies("1.1.0", ">=1.2.0"), ">= fails")
	t.ok(AfVersion.satisfies("1.4.0", "^1.2.0"), "caret")
	t.ok(not AfVersion.satisfies("2.0.0", "^1.2.0"), "caret major")
	t.ok(AfVersion.satisfies("1.2.9", "~1.2.0"), "tilde")
	t.ok(not AfVersion.satisfies("1.3.0", "~1.2.0"), "tilde minor")
	t.ok(AfVersion.satisfies("1.5.0", ">=1.0.0 <2.0.0"), "range")
	t.ok(not AfVersion.satisfies("2.1.0", ">=1.0.0, <2.0.0"), "range comma")
	t.ok(AfVersion.satisfies("9.9.9", "*"), "any")
	t.ok(AfVersion.satisfies("1.0.0", "1.0.0"), "exact")
