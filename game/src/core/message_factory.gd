class_name MessageFactory
extends RefCounted

## Turns (time, rng, cast history) into the next chat message. Bounded and
## deterministic: combines chat grammar with authored moderation examples,
## keeping the policy metadata intact and banned viewers out of the cast.

const FALLBACK_FROM_REPEAT := ["spam", "insult", "mild_troll", "ad"]
const RECENT_MEMORY := 8

var catalog: MessageCatalog
var bal: Balance
var director: DifficultyDirector

var _ladder := {}          # category -> username we are escalating
var _recent_ids: Array = []
var _thread := ""
var _thread_until := 0.0
var _last_friendly := ""

const MOMENTS := ["that jump scare", "the boss fight", "the scuffed mic", "that clutch", "the loading screen", "the accidental speedrun", "the background music", "that plot twist"]
const CHAT_GRAMMAR := {
	"wholesome": ["{moment} made my night {emote}", "{praise}, needed this stream today {emote}", "chat can we appreciate {thing} {emote}", "{praise}!! {emote}"],
	"friendly": ["{hello} chat {emote}", "{hello}, {activity}", "{activity} and watching {moment} {emote}", "{moment} {emote}"],
	"question": ["chat does anyone know {question}?", "wait {question}?", "{question}? just got here", "@{regular} {question}?"],
	"joke": ["{moment} any% speedrun {emote}", "{moment} was the real final boss {emote}", "my last braincell during {moment} {emote}", "@{regular} we're never living {moment} down {emote}"],
	"criticism": ["{critique}", "{critique}, still enjoying the stream tho", "imo {critique}", "@{regular} yeah {critique}"],
}
const FILLERS := {
	"praise": ["such a comfy stream", "your commentary is so good", "love the energy tonight", "this community is so sweet", "you handled that so well"],
	"thing": ["the cozy vibes", "the soundtrack", "that timing", "the commentary", "this community"],
	"hello": ["yo", "heyy", "evening", "first time here hi", "lurk mode on", "just got home hi"],
	"activity": ["making noodles", "watching from the couch", "avoiding my homework", "drawing along", "folding laundry", "on my lunch break"],
	"question": ["what game this is", "when the next stream is", "if the music has a playlist", "which difficulty this is", "how long we've been live", "if this is a first playthrough"],
	"critique": ["the game audio could be a little lower", "i preferred the last map", "that route seemed slower", "the camera shake is a bit much for me", "the tutorial could explain this better", "i don't think that build works here"],
}
const EMOTES := {
	"wholesome": ["<3", "FeelsGoodMan", "uwu", "<3 <3"],
	"friendly": ["heyhey", "LUL", "ooo", "", ""],
	"question": ["", ""],
	"joke": ["LUL", "KEKW", "ICANT", "pepeLaugh"],
	"criticism": ["", ""],
}


func _init(cat: MessageCatalog, balance: Balance, dirn: DifficultyDirector) -> void:
	catalog = cat
	bal = balance
	director = dirn if dirn != null else DifficultyDirector.new(balance)


func reset() -> void:
	_ladder.clear()
	_recent_ids.clear()
	_thread = ""
	_thread_until = 0.0
	_last_friendly = ""


## Returns {"def": Dictionary, "user": Dictionary} or an empty Dictionary when
## nothing can be spawned this tick (e.g. everyone left is banned).
func request(t: float, rng: SplitMix32, users: Dictionary, banned: Dictionary,
		active_counts: Dictionary) -> Dictionary:
	var weights := director.weights(t)
	var tier := director.max_tier(t)
	var category := String(rng.weighted(weights))

	if category == "repeat_offender":
		if not director.allows_repeat_offenders(t) or not _has_offender(users, banned, active_counts, 2):
			category = String(rng.pick(FALLBACK_FROM_REPEAT))

	# Never ask for a category with no authored content at this difficulty.
	var guard := 0
	while catalog.pool(category, tier).is_empty() and guard < 8:
		var keys: Array = weights.keys()
		if keys.is_empty():
			return {}
		category = String(rng.pick(keys))
		guard += 1
	if catalog.pool(category, tier).is_empty():
		return {}

	var user := pick_user(category, rng, users, banned, active_counts)
	if user.is_empty():
		return {}

	var pool := catalog.pool(category, tier)
	var chosen: Dictionary = _pick_def(pool, rng)
	_remember(chosen)
	var generated := chosen.duplicate(true)
	if CHAT_GRAMMAR.has(category):
		# Nearby posts share a topic and refer to a previous friendly viewer.
		if t >= _thread_until or _thread == "":
			_thread = String(rng.pick(MOMENTS))
			_thread_until = t + rng.range_f(12.0, 24.0)
		var text := String(rng.pick(CHAT_GRAMMAR[category]))
		text = text.replace("{moment}", _thread)
		text = text.replace("{regular}", _last_friendly if _last_friendly != "" else "chat")
		text = text.replace("{emote}", String(rng.pick(EMOTES[category])))
		for token in FILLERS:
			if text.contains("{" + token + "}"):
				text = text.replace("{" + token + "}", String(rng.pick(FILLERS[token])))
		generated["severity"] = 0
		generated["alt_actions"] = []
		generated["text"] = text.strip_edges()
		generated["explanation"] = "Ordinary conversation, reactions and disagreement are welcome. Leave this message in chat."
		_last_friendly = String(user["name"])
	else:
		# Preserve the meaning of nuanced abuse examples; vary delivery only.
		var text := String(chosen["text"])
		if rng.next_float() < 0.6:
			text = text.to_lower()
		if category == "spam" and String(chosen["ideal_action"]) != "allow":
			text = (text + " ").repeat(2 + rng.next_int() % 2).strip_edges().left(240)
		elif rng.next_float() < 0.35:
			text += String(rng.pick(["...", "!!", " lol"]))
		generated["text"] = text
	return {"def": generated, "user": user}


func pick_user(category: String, rng: SplitMix32, users: Dictionary, banned: Dictionary,
		active_counts: Dictionary) -> Dictionary:
	var cands: Array = []
	for u in catalog.users_for(category):
		var uname := String(u["name"])
		if banned.has(uname):
			continue
		if int(active_counts.get(uname, 0)) >= 2:
			continue
		cands.append(u)
	if cands.is_empty():
		return {}

	var escalating := bal.escalates_at(category) or category == "repeat_offender"
	if escalating:
		# Feed one offender back into chat so strike tracking has meaning.
		var ladder_name := String(_ladder.get(category, ""))
		if ladder_name != "" and rng.next_float() < 0.62:
			for c in cands:
				if String(c["name"]) == ladder_name:
					return c
		var picked: Dictionary = cands[rng.next_int() % cands.size()]
		_ladder[category] = String(picked["name"])
		return picked

	# Friendly chat: spread it across the cast so regulars feel like regulars.
	var best: Dictionary = cands[rng.next_int() % cands.size()]
	for _i in 3:
		var try: Dictionary = cands[rng.next_int() % cands.size()]
		var seen_last := float(users.get(String(try["name"]), {}).get("last_seen", -999.0))
		var best_last := float(users.get(String(best["name"]), {}).get("last_seen", -999.0))
		if seen_last < best_last:
			best = try
	return best


func _has_offender(users: Dictionary, banned: Dictionary, active_counts: Dictionary, need: int) -> bool:
	for name in users.keys():
		if banned.has(name):
			continue
		if int(users[name].get("offenses", 0)) < need:
			continue
		if int(active_counts.get(name, 0)) >= 2:
			continue
		for t in _traits_of(name):
			if t in ["spammer", "troll", "hater"]:
				return true
	return false


func _traits_of(username: String) -> Array:
	for u in catalog.users:
		if String(u["name"]) == username:
			return u.get("traits", [])
	return []


func _pick_def(pool: Array, rng: SplitMix32) -> Dictionary:
	var fresh: Array = []
	for d in pool:
		if not _recent_ids.has(String(d["id"])):
			fresh.append(d)
	var source: Array = fresh if not fresh.is_empty() else pool
	return source[rng.next_int() % source.size()]


func _remember(def: Dictionary) -> void:
	_recent_ids.append(String(def["id"]))
	while _recent_ids.size() > RECENT_MEMORY:
		_recent_ids.pop_front()
