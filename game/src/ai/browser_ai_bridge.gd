class_name BrowserAIBridge
extends RefCounted

## The Godot half of the browser AI subsystem.
##
## The rules of this file:
##   * It is the only place that touches JavaScriptBridge for AI.
##   * Every call is fire-and-forget or a cheap synchronous read. Inference
##     happens in a Web Worker (game/web/ai/), so nothing here can stall the
##     render loop, and a missing/broken bridge is a normal state, not an error.
##   * Arguments go over the wire base64-encoded: JSON full of quotes and
##     newlines through a JS string literal is how quoting bugs are born.
##
## Anything that is not the web export (desktop editor, headless tests, CI)
## simply reports "not available" and the game plays in Classic Mode.

const GLOBAL := "window.ModSimAI"
const PROTOCOL := "modsim-ai-1"

var last_error: String = ""
var last_code: String = ""   # last generated JS; the e2e report prints it
var calls := 0                 # how many JSON round-trips this bridge has made
## Headless tests have no JavaScriptBridge, but the pipeline above it (queue,
## validation, fallback, scoring) is exactly the same code. Forcing the probe
## lets the tests walk that path on desktop.
var force_present := false
var _probed := false
var _present := false

## Injected in tests: an object that implements the same surface as
## window.ModSimAI, so the integration can be exercised without a model.
var override_object_name: String = ""


static func is_web_platform() -> bool:
	return OS.has_feature("web")


func _global() -> String:
	return override_object_name if override_object_name != "" else GLOBAL


## Cheap existence check, cached: the menu calls it every time it opens.
func bridge_present() -> bool:
	if force_present:
		return true
	if not is_web_platform():
		return false
	if _probed:
		return _present
	_probed = true
	var v: Variant = _eval("!!(%s && %s.version)" % [_global(), _global()])
	_present = bool(v)
	return _present


func reset_probe() -> void:
	_probed = false
	_present = false


# ------------------------------------------------------------ JS plumbing

func _eval(code: String) -> Variant:
	if not is_web_platform():
		return null
	var v: Variant = JavaScriptBridge.eval(code, true)
	# A successful call clears the old complaint: the settings row shows this
	# text, and a stale error from before the bridge had loaded would be a lie.
	last_error = "" if v != null else "eval returned null"
	return v


func _b64(value: Variant) -> String:
	return Marshalls.raw_to_base64(JSON.stringify(value).to_utf8_buffer())


func _from_json(text: String) -> Variant:
	if text == "" or text == "null" or text == "undefined":
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		last_error = "bad JSON from bridge"
	return parsed


## Call a bridge method that returns JSON. The call is wrapped in try/catch on
## the JS side, so a broken model surfaces as a null return here rather than a
## Godot script error, and the reason is kept in last_error for the UI.
func _json_call(method: String, arg: Variant = null) -> Variant:
	if not bridge_present():
		return null
	calls += 1
	var code := _WRAPPER % _call_expr(method, arg)
	last_code = code
	var raw: Variant = _eval(code)
	if typeof(raw) != TYPE_STRING:
		return null
	var parsed: Variant = _from_json(String(raw))
	if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("__bridge_error"):
		last_error = String((parsed as Dictionary)["__bridge_error"])
		return null
	return parsed


const _WRAPPER := "(function(){try{var o=%s;" \
	+ "return typeof o==='string'?o:JSON.stringify(o===undefined?null:o);}" \
	+ "catch(e){return JSON.stringify({__bridge_error:String(e && e.message || e)});}})()"


func _call_expr(method: String, arg: Variant) -> String:
	var g := _global()
	if arg == null:
		return "%s.%s()" % [g, method]
	return "%s.%s(JSON.parse(atob(\"%s\")))" % [g, method, _b64(arg)]


## Fire-and-forget: the answer comes back through poll()/status().
func _send(method: String, arg: Variant = null) -> void:
	if not bridge_present():
		return
	var g := _global()
	var call := "%s.%s()" % [g, method] if arg == null \
		else "%s.%s(JSON.parse(atob(\"%s\")))" % [g, method, _b64(arg)]
	_eval("(function(){try{%s;}catch(e){return 0;}})()" % call)


# ------------------------------------------------------------ public API

func configure(patch: Dictionary) -> void:
	_send("configure", patch)


func capabilities() -> Dictionary:
	var v: Variant = _json_call("capabilities")
	return (v as Dictionary) if typeof(v) == TYPE_DICTIONARY else {}


func status() -> Dictionary:
	var v: Variant = _json_call("status")
	return (v as Dictionary) if typeof(v) == TYPE_DICTIONARY else {}


## Drain the bridge's event queue. Returns [] when there is nothing new.
func poll_events() -> Array:
	var v: Variant = _json_call("poll")
	return (v as Array) if typeof(v) == TYPE_ARRAY else []


func start(consent: bool = true, model_id: String = "") -> void:
	var arg := {"consent": consent}
	if model_id != "":
		arg["modelId"] = model_id
	_send("start", arg)


func request_batch(request: Dictionary = {}) -> void:
	_send("requestBatch", request)


## Take up to n validated messages out of the bridge queue. They are gone from
## the browser side once returned, so the caller owns them.
func take_messages(n: int = 1) -> Array:
	var v: Variant = _json_call("takeMessages", n)
	return (v as Array) if typeof(v) == TYPE_ARRAY else []


func peek_messages(n: int = 8) -> Array:
	var v: Variant = _json_call("peekMessages", n)
	return (v as Array) if typeof(v) == TYPE_ARRAY else []


func request_reactions(request: Dictionary = {}) -> void:
	_send("requestReactions", request)


func take_reactions(n: int = 1) -> Array:
	var v: Variant = _json_call("takeReactions", n)
	return (v as Array) if typeof(v) == TYPE_ARRAY else []


func cancel() -> void:
	_send("cancel")


func unload() -> void:
	_send("unload")


func delete_cache(model_id: String = "") -> void:
	_send("delete_cache", {"modelId": model_id} if model_id != "" else {})


func stats_request() -> void:
	_send("stats")


## Test-only: make the bridge produce garbage so the fallback path is covered.
func inject_fault(kind: String) -> void:
	_send("_fault", kind)
