class_name MessageFactory
extends RefCounted

## Turns (time, rng, cast history) into the next chat message. Bounded and
## deterministic: it never invents content, only selects from the dataset, and
## it will not hand a microphone to someone who has been banned.

const FALLBACK_FROM_REPEAT := ["spam", "insult", "mild_troll", "ad"]
const RECENT_MEMORY := 8

var catalog: MessageCatalog
var bal: Balance
var director: DifficultyDirector

var _ladder := {}          # category -> username we are escalating
var _recent_ids: Array = []


func _init(cat: MessageCatalog, balance: Balance, dirn: DifficultyDirector) -> void:
	catalog = cat
	bal = balance
	director = dirn if dirn != null else DifficultyDirector.new(balance)


func reset() -> void:
	_ladder.clear()
	_recent_ids.clear()


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
	return {"def": chosen, "user": user}


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
