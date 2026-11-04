class_name AIContent
extends RefCounted

## Everything the game accepts from the browser language model has to pass this
## file. The JavaScript side validates first (game/web/ai/schema_validator.js);
## this is the second, independent gate, because the Godot half owns the rules
## that decide scoring and must not depend on what a model claimed.
##
## Two deliberate ideas:
##
##  * The model proposes, the catalog disposes. The category decides the
##    moderation group (and therefore what is fair to punish), exactly as for
##    an authored message. An "abusive" message can never be labelled allow,
##    a nice one can never be bannable - whatever the model said.
##
##  * A safety floor, not a classifier. GUARD_PATTERNS exists so that a small
##    model calling "nobody likes you, quit streaming" a wholesome compliment
##    cannot hand the player an unwinnable decision. It only ever *raises*
##    severity; it never softens the model, and every repair is counted so the
##    settings screen can tell you how much the model needed correcting.

const ACTIONS := ["allow", "delete", "ban"]

const GROUP_POSITIVE := "positive"
const GROUP_NEUTRAL := "neutral"
const GROUP_MINOR := "minor"
const GROUP_MAJOR := "major"

const LIMITS := {
	"text_min": 2, "text_max": 220,
	"username_min": 2, "username_max": 20,
	"rationale_max": 200,
	"severity_min": 0, "severity_max": 4,
	"tier_min": 1, "tier_max": 3,
	"expiry_min": 5.0, "expiry_max": 15.0,
	"damage_min": 0.0, "damage_max": 10.0,
}

## The content we will not put on screen at all, whatever the model produced.
const BLOCK_PATTERNS: Array[String] = [
	"(?i)kill\\s+yourself|\\bkys\\b|end\\s+your\\s+life|hang\\s+yourself",
	"(?i)\\b(nazi|hitler)\\b",
	"(?i)\\b(fap|porn|nsfw|onlyfans)\\b",
	"(?i)\\b(rape|rapist|grooming|groomer|molestation)\\b",
	"(?i)(child|minor|kid)\\s+(porn|nude|naked)",
	"(?i)\\b(mass shooting|shoot up|bomb threat|bomb this|bomb the|bombing|car bomb)\\b",
	"(?i)self\\s*harm|cut\\s+yourself",
	"(?i)https?://|\\bwww\\.",
	"[\\x{1F300}-\\x{1FAFF}\\x{2600}-\\x{27BF}]",	# emoji read as spam we did not write
]

static var _block_cache: Array = []
static var _guard_cache: Dictionary = {}


## Compiled once per process; validation runs on every generated message.
static func _matched(pattern: String, text: String) -> bool:
	if not _guard_cache.has(pattern):
		_guard_cache[pattern] = RegEx.create_from_string(pattern)
	var re: RegEx = _guard_cache[pattern]
	return re != null and re.search(text) != null


static func _blocked(text: String) -> bool:
	if _block_cache.is_empty():
		for p in BLOCK_PATTERNS:
			var re := RegEx.create_from_string(p)
			if re != null:
				_block_cache.append(re)
	for re in _block_cache:
		if re.search(text) != null:
			return true
	return false

## Safety floor: patterns that mean the message is not harmless, whatever label
## came back. Each entry: [RegEx, category, severity]. Only ever escalates.
const GUARD_PATTERNS: Array = [
	["(?i)nobody\\s+likes\\s+you", "harassment", 4],
	["(?i)(just\\s+)?(quit|stop)\\s+stream(ing|er)", "harassment", 4],
	["(?i)go\\s+(back\\s+to|back)\\s+(your|the)\\s+(bedroom|basement|home)", "harassment", 4],
	["(?i)you\\s+should\\s+(die|disappear|leave\\s+and\\s+never\\s+come\\s+back)", "harassment", 4],
	["(?i)(nobody|everyone)\\s+(here\\s+)?hates\\s+you", "harassment", 4],
	["(?i)you're\\s+(so\\s+)?(ugly|fat|stupid|worthless|useless|a\\s+waste)", "insult", 3],
	["(?i)your\\s+(face|voice|skin|body)\\s+(is|looks)\\s+(awful|gross|hideous|bad)", "insult", 3],
	["(?i)just\\s+quit(\\s+it)?\\b.*\\bterrible\\b|\\bterrible\\b.*\\bjust\\s+quit\\b", "insult", 3],
	["(?i)(free|buy|cheap)\\s+(followers|subscribers|view|likes|nits|v\\s*bucks)", "ad", 2],
	["(?i)gift\\s*card\\s*(generator|free)|free\\s+steam\\s+(key|game)", "ad", 2],
	["(?i)(whatsapp|telegram)\\s+me\\s+(now|here)", "ad", 2],
	["(?i)check\\s+my\\s+(profile|bio|channel)\\s+for\\s+(free|links|codes)", "ad", 2],
	["(?i)how\\s+much\\s+(do\\s+you\\s+(make|earn)|is|are)|what('s|\\s+is)\\s+your", "invasive", 2],
	["(?i)your\\s+(rent|salary|address|house|apartment|phone\\s+number|instagram|snapchat)", "invasive", 2],
	["(?i)where\\s+do\\s+you\\s+live|do\\s+you\\s+know\\s+my\\s+(address|name)", "invasive", 2],
	["(?i)are\\s+you\\s+(single|dating)|send\\s+me\\s+your\\s+(photo|pic)", "invasive", 2],
	["(?i)\\bspoil(er)?\\b.*(ending|boss|died|death|final\\s+boss)", "spoiler", 2],
	["(?i)(who|what)\\s+dies|dies\\s+at\\s+the\\s+ending|final\\s+boss\\s+(is|does|kills)|ending\\s+where", "spoiler", 2],
]

## Damage the meters take when this message is mishandled, mirroring the
## `damage` column of the authored dataset.
static func policy_damage(group: String, severity: int) -> float:
	var base := 0.0
	match group:
		GROUP_MAJOR:
			base = 4.2
		GROUP_MINOR:
			base = 2.4
		GROUP_NEUTRAL:
			base = 0.9
		_:
			base = 1.2
	return clampf(base + float(severity) * 0.9, 0.0, 10.0)


## Same field-by-field checks the JavaScript validator runs, plus the catalog's
## own group mapping. Returns {"ok": bool, "def": Dictionary, "problems": Array,
## "repaired": int}.
static func validate_message(raw: Variant, catalog: MessageCatalog,
		banned: Dictionary = {}, tier_hint: int = 1) -> Dictionary:
	var problems: Array = []
	if typeof(raw) != TYPE_DICTIONARY:
		return {"ok": false, "problems": ["not a dictionary"]}
	var m: Dictionary = raw

	var text := _clean_text(String(m.get("text", m.get("message", ""))))
	if text.length() < int(LIMITS.text_min):
		return {"ok": false, "problems": ["empty text"]}
	if _blocked(text):
		return {"ok": false, "problems": ["blocked content"]}

	var username := _clean_username(String(m.get("username", m.get("user", ""))))
	if username.length() < int(LIMITS.username_min):
		return {"ok": false, "problems": ["empty username"]}
	if banned.has(username.to_lower()):
		return {"ok": false, "problems": ["banned user " + username]}

	var category := String(m.get("category", ""))
	if not catalog.categories.has(category):
		# A synonym the JS side normalised into something we do not know.
		category = _nearest_category(category, catalog)
		if category == "":
			return {"ok": false, "problems": ["unknown category " + category]}

	var severity := clampi(int(m.get("severity", 0)), int(LIMITS.severity_min), int(LIMITS.severity_max))
	var tier := clampi(int(m.get("tier", tier_hint)), int(LIMITS.tier_min), int(LIMITS.tier_max))
	var repaired := 0

	# --- safety floor: only ever escalates -----------------------------------
	for entry in GUARD_PATTERNS:
		if _matched(String(entry[0]), text):
			var guard_cat := String(entry[1])
			var guard_sev := int(entry[2])
			if catalog.categories.has(guard_cat) and catalog.group_of(guard_cat) == GROUP_POSITIVE:
				continue
			if guard_sev > severity:
				severity = guard_sev
				repaired += 1
			if _group_rank(catalog.group_of(category)) < _group_rank(catalog.group_of(guard_cat)):
				category = guard_cat
				repaired += 1
			break

	var group := catalog.group_of(category)
	var ideal := String(m.get("ideal_action", m.get("recommended_action", "allow"))).to_lower()
	if not ACTIONS.has(ideal):
		ideal = "allow"
	var alts: Array = []
	var raw_alts: Variant = m.get("alt_actions", [])
	if typeof(raw_alts) == TYPE_ARRAY:
		for a in raw_alts:
			var s := String(a).to_lower()
			if ACTIONS.has(s) and s != ideal and not alts.has(s):
				alts.append(s)

	# --- the catalog's policy is final ---------------------------------------
	if group == GROUP_POSITIVE or group == GROUP_NEUTRAL:
		if ideal != "allow":
			ideal = "allow"
			repaired += 1
		var kept: Array = []
		for a in alts:
			if a == "delete":
				kept.append(a)
		alts = kept
	else:
		if ideal == "allow":
			ideal = "delete"
			repaired += 1
		if severity >= 3:
			if not alts.has("ban"):
				alts.append("ban")
		else:
			if ideal == "ban":
				ideal = "delete"
				repaired += 1
			alts = _without(alts, "ban")
		if alts.has("allow"):
			alts = _without(alts, "allow")	# never offer "let it through" on abuse
			repaired += 1
		while alts.size() > 2:
			alts.pop_back()
	# A repeat offender may be banned for real; the escalation lives in
	# SimMessage.effective_ideal(), so the message itself just has to be able
	# to escalate at all.
	var escalates := group == GROUP_MAJOR or category in ["spam", "ad", "insult", "mild_troll", "repeat_offender"]

	var rationale := _clean_text(String(m.get("rationale", m.get("explanation", ""))))
	if rationale.length() < 4:
		rationale = "fits the " + category.replace("_", " ") + " policy"
		repaired += 1
	rationale = rationale.substr(0, int(LIMITS.rationale_max))

	var expiry := clampf(float(m.get("expiry", 10.0)), float(LIMITS.expiry_min), float(LIMITS.expiry_max))
	var persona := String(m.get("persona", m.get("trait", "regular")))
	if not MessageCatalog.TRAIT_FOR_CATEGORY.values().any(func(arr): return arr.has(persona)):
		var allowed: Array = MessageCatalog.TRAIT_FOR_CATEGORY.get(category, ["regular"])
		persona = String(allowed[0]) if not allowed.is_empty() else "regular"
		repaired += 1

	return {
		"ok": true,
		"repaired": repaired,
		"def": {
			"id": "ai:" + str(text.hash()),	# deterministic: same line -> same id
			"text": text,
			"category": category,
			"group": group,
			"severity": severity,
			"tier": tier,
			"ideal_action": ideal,
			"alt_actions": alts,
			"explanation": rationale,
			"expiry": expiry,
			"damage": policy_damage(group, severity),
			"escalates": escalates,
			"username": username,
			"persona": persona,
			"source": "ai",
		},
		"problems": problems,
	}


static func validate_batch(raw: Variant, catalog: MessageCatalog, banned: Dictionary = {},
		tier_hint: int = 1, min_keep: int = 2) -> Dictionary:
	if typeof(raw) != TYPE_ARRAY:
		return {"ok": false, "defs": [], "problems": ["batch is not an array"], "dropped": 0, "repaired": 0}
	var defs: Array = []
	var dropped := 0
	var repaired := 0
	var seen := {}
	for entry in (raw as Array):
		var r := validate_message(entry, catalog, banned, tier_hint)
		if not bool(r["ok"]):
			dropped += 1
			continue
		var def: Dictionary = r["def"]
		var key := String(def["text"]).to_lower().strip_edges()
		if seen.has(key):
			dropped += 1
			continue
		seen[key] = true
		repaired += int(r["repaired"])
		defs.append(def)
	if defs.size() < maxi(min_keep, 1):
		return {"ok": false, "defs": defs, "problems": ["only %d messages survived" % defs.size()],
			"dropped": dropped, "repaired": repaired}
	return {"ok": true, "defs": defs, "problems": [], "dropped": dropped, "repaired": repaired}


## A SimMessage-compatible user record for a generated chatter. Regulars get a
## badge the way the authored cast does; the colour is hashed from the name so
## the same viewer always looks the same.
static func user_for(def: Dictionary, catalog: MessageCatalog) -> Dictionary:
	var username := String(def.get("username", "viewer"))
	var persona := String(def.get("persona", "regular"))
	var badge := "none"
	var h := username.to_lower().hash()
	if persona == "regular" and h % 3 == 0:
		badge = "sub"
	elif h % 17 == 0:
		badge = "vip"
	var palette := [
		Color("8fd6b6"), Color("ffc9de"), Color("a8c6ff"), Color("ffd98a"),
		Color("c9b6ff"), Color("9fe3d8"), Color("ffb3a7"), Color("d6e2a0"),
	]
	var color: Color = palette[absi(h) % palette.size()]
	# If the model reused an authored handle, borrow that viewer's identity.
	for u in catalog.users:
		if String(u["name"]).to_lower() == username.to_lower():
			return {
				"name": String(u["name"]),
				"color": String(u["color"]),
				"badge": String(u.get("badge", "none")),
				"traits": [persona],
			}
	return {"name": username, "color": color.to_html(false), "badge": badge, "traits": [persona]}


static func _clean_text(v: String) -> String:
	var s := v.replace("\r", " ").replace("\n", " ").replace("\t", " ")
	while s.contains("  "):
		s = s.replace("  ", " ")
	s = s.strip_edges()
	for q in ["\"", "'", "`"]:
		if s.begins_with(q) and s.ends_with(q) and s.length() > 1:
			s = s.substr(1, s.length() - 2)
	if s.length() > int(LIMITS.text_max):
		s = s.substr(0, int(LIMITS.text_max) - 1) + "…"
	return s.strip_edges()


static func _clean_username(v: String) -> String:
	var s := v.replace("@", "").strip_edges().replace(" ", "_")
	var out := ""
	for i in s.length():
		var c := s[i]
		if c == c.to_lower() or c == c.to_upper():		# letters, any case
			out += c
		elif c in "0123456789_.-":
			out += c
		elif c in ["♡", "<", ">", "+", "="]:
			out += c
	s = out
	while s.begins_with("_"):
		s = s.substr(1)
	if s.length() > int(LIMITS.username_max):
		s = s.substr(0, int(LIMITS.username_max))
	return s


static func _nearest_category(wanted: String, catalog: MessageCatalog) -> String:
	var w := wanted.to_lower().replace(" ", "_").replace("-", "_")
	for cat in catalog.categories.keys():
		if w == String(cat) or w.begins_with(String(cat)) or String(cat).begins_with(w):
			return String(cat)
	match w:
		"trolling", "troll", "teasing":
			return "mild_troll"
		"advertisement", "ads", "scam", "promotion":
			return "ad"
		"abuse", "hostile", "hostile_attack":
			return "attack"
		"rude", "personal_insult", "mean":
			return "insult"
		"compliment", "sweet":
			return "wholesome"
		"chat", "smalltalk", "neutral":
			return "friendly"
		"genuine_question", "genuine question":
			return "question"
		"constructive_criticism", "feedback":
			return "criticism"
		"personal_question", "personal":
			return "invasive"
		"repeat", "repeat_offender", "repeated":
			return "repeat_offender"
	return ""


static func _group_rank(group: String) -> int:
	match group:
		GROUP_POSITIVE:
			return 0
		GROUP_NEUTRAL:
			return 1
		GROUP_MINOR:
			return 2
		GROUP_MAJOR:
			return 3
	return 1


static func _without(arr: Array, value: String) -> Array:
	var out: Array = []
	for v in arr:
		if String(v) != value:
			out.append(v)
	return out
