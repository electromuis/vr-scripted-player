class_name TestCase
extends RefCounted

## Minimal assertion library for the vanilla test harness. If we outgrow this
## (fixtures, mocking, richer reporting), migrate to GUT — the API here is a
## deliberate subset so tests port cleanly.

var _failures: Array = []
var _current: String = ""


func begin(name: String) -> void:
	_current = name
	_failures = []


func failures() -> Array:
	return _failures


func fail(msg: String) -> void:
	_failures.append("[%s] %s" % [_current, msg])


func assert_true(cond: bool, msg: String = "") -> void:
	if not cond:
		fail("assert_true failed: %s" % msg)


func assert_false(cond: bool, msg: String = "") -> void:
	if cond:
		fail("assert_false failed: %s" % msg)


func assert_eq(a, b, msg: String = "") -> void:
	if a != b:
		fail("assert_eq failed (%s != %s) %s" % [a, b, msg])


func assert_has(haystack: String, needle: String, msg: String = "") -> void:
	if not haystack.contains(needle):
		fail("assert_has failed: '%s' not in '%s' %s" % [needle, haystack, msg])


func assert_ok(result: Dictionary, msg: String = "") -> void:
	if not result.get("ok", false):
		fail("assert_ok failed: %s | error=%s" % [msg, result.get("error", "(no error)")])


func assert_err(result: Dictionary, needle: String, msg: String = "") -> void:
	if result.get("ok", false):
		fail("assert_err expected failure but got ok: %s" % msg)
		return
	var errs: Array = result.get("errors", [])
	var joined := " | ".join(errs)
	if not joined.contains(needle):
		fail("assert_err: expected an error containing '%s' but got: %s" % [needle, joined])
