class_name AIChatManager
extends RefCounted

## Keeps a bounded queue of AI-generated chat messages, and quietly falls back
## to the authored dataset whenever the model cannot keep up.
##
## The contract with the game is small:
##
##     if ai != null and ai.will_serve():  use ai.next_message()
##     else:                               use the dataset
##
## Everything else lives here: polling the bridge, asking for the next batch
## before the queue runs dry, re-validating what came back, timing out an
## inference that never finishes, and remembering how much of tonight's chat was
## actually written by the model - because the UI has to say CLASSIC when it
## was not, and that honesty is the whole point of having two modes.

signal changed
signal consent_required(info: Dictionary)
signal ready(info: Dictionary)
signal failed(reason: String)

const POLL_INTERVAL := 0.25
const BATCH_COOLDOWN := 1.0
const GENERATION_TIMEOUT := 150.0
const MAX_QUEUE_DEFAULT := 24
const LOW_WATER_DEFAULT := 4

var bridge := BrowserAIBridge.new()
var catalog: MessageCatalog
var bal: Balance
var director: DifficultyDirector

var enabled := false                 # the player asked for AI chat
var consented := false               # and agreed to the weights download
var profile: String = "auto"         # light | auto | standard | quality
var max_queue: int = MAX_QUEUE_DEFAULT
var low_water: int = LOW_WATER_DEFAULT
var model_id: String = ""            # "" -> let the bridge recommend

var phase: String = "off"
var status: Dictionary = {}
var capabilities: Dictionary = {}
var last_error: String = ""
var last_consent_info: Dictionary = {}
var ready_flag := false

var elapsed: float = 0.0
var stream_info: Dictionary = {}
var cast: Array = []                 # [{username, persona, offenses}]
## Set by the sim: a Callable returning the recurring cast, so the model can
## bring back the same noisy regulars instead of inventing new names.
var cast_provider: Callable = Callable()
var banned: Dictionary = {}

var _queue: Array = []
var _reactions: Array = []
var _poll_accum := 0.0
var _inflight := false
var _inflight_at := 0.0
var _last_request_at := -99.0
var _recent: Array = []              # last few messages, for context

# What actually went on screen. Reported to the player and to the results screen.
var served_ai := 0
var served_classic := 0
var dropped := 0
var repaired := 0
var batches_ok := 0
var batches_failed := 0


func _init(content: MessageCatalog = null, balance: Balance = null) -> void:
	catalog = content if content != null else MessageCatalog.load_default()
	bal = balance if balance != null else Balance.load_default()


func configure(new_director: DifficultyDirector, stream: Dictionary, opts: Dictionary = {}) -> void:
	if new_director != null:
		director = new_director
	if not stream.is_empty():
		stream_info = stream
	enabled = bool(opts.get("enabled", enabled))
	consented = bool(opts.get("consented", consented))
	profile = String(opts.get("profile", profile))
	model_id = String(opts.get("model_id", model_id))
	var patch := {
		"profile": profile,
		"consent": consented,
		"maxQueue": max_queue,
	}
	if model_id != "":
		patch["modelId"] = model_id
	var target := int(opts.get("batch_target", 0))
	if target > 0:
		patch["batchTarget"] = target
	bridge.configure(patch)
	_reset_run()


func _reset_run() -> void:
	_queue.clear()
	_reactions.clear()
	_recent.clear()
	_inflight = false
	served_ai = 0
	served_classic = 0
	dropped = 0
	repaired = 0
	batches_ok = 0
	batches_failed = 0
	elapsed = 0.0


## Drive the bridge. Called from the game screen's _process, and directly by
## tests. Cheap when there is nothing to do.
func tick(delta: float) -> void:
	if not bridge.bridge_present():
		return
	_poll_accum += delta
	if _poll_accum >= POLL_INTERVAL:
		_poll_accum = 0.0
		_drain_events()
		_refresh_status()
		_pull()
	_check_timeout()
	_maybe_request()


## Move whatever the browser has already validated into our own queue. The
## bridge keeps the raw model output; nothing reaches the game before
## AIContent has had its say (that is the second, Godot-side gate).
func _pull() -> void:
	if _queue.size() >= max_queue:
		return
	var want: int = clampi(low_water - _queue.size(), 0, 8)
	if want <= 0 and _queue.size() < low_water:
		want = low_water
	elif want <= 0:
		return
	var pulled := bridge.take_messages(want)
	if pulled.is_empty():
		return
	ingest(pulled)


func _drain_events() -> void:
	for ev in bridge.poll_events():
		if typeof(ev) != TYPE_DICTIONARY:
			continue
		match String(ev.get("type", "")):
			"consent_required":
				last_consent_info = ev
				consent_required.emit(ev)
			"ready":
				ready_flag = true
				ready.emit(ev)
				changed.emit()
			"error":
				last_error = String(ev.get("message", ev.get("code", "ai error")))
				failed.emit(last_error)
				changed.emit()
			"batch_done":
				_inflight = false
				_last_request_at = elapsed
				if bool(ev.get("ok", false)):
					batches_ok += 1
				else:
					batches_failed += 1
			"phase":
				if String(ev.get("phase", "")) == "ready":
					ready_flag = true


func _refresh_status() -> void:
	status = bridge.status()
	if typeof(status) != TYPE_DICTIONARY:
		status = {}
	capabilities = status.get("capabilities", {})
	var p := String(status.get("phase", "off"))
	if p != phase:
		phase = p
		changed.emit()
	ready_flag = ready_flag or bool(status.get("loaded", false))


func _check_timeout() -> void:
	if not _inflight:
		return
	if elapsed - _inflight_at > GENERATION_TIMEOUT:
		_inflight = false
		bridge.cancel()
		last_error = "the model took too long; using the authored chat"


## Ask for another batch when the queue is getting thin.
func _maybe_request() -> void:
	if not will_ever_serve() or _inflight:
		return
	if _queue.size() >= low_water:
		return
	if elapsed - _last_request_at < BATCH_COOLDOWN:
		return
	if not ready_flag and phase not in ["ready", "generating"]:
		return
	_inflight = true
	_inflight_at = elapsed
	if cast_provider.is_valid():
		cast = cast_provider.call()
	bridge.request_batch({
		"count": _batch_size(),
		"mix": _mix_for(_batch_size()),
		"recent": _recent_context(),
		"cast": cast,
		"banned": banned.keys(),
		"stream": stream_info,
		"tier": _tier_now(),
		"pressure": _pressure_now(),
		"timeoutMs": int(GENERATION_TIMEOUT * 1000.0),
	})


func _batch_size() -> int:
	var runtime := String(status.get("runtime", ""))
	var want := 6 if runtime == "wllama" else 12
	return clampi(want, 4, MAX_QUEUE_DEFAULT)


## Ask the difficulty director for the same category spread the dataset would
## have produced, so AI chat and Classic chat feel the same to play against.
func _mix_for(count: int) -> Dictionary:
	if director == null:
		return {}
	var weights: Dictionary = director.weights(elapsed)
	var total := 0.0
	for k in weights.keys():
		total += float(weights[k])
	if total <= 0.0:
		return {}
	var mix := {}
	var given := 0
	var keys := weights.keys()
	keys.sort()
	for k in keys:
		var share := float(weights[k]) / total * float(count)
		var n := int(floor(share))
		if n > 0:
			mix[String(k)] = n
			given += n
	var i := 0
	while given < count and not keys.is_empty():
		var k = keys[i % keys.size()]
		var cat := String(k)
		if float(weights[cat]) / total > 0.04:
			mix[cat] = int(mix.get(cat, 0)) + 1
			given += 1
		i += 1
		if i > count * 4:
			break
	return mix


func _tier_now() -> int:
	if director == null:
		return 1
	return director.max_tier(elapsed)


func _pressure_now() -> float:
	if director == null:
		return 0.3
	return director.pressure(elapsed)


func _recent_context() -> Array:
	var out: Array = []
	for r in _recent.slice(-8):
		out.append({"username": String(r.get("username", "")), "text": String(r.get("text", ""))})
	return out


# ---------------------------------------------------------------- serving

## True when a message from the model is plausible right now (cheap check).
func will_ever_serve() -> bool:
	return enabled and bridge.bridge_present() and ready_flag


func will_serve() -> bool:
	return will_ever_serve() and not _queue.is_empty()


func is_available() -> bool:
	return bridge.bridge_present()


## Test hook: pretend the browser bridge exists so the whole queue/validation/
## fallback path can be exercised headless, with no JavaScript anywhere.
func set_available_for_tests(value: bool) -> void:
	bridge.force_present = value


## Pull the next AI message, or {} to tell the caller to use the dataset.
func next_message() -> Dictionary:
	if not will_serve():
		return {}
	while not _queue.is_empty():
		var def: Dictionary = _queue.pop_front()
		if banned.has(String(def.get("username", "")).to_lower()):
			dropped += 1
			continue
		served_ai += 1
		_note_recent(def)
		return def
	return {}


func note_classic_served() -> void:
	served_classic += 1


## The sim tells us what just happened, so the next batch can react to it and
## so repeat offenders are recognisable to the model.
func note_spawned(def: Dictionary) -> void:
	_note_recent(def)


func note_banned(username: String) -> void:
	banned[username.to_lower()] = true


func _note_recent(def: Dictionary) -> void:
	_recent.append({"username": String(def.get("username", "")), "text": String(def.get("text", ""))})
	while _recent.size() > 16:
		_recent.pop_front()


## Ingest a batch pulled from the bridge (called by _maybe_request's reply path
## and by tests). Returns how many messages were accepted.
func ingest(raw_batch: Variant) -> int:
	var res := AIContent.validate_batch(raw_batch, catalog, banned, _tier_now(), 1)
	dropped += int(res.get("dropped", 0))
	repaired += int(res.get("repaired", 0))
	var accepted := 0
	for def in (res.get("defs", []) as Array):
		if _queue.size() >= max_queue:
			break
		_queue.append(def)
		accepted += 1
	if accepted > 0:
		changed.emit()
	return accepted


# ------------------------------------------------------------------- setup

func request_download() -> void:
	consented = true
	bridge.configure({"consent": true, "profile": profile, "modelId": model_id})
	bridge.start(true, model_id)
	_refresh_status()


func probe() -> void:
	if not bridge.bridge_present():
		return
	bridge.probe()
	# The first status read may need a moment for the async capability probe.
	capabilities = bridge.capabilities()
	status = bridge.status()
	if typeof(status) == TYPE_DICTIONARY:
		phase = String(status.get("phase", phase))
		ready_flag = ready_flag or bool(status.get("loaded", false))


func unload() -> void:
	bridge.unload()
	ready_flag = false
	_queue.clear()
	_inflight = false


func delete_weights() -> void:
	bridge.delete_cache(model_id)


# --------------------------------------------------------------- reactions

func request_reaction(context: String) -> void:
	if not will_ever_serve():
		return
	bridge.request_reactions({"count": 3, "context": context, "recent": _recent_context(), "stream": stream_info})


func take_reaction() -> Dictionary:
	if _reactions.is_empty():
		var pulled := bridge.take_reactions(3)
		for r in pulled:
			if typeof(r) == TYPE_DICTIONARY and String(r.get("text", "")).length() > 3:
				_reactions.append(r)
	if _reactions.is_empty():
		return {}
	return _reactions.pop_front()


# -------------------------------------------------------------------- info

## How tonight's chat should be labelled. Deliberately conservative: the model
## only gets credit for messages it really wrote, and it only owns the label
## once it carried the majority of them. Anything else says so honestly.
func source_label() -> String:
	if not enabled or served_ai == 0:
		return "CLASSIC"
	if served_classic == 0 or served_ai >= served_classic:
		return "AI"
	return "MIXED"


func state_label() -> String:
	if not bridge.bridge_present():
		return "AI needs a browser"
	match phase:
		"ready", "generating":
			return "AI ready" if ready_flag else "AI warming up"
		"downloading":
			return "Downloading %d%%" % int(float(status.get("progress", 0.0)) * 100.0)
		"loading":
			return "Loading model"
		"consent":
			return "AI ready to download"
		"unsupported":
			return "This device can't run AI chat"
		"error":
			return "AI unavailable"
		_:
			return "AI off"


func detail_line() -> String:
	var model := String(status.get("model", ""))
	var runtime := String(status.get("runtime", ""))
	var toks := float(status.get("stats", {}).get("tokensPerSecond", 0.0))
	if model == "":
		return state_label()
	var bits: Array = [model.replace("-cpu", "").replace("-webgpu", "")]
	if runtime != "":
		bits.append(runtime)
	if toks > 0.0:
		bits.append("%d tok/s" % int(toks))
	bits.append("queue %d" % int(status.get("queue", _queue.size())))
	return " · ".join(bits)


func summary() -> Dictionary:
	return {
		"enabled": enabled,
		"available": bridge.bridge_present(),
		"ready": ready_flag,
		"phase": phase,
		"model": String(status.get("model", "")),
		"runtime": String(status.get("runtime", "")),
		"served_ai": served_ai,
		"served_classic": served_classic,
		"dropped": dropped,
		"repaired": repaired,
		"batches_ok": batches_ok,
		"batches_failed": batches_failed,
		"error": last_error,
	}
