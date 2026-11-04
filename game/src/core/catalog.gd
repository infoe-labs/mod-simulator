class_name MessageCatalog
extends RefCounted

## Loads and indexes res://data/messages.json exactly once. Nothing in the
## game parses JSON at runtime after this call — the sim only touches
## pre-indexed arrays.

const PATH := "res://data/messages.json"

const GROUP_POSITIVE := "positive"
const GROUP_NEUTRAL := "neutral"
const GROUP_MINOR := "minor"
const GROUP_MAJOR := "major"

## Which user personalities are allowed to author which category. Keeps the
## cast coherent: the nice regulars stay nice, the trolls keep trolling, and
## repeat-offender tracking means something.
const TRAIT_FOR_CATEGORY := {
	"wholesome": ["sweet", "regular", "newcomer"],
	"friendly": ["regular", "newcomer", "sweet", "joker"],
	"question": ["newcomer", "regular", "nosy"],
	"joke": ["joker", "regular"],
	"criticism": ["regular", "newcomer", "joker"],
	"mild_troll": ["joker", "troll", "regular"],
	"spam": ["spammer"],
	"ad": ["scammer", "spammer"],
	"spoiler": ["spoiler", "joker"],
	"insult": ["hater", "troll"],
	"harassment": ["hater", "troll"],
	"attack": ["hater"],
	"invasive": ["nosy", "newcomer", "hater"],
	"repeat_offender": ["spammer", "troll", "hater"],
}

const REQUIRED_FIELDS := [
	"id", "text", "category", "severity", "ideal_action",
	"alt_actions", "tier", "damage", "expiry", "escalates", "explanation",
]

var balance: Balance
var meta: Dictionary = {}
var categories: Dictionary = {}
var users: Array = []
var titles: Array = []
var messages: Array = []

var _by_category: Dictionary = {}
var _by_trait: Dictionary = {}
var _loaded := false


static func load_default() -> MessageCatalog:
	return load_path(PATH)


static func load_path(path: String) -> MessageCatalog:
	var c := MessageCatalog.new()
	c._load(path)
	return c


func _load(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_error("Content file missing: %s" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Content unreadable: %s" % path)
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Content is not valid JSON: %s" % path)
		return
	var doc: Dictionary = parsed
	meta = doc.get("meta", {})
	categories = doc.get("categories", {})
	titles = doc.get("titles", [])
	users = []
	for u in doc.get("users", []):
		if typeof(u) == TYPE_DICTIONARY and u.has("name"):
			users.append({
				"name": String(u.get("name", "viewer")),
				"color": String(u.get("color", "#cfd8e3")),
				"badge": String(u.get("badge", "none")),
				"traits": (u.get("traits", ["regular"]) as Array).duplicate(),
			})
	messages = []
	for m in doc.get("messages", []):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var missing := false
		for k in REQUIRED_FIELDS:
			if not m.has(k):
				missing = true
				break
		if missing:
			push_warning("Skipping message with missing fields: %s" % str(m.get("id", "?")))
			continue
		messages.append({
			"id": String(m["id"]),
			"text": String(m["text"]),
			"category": String(m["category"]),
			"group": String(m.get("group", "")),
			"severity": int(m["severity"]),
			"ideal_action": String(m["ideal_action"]),
			"alt_actions": (m["alt_actions"] as Array).duplicate(),
			"tier": int(m["tier"]),
			"damage": float(m["damage"]),
			"expiry": float(m["expiry"]),
			"escalates": bool(m["escalates"]),
			"explanation": String(m["explanation"]),
		})
	_index()
	_loaded = true


func _index() -> void:
	_by_category.clear()
	for cat in categories.keys():
		_by_category[cat] = []
	for m in messages:
		var cat: String = m["category"]
		if not _by_category.has(cat):
			_by_category[cat] = []
		_by_category[cat].append(m)
	_by_trait.clear()
	for u in users:
		for t in (u["traits"] as Array):
			var key := String(t)
			if not _by_trait.has(key):
				_by_trait[key] = []
			_by_trait[key].append(u)


## Convenience for the UI: whether a category can escalate to a ban.
func escalates_at(category: String) -> bool:
	if balance == null:
		balance = Balance.load_default()
	return balance.escalates_at(category)


func strikes_to_ban(category: String) -> int:
	if balance == null:
		balance = Balance.load_default()
	return balance.strikes_to_ban(category)


func is_loaded() -> bool:
	return _loaded and not messages.is_empty()


func count() -> int:
	return messages.size()


func category_ids() -> Array:
	return categories.keys()


func label(category: String) -> String:
	return String(categories.get(category, {}).get("label", category))


func short(category: String) -> String:
	return String(categories.get(category, {}).get("short", "?"))


func group_of(category: String) -> String:
	return String(categories.get(category, {}).get("group", GROUP_NEUTRAL))


func group_for(def: Dictionary) -> String:
	## A message may declare its own group (an ambiguous one-off inside an
	## otherwise-rough category). The category group is the default.
	var g := String(def.get("group", ""))
	if g in [GROUP_POSITIVE, GROUP_NEUTRAL, GROUP_MINOR, GROUP_MAJOR]:
		return g
	return group_of(String(def.get("category", "")))


static func group_of_doc(cats: Dictionary, row: Dictionary) -> String:
	var g := String(row.get("group", ""))
	if g in [GROUP_POSITIVE, GROUP_NEUTRAL, GROUP_MINOR, GROUP_MAJOR]:
		return g
	return String(cats.get(String(row.get("category", "")), {}).get("group", GROUP_NEUTRAL))


func is_positive_group(category: String) -> bool:
	return group_of(category) == GROUP_POSITIVE


func is_harmless(category: String) -> bool:
	return group_of(category) in [GROUP_POSITIVE, GROUP_NEUTRAL]


func pool(category: String, max_tier: int = 3) -> Array:
	var out: Array = []
	for m in _by_category.get(category, []):
		if int(m["tier"]) <= max_tier:
			out.append(m)
	if out.is_empty():
		out = _by_category.get(category, [])
	return out


func users_for(category: String) -> Array:
	var out: Array = []
	for t in TRAIT_FOR_CATEGORY.get(category, ["regular"]):
		for u in _by_trait.get(String(t), []):
			if not out.has(u):
				out.append(u)
	if out.is_empty():
		out = users.duplicate()
	return out


func random_title(rng: SplitMix32) -> String:
	if titles.is_empty():
		return "cozy stream ♡"
	return String(rng.pick(titles))


## ---- static validation, shared by the test suite ----

static func validate(doc: Dictionary) -> Array:
	var problems: Array = []
	var cats: Dictionary = doc.get("categories", {})
	var msgs: Array = doc.get("messages", [])
	var usrs: Array = doc.get("users", [])
	if msgs.size() < 150:
		problems.append("need >= 150 authored messages, found %d" % msgs.size())
	if cats.size() < 14:
		problems.append("need >= 14 categories, found %d" % cats.size())
	if usrs.size() < 24:
		problems.append("need >= 24 usernames, found %d" % usrs.size())
	var seen_ids := {}
	for m in msgs:
		var mid := String(m.get("id", "<no id>"))
		if seen_ids.has(mid):
			problems.append("duplicate message id %s" % mid)
		seen_ids[mid] = true
		for f in REQUIRED_FIELDS:
			if not m.has(f):
				problems.append("%s missing field '%s'" % [mid, f])
		var cat := String(m.get("category", ""))
		if not cats.has(cat):
			problems.append("%s has unknown category '%s'" % [mid, cat])
		var ideal := String(m.get("ideal_action", ""))
		if ideal not in ["allow", "delete", "ban"]:
			problems.append("%s has invalid ideal_action '%s'" % [mid, ideal])
		var alts: Variant = m.get("alt_actions", [])
		if typeof(alts) != TYPE_ARRAY:
			problems.append("%s alt_actions must be an array" % mid)
		else:
			for a in alts:
				if String(a) not in ["allow", "delete", "ban"]:
					problems.append("%s has invalid alt_action '%s'" % [mid, str(a)])
				if String(a) == ideal:
					problems.append("%s lists its ideal action as an alternative" % mid)
		var sev := int(m.get("severity", -1))
		if sev < 0 or sev > 4:
			problems.append("%s severity out of range: %d" % [mid, sev])
		var tier := int(m.get("tier", -1))
		if tier < 1 or tier > 3:
			problems.append("%s tier out of range: %d" % [mid, tier])
		if float(m.get("expiry", 0.0)) < 5.0 or float(m.get("expiry", 0.0)) > 15.0:
			problems.append("%s expiry outside 5..15s: %s" % [mid, str(m.get("expiry"))])
		if String(m.get("text", "")).strip_edges().is_empty():
			problems.append("%s has empty text" % mid)
		if String(m.get("explanation", "")).strip_edges().is_empty():
			problems.append("%s has no explanation" % mid)
		# The group must be able to produce a sane scoring outcome.
		var grp := group_of_doc(cats, m)
		if grp not in [GROUP_POSITIVE, GROUP_NEUTRAL, GROUP_MINOR, GROUP_MAJOR]:
			problems.append("%s category '%s' has unknown group '%s'" % [mid, cat, grp])
		if grp in [GROUP_POSITIVE, GROUP_NEUTRAL] and ideal != "allow":
			problems.append("%s is harmless but ideal action is '%s'" % [mid, ideal])
		if grp in [GROUP_MINOR, GROUP_MAJOR] and ideal == "allow":
			problems.append("%s is abusive but ideal action is 'allow'" % mid)
	# Trait coverage: every category must have authors available.
	var trait_users := {}
	for u in usrs:
		for t in u.get("traits", []):
			var key := String(t)
			if not trait_users.has(key):
				trait_users[key] = 0
			trait_users[key] += 1
	for cat in cats.keys():
		var traits: Array = TRAIT_FOR_CATEGORY.get(cat, [])
		if traits.is_empty():
			problems.append("category '%s' has no trait mapping" % cat)
			continue
		var total := 0
		for t in traits:
			total += int(trait_users.get(String(t), 0))
		if total < 3:
			problems.append("category '%s' has too few candidate authors (%d)" % [cat, total])
	return problems
