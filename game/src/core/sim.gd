class_name Sim
extends RefCounted

## The whole game, minus pixels. Drives time, spawning, expiration, meters and
## scoring. The UI subscribes; it never decides anything itself.

signal spawned(msg: SimMessage)
signal resolved(msg: SimMessage, result: Dictionary)
signal expired(msg: SimMessage, result: Dictionary)
signal purged(msgs: Array)
signal meters(happiness: float, trust: float)
signal speech(text: String, mood: String)
signal phase_changed(index: int, phase: Dictionary)
signal state_changed(next_state: int)
signal trust_gated(trust_needed: float)
signal victory_locked()
signal combo_changed(combo: int)

enum State { READY, RUNNING, PAUSED, WON, LOST, COMPLETE }

const SPEECH_GAP := 2.4
const TRUST_GATE_REPEAT := 22.0

var bal: Balance
var catalog: MessageCatalog
var director: DifficultyDirector
var factory: MessageFactory
var rng: SplitMix32
var viewer_rng: SplitMix32
## Optional browser-LLM chat source. When it has a message ready the chat comes
## from the model; when it does not, the authored dataset fills in and the UI
## says so. The sim never waits on it.
var ai: AIChatManager = null

var mode: String = "story"
var seed_value: int = 0
var title: String = ""
var state: int = State.READY

var elapsed: float = 0.0
var happiness: float = 50.0
var trust: float = 35.0
var score: int = 0
var combo: int = 0
var best_combo: int = 0
var viewer_count: int = 0

var active: Array = []              # Array[SimMessage], oldest first
var users: Dictionary = {}          # username -> record
var banned: Dictionary = {}         # username -> true
var focus_id: int = -1

var session_seconds: float = 240.0
var win_from: float = 192.0
var victory_locked_shown: bool = false
var spawn_timer: float = 0.0
var act_timer: float = 0.0
var next_instance_id: int = 1
var last_phase_index: int = -1
var trust_gate_shown: bool = false
var trust_gate_timer: float = 0.0
var last_speech_at: float = -99.0

var stats: Dictionary = {}

var _flood: int = 0
var _trust_from_allows: float = 0.0
var _expiry_scale: float = 1.0
var _wrong_scale: float = 1.0


func _init(balance: Balance = null, content: MessageCatalog = null) -> void:
	bal = balance if balance != null else Balance.load_default()
	catalog = content if content != null else MessageCatalog.load_default()
	director = DifficultyDirector.new(bal)
	factory = MessageFactory.new(catalog, bal, director)
	rng = SplitMix32.new(1)
	viewer_rng = SplitMix32.new(1)


func configure(new_mode: String, new_seed: int) -> void:
	mode = new_mode if bal.mode_config(new_mode) != {} else "story"
	seed_value = new_seed
	rng = SplitMix32.new(seed_value if seed_value != 0 else 0xC0FFEE)
	viewer_rng = SplitMix32.new(seed_value ^ 0x5EEDBEEF)
	var m := bal.mode_config(mode)
	_expiry_scale = float(m.get("expiry_penalty_scale", 1.0))
	_wrong_scale = float(m.get("wrong_penalty_scale", 1.0))
	session_seconds = float(m.get("session_seconds", bal.get_num("session_seconds", 240.0)))
	var frac := clampf(bal.get_num("win_from_fraction", 0.8), 0.0, 0.999)
	win_from = session_seconds * frac if session_seconds > 0.0 else 0.0
	victory_locked_shown = false
	happiness = bal.get_num("starting_happiness", 50.0)
	trust = bal.get_num("starting_trust", 35.0)
	score = 0
	combo = 0
	best_combo = 0
	elapsed = 0.0
	spawn_timer = 1.2
	act_timer = 0.0
	next_instance_id = 1
	last_phase_index = -1
	trust_gate_shown = false
	trust_gate_timer = 0.0
	last_speech_at = -99.0
	_flood = 0
	_trust_from_allows = 0.0
	active.clear()
	users.clear()
	banned.clear()
	focus_id = -1
	factory.reset()
	title = catalog.random_title(viewer_rng)
	viewer_count = 18 + (seed_value % 23)
	stats = {
		"total": 0, "handled": 0, "correct": 0, "partial": 0, "wrong": 0,
		"expired": 0, "serious_missed": 0, "bans": 0, "deletes": 0, "allows": 0,
		"innocent_bans": 0, "abuses_allowed": 0, "unmoderated": 0,
		"ai": 0, "classic": 0,
	}
	state = State.READY


func start() -> void:
	_set_state(State.RUNNING)
	say(Voice.line(rng, "start"), "happy", true)


func pause() -> void:
	if state == State.RUNNING:
		_set_state(State.PAUSED)


func resume() -> void:
	if state == State.PAUSED:
		_set_state(State.RUNNING)


func is_running() -> bool:
	return state == State.RUNNING


func is_over() -> bool:
	return state in [State.WON, State.LOST, State.COMPLETE]


func _set_state(next: int) -> void:
	if state == next:
		return
	state = next
	state_changed.emit(next)


# ---------------------------------------------------------------- main loop

func tick(dt: float) -> void:
	if state != State.RUNNING or dt <= 0.0:
		return
	dt = minf(dt, 0.25)          # never let a stalled frame eat the run
	elapsed += dt
	act_timer = maxf(0.0, act_timer - dt)
	trust_gate_timer -= dt
	viewer_count = _viewers()

	if ai != null:
		ai.elapsed = elapsed
		ai.tick(dt)

	var idx := director.phase_index(elapsed)
	if idx != last_phase_index:
		last_phase_index = idx
		var p := director.phase_at(elapsed)
		phase_changed.emit(idx, p)
		var key := "phase_" + String(p.get("id", ""))
		if Voice.LINES.has(key):
			say(Voice.line(rng, key), "happy")

	spawn_timer -= dt
	var guard := 0
	while spawn_timer <= 0.0 and guard < 8:
		guard += 1
		if not _try_spawn():
			spawn_timer = 0.5
			break
		spawn_timer += director.interval(rng, elapsed)
		# Occasional burst: chat piling on, which is what makes the queue bite.
		var burst_chance := director.burst(elapsed)
		if burst_chance > 0.0 and active.size() < _cap() and rng.next_float() < burst_chance:
			_try_spawn()
	if spawn_timer < -0.75:
		spawn_timer = -0.75          # stalled by the queue cap, not by luck

	# Independent expiration timers, each resolved exactly once.
	var i := active.size() - 1
	while i >= 0:
		var m: SimMessage = active[i]
		m.remaining -= dt
		if m.remaining <= 0.0:
			active.remove_at(i)
			_expire(m)
		i -= 1

	_check_end()


func _try_spawn() -> bool:
	if active.size() >= _cap():
		return false
	var req := _ai_request()
	var from_ai := not req.is_empty()
	if req.is_empty():
		req = factory.request(elapsed, rng, users, banned, _active_counts())
		if ai != null and not req.is_empty():
			ai.note_classic_served()
	if req.is_empty():
		return false
	var def: Dictionary = req["def"]
	var user: Dictionary = req["user"]
	var uname := String(user["name"])
	if banned.has(uname.to_lower()):
		# The model proposed someone we already threw out. Drop it, silently.
		if from_ai and ai != null:
			ai.note_banned(uname)
		return false
	var rec := _user_rec(uname)
	var category := String(def["category"])
	var prior_category := int((rec["by_cat"] as Dictionary).get(category, 0))
	var prior_total := int(rec["offenses"])
	var prior_posts := int(rec.get("messages", 0))
	var lifetime := clampf(float(def["expiry"]) * director.expiry_scale(elapsed), 4.5, 14.0)
	var m := SimMessage.from_def(def, catalog, user, next_instance_id, elapsed,
			lifetime, prior_category, prior_total, bal)
	m.prior_messages = prior_posts
	m.source = "ai" if from_ai else "classic"
	next_instance_id += 1
	active.append(m)
	rec["messages"] = prior_posts + 1
	if m.is_abuse():
		rec["offenses"] = prior_total + 1
		(rec["by_cat"] as Dictionary)[category] = prior_category + 1
	rec["last_seen"] = elapsed
	stats["total"] = int(stats["total"]) + 1
	if from_ai:
		stats["ai"] = int(stats.get("ai", 0)) + 1
	else:
		stats["classic"] = int(stats.get("classic", 0)) + 1
	if focus_id < 0:
		focus_id = m.instance_id
	spawned.emit(m)
	return true


## Ask the browser model for the next message. Returns {} when it has nothing
## ready, which is normal and is not an error - that is Classic Mode working.
func _ai_request() -> Dictionary:
	if ai == null or not ai.will_serve():
		return {}
	var def: Dictionary = ai.next_message()
	if def.is_empty():
		return {}
	var user := AIContent.user_for(def, catalog)
	return {"def": def, "user": user}


func _expire(m: SimMessage) -> void:
	m.state = "expired"
	m.action = "expire"
	var res := ModerationEngine.expire_verdict(m, bal)
	var d: Vector2 = res["delta"]
	d = Vector2(d.x * _expiry_scale, d.y * _expiry_scale)
	_apply(Vector2(d.x, d.y))
	combo = 0
	combo_changed.emit(combo)
	stats["expired"] = int(stats["expired"]) + 1
	stats["unmoderated"] = int(stats["unmoderated"]) + 1
	if m.is_serious():
		stats["serious_missed"] = int(stats["serious_missed"]) + 1
		say(Voice.line(rng, "serious_expired"), "crying")
	elif String(res["kind"]) == "expire_spam":
		say(Voice.line(rng, "spam_expired"), "upset", 0.4)
	else:
		say(Voice.line(rng, "spam_expired"), "neutral", 0.12)
	expired.emit(m, res)
	_clamp_focus()


func act(action: String) -> Dictionary:
	if state != State.RUNNING:
		return {}
	if act_timer > 0.0:
		return {"blocked": true, "reason": "cooldown"}
	var m := focused()
	if m == null:
		return {"blocked": true, "reason": "empty"}
	var flood := flood_scale()
	var res := ModerationEngine.decide(m, action, bal, combo, flood)
	# The screen shows "was <category> · best <call>" after the decision; the
	# engine stays render-agnostic, so the message rides along here.
	res["message"] = m
	var d: Vector2 = res["delta"]
	if not bool(res["correct"]) and bal.get_int("combo_max", 6) >= 0:
		d = Vector2(d.x * _wrong_scale, d.y * _wrong_scale)
	if String(res["kind"]).begins_with("allow_"):
		var room := maxf(0.0, bal.get_num("trust_positive_cap", 55.0) - _trust_from_allows)
		d.y = minf(d.y, room)
		_trust_from_allows += maxf(0.0, d.y)

	# Trust is the reward for judgment; happiness is the reward for outcomes.
	if bool(res["exact"]):
		combo += 1
		best_combo = maxi(best_combo, combo)
		_flood += 1 if m.is_harmless() and action == "allow" else 0
		if not (m.is_harmless() and action == "allow"):
			_flood = 0
		score += int(res["points"])
		var bonus := bal.get_int("combo_points", 30)
		if combo >= 2:
			score += bonus * mini(combo, bal.get_int("combo_max", 6))
	elif bool(res["partial"]):
		score += int(res["points"])
		_flood = 0
	else:
		combo = 0
		_flood = 0

	_apply(d)

	m.state = {"allow": "allowed", "delete": "deleted", "ban": "banned"}.get(action, "allowed")
	m.action = action
	active.erase(m)
	stats["handled"] = int(stats["handled"]) + 1
	if bool(res["correct"]):
		stats["correct"] = int(stats["correct"]) + (1 if bool(res["exact"]) else 0)
		stats["partial"] = int(stats["partial"]) + (1 if bool(res["partial"]) else 0)
	else:
		stats["wrong"] = int(stats["wrong"]) + 1
	match action:
		"allow":
			stats["allows"] = int(stats["allows"]) + 1
			if m.is_abuse() and not bool(res["correct"]):
				stats["abuses_allowed"] = int(stats["abuses_allowed"]) + 1
		"delete":
			stats["deletes"] = int(stats["deletes"]) + 1
		"ban":
			stats["bans"] = int(stats["bans"]) + 1
			ban_user(m.username)
			if m.is_harmless():
				stats["innocent_bans"] = int(stats["innocent_bans"]) + 1
	_focus_next_oldest()
	combo_changed.emit(combo)
	_react(m, res)
	resolved.emit(m, res)
	act_timer = bal.get_num("act_cooldown", 0.14)
	_check_end()
	return res


## Attach (or detach with null) the browser-LLM chat source. The sim calls it
## for a message and, when it has nothing ready, uses the authored dataset.
func set_ai(manager: AIChatManager) -> void:
	ai = manager
	if ai != null:
		# The model gets the recurring cast - who has been posting and who has
		# strikes - so its batches can bring repeat offenders back instead of
		# inventing a fresh stranger every second.
		ai.cast_provider = _ai_cast


## Who the model should remember when it writes the next batch.
func _ai_cast() -> Array:
	if ai == null:
		return []
	var out: Array = []
	for username in users.keys():
		var rec: Dictionary = users[username]
		var posts := int(rec.get("messages", 0))
		var offenses := int(rec.get("offenses", 0))
		if posts <= 0:
			continue
		out.append({
			"username": String(username),
			"posts": posts,
			"offenses": offenses,
			"last_seen": float(rec.get("last_seen", 0.0)),
		})
		if out.size() >= 14:
			break
	return out


func ban_user(username: String) -> void:
	if banned.has(username):
		return
	banned[username] = true
	if ai != null:
		ai.note_banned(username)
	var gone: Array = []
	for m in active:
		if m.username == username:
			m.state = "purged"
			gone.append(m)
	for m in gone:
		active.erase(m)
	if not gone.is_empty():
		purged.emit(gone)
	_clamp_focus()


func act_on(instance_id: int, action: String) -> Dictionary:
	if focused() != null and focused().instance_id == instance_id:
		return act(action)
	if focus_message(instance_id):
		return act(action)
	return {}


# ------------------------------------------------------------------- focus

func focused() -> SimMessage:
	for m in active:
		if m.instance_id == focus_id:
			return m
	return active[0] if not active.is_empty() else null


func focus_message(instance_id: int) -> bool:
	for m in active:
		if m.instance_id == instance_id:
			focus_id = instance_id
			return true
	return false


func focus_next() -> void:
	if active.is_empty():
		focus_id = -1
		return
	var pos := _index_of_focus()
	focus_id = active[(pos + 1) % active.size()].instance_id


func _focus_next_oldest() -> void:
	focus_id = active[0].instance_id if not active.is_empty() else -1


func _index_of_focus() -> int:
	for i in active.size():
		if active[i].instance_id == focus_id:
			return i
	return 0


func _clamp_focus() -> void:
	if active.is_empty():
		focus_id = -1
		return
	if focused() == null:
		focus_id = active[0].instance_id


# ------------------------------------------------------------------ helpers

func _apply(delta: Vector2) -> void:
	# Progress is deliberately harder the closer she already is to beaming:
	# good calls still matter, but a 100%% night cannot be run out early by
	# grinding friendly messages. Penalties are never discounted.
	var dx := delta.x
	var dy := delta.y
	if dx > 0.0:
		dx *= _falloff(happiness, "heal_strength", "heal_exponent", "heal_floor")
	if dy > 0.0:
		dy *= _falloff(trust, "trust_heal_strength", "trust_heal_exponent", "trust_heal_floor")
	happiness = clampf(happiness + dx, 0.0, 100.0)
	trust = clampf(trust + dy, 0.0, 100.0)
	meters.emit(happiness, trust)


## 1.0 when the meter is low, dropping towards `floor` as it approaches 100.
func _falloff(value: float, strength_key: String, exponent_key: String,
		floor_key: String) -> float:
	var strength := bal.get_num(strength_key, 0.85)
	var exponent := bal.get_num(exponent_key, 2.5)
	var floor_v := bal.get_num(floor_key, 0.12)
	var t := clampf(value / 100.0, 0.0, 1.0)
	return clampf(1.0 - strength * pow(t, exponent), floor_v, 1.0)


func _cap() -> int:
	return mini(bal.get_int("queue_limit", 24), director.max_active(elapsed))


func _active_counts() -> Dictionary:
	var counts := {}
	for m in active:
		counts[m.username] = int(counts.get(m.username, 0)) + 1
	return counts


## Where tonight's chat actually came from. The results screen and the header
## chip read this, and it can only ever say "ai" for messages the model wrote.
func chat_source() -> String:
	if ai == null:
		return "classic"
	return ai.source_label().to_lower()


## How much of the chat the model carried, for the results screen.
func chat_mix() -> Dictionary:
	return {
		"ai": int(stats.get("ai", 0)),
		"classic": int(stats.get("classic", 0)),
		"source": chat_source(),
	}


func _user_rec(username: String) -> Dictionary:
	if not users.has(username):
		users[username] = {"offenses": 0, "by_cat": {}, "last_seen": -999.0, "messages": 0}
	return users[username]


func flood_scale() -> float:
	var decay := bal.get_num("positive_flood_decay", 0.14)
	var floor_v := bal.get_num("positive_flood_floor", 0.2)
	return clampf(1.0 - decay * float(maxi(0, _flood - 2)), floor_v, 1.0)


func _viewers() -> int:
	var base := 18.0 + float(last_phase_index + 1) * 46.0 + director.pressure(elapsed) * 210.0
	var drift := float(viewer_rng.next_int() % 17) - 8.0
	var mood := (happiness - 50.0) * 0.9
	return maxi(1, int(base + drift + mood))


func say(text: String, mood: String, force: bool = false, prob: float = 0.55) -> void:
	if not force and elapsed - last_speech_at < SPEECH_GAP:
		return
	if not force and rng.next_float() > prob:
		return
	var final_text := text
	var final_mood := mood
	# When the model is awake it may write the streamer's line instead, which is
	# what makes the VTuber feel like she is reading the same chat you are.
	if ai != null and ai.enabled and rng.next_float() < 0.4:
		var reaction := ai.take_reaction()
		if not reaction.is_empty():
			final_text = String(reaction.get("text", "")).strip_edges()
			final_mood = String(reaction.get("mood", mood))
	if final_text.length() < 3 or final_text.length() > 160:
		return
	last_speech_at = elapsed
	speech.emit(final_text, final_mood)


func _react(m: SimMessage, res: Dictionary) -> void:
	var kind := String(res["kind"])
	match kind:
		"allow_wholesome":
			say(Voice.line(rng, "allow_wholesome"), "happy")
		"allow_neutral":
			say(Voice.line(rng, "allow_friendly"), "neutral", false, 0.3)
		"delete_minor", "delete_major":
			say(Voice.line(rng, "delete"), "happy", false, 0.5)
		"ban_major", "ban_minor":
			say(Voice.line(rng, "ban"), "happy", false, 0.7)
		"ban_innocent", "delete_harmless":
			say(Voice.line(rng, "innocent_banned" if kind == "ban_innocent" else "harmless_deleted"),
					"upset" if kind == "ban_innocent" else "confused", true)
		"allow_hostile", "allow_minor_abuse":
			say(Voice.line(rng, "abuse_allowed"), "upset", true)
		"ban_over_delete":
			say(Voice.line(rng, "too_harsh"), "confused", false, 0.6)
		"delete_over_ban", "let_slip_mild":
			say(Voice.line(rng, "too_soft"), "confused", false, 0.5)
	if combo > 0 and combo % 5 == 0:
		say(Voice.line(rng, "combo"), "excited", true)
	if trust >= bal.get_num("trust_to_win", 78.0) and combo >= 8:
		say(Voice.line(rng, "high_trust"), "happy", false, 0.4)


func _check_end() -> void:
	if is_over():
		return
	if happiness <= 0.0:
		say(Voice.line(rng, "lose"), "crying", true)
		_set_state(State.LOST)
		return
	var ready := happiness >= 100.0 and trust >= bal.get_num("trust_to_win", 78.0)
	if ready and elapsed >= win_from:
		say(Voice.line(rng, "win"), "excited", true)
		_set_state(State.WON)
		return
	if ready and elapsed < win_from:
		# She's beaming, but the night isn't over: hold the line to the end.
		if not victory_locked_shown or trust_gate_timer <= 0.0:
			victory_locked_shown = true
			trust_gate_timer = TRUST_GATE_REPEAT
			victory_locked.emit()
			say(Voice.line(rng, "near_win"), "excited", true)
	if happiness >= 100.0 and trust < bal.get_num("trust_to_win", 78.0):
		if not trust_gate_shown or trust_gate_timer <= 0.0:
			trust_gate_shown = true
			trust_gate_timer = TRUST_GATE_REPEAT
			trust_gated.emit(bal.get_num("trust_to_win", 78.0))
		say(Voice.line(rng, "trust_gate"), "embarrassed", true)
	if session_seconds > 0.0 and elapsed >= session_seconds:
		if ready and elapsed >= win_from:
			say(Voice.line(rng, "win"), "excited", true)
			_set_state(State.WON)
		else:
			_set_state(State.COMPLETE)


func accuracy() -> float:
	var handled := int(stats["handled"]) + int(stats["expired"])
	if handled <= 0:
		return 0.0
	return float(int(stats["correct"]) + int(stats["partial"])) / float(handled)


func summary() -> Dictionary:
	var outcome := ""
	match state:
		State.WON:
			outcome = "win"
		State.LOST:
			outcome = "lose"
		State.COMPLETE:
			outcome = "complete"
		_:
			outcome = "aborted"
	return {
		"outcome": outcome,
		"mode": mode,
		"seed": seed_value,
		"score": score,
		"happiness": happiness,
		"trust": trust,
		"accuracy": accuracy(),
		"correct": int(stats["correct"]),
		"partial": int(stats["partial"]),
		"wrong": int(stats["wrong"]),
		"expired": int(stats["expired"]),
		"serious_missed": int(stats["serious_missed"]),
		"bans": int(stats["bans"]),
		"deletes": int(stats["deletes"]),
		"allows": int(stats["allows"]),
		"innocent_bans": int(stats["innocent_bans"]),
		"abuses_allowed": int(stats["abuses_allowed"]),
		"best_combo": best_combo,
		"total_messages": int(stats["total"]),
		"ai_messages": int(stats.get("ai", 0)),
		"classic_messages": int(stats.get("classic", 0)),
		"chat_source": chat_source(),
		"time": elapsed,
		"title": title,
		"trust_needed": bal.get_num("trust_to_win", 78.0),
		"win_from": win_from,
	}
