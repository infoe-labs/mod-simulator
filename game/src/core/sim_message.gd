class_name SimMessage
extends RefCounted

## One chat message in flight. Pure data + derived moderation state — no
## nodes, no rendering, so the whole game can be simulated head-to-head.

var instance_id: int = 0
var def: Dictionary = {}            # the dataset row (shared, treat as read-only)
var text: String = ""
var category: String = ""
var group: String = "neutral"
var severity: int = 0
var tier: int = 1
var damage: float = 0.0
var username: String = ""
var color: String = "#cfd8e3"
var badge: String = "none"
var born_at: float = 0.0
var lifetime: float = 10.0
var remaining: float = 10.0
var strikes: int = 0                # this user's prior offenses in THIS category
var total_offenses: int = 0         # this user's prior offenses overall
var prior_messages: int = 0         # posts by this user earlier in this run
var ideal: String = "allow"
var alts: Array = []
var escalated: bool = false
var state: String = "pending"       # pending | allowed | deleted | banned | purged
var action: String = ""             # what the player actually chose
## "classic" for an authored row, "ai" for a message a browser model wrote.
## Set by Sim at spawn time; the UI reads it and must never guess.
var source: String = "classic"


static func from_def(def: Dictionary, cat: MessageCatalog, user: Dictionary,
		id: int, born: float, lifetime_s: float, prior_category: int,
		prior_total: int, bal: Balance) -> SimMessage:
	var m := SimMessage.new()
	m.def = def
	m.instance_id = id
	m.text = String(def["text"])
	m.category = String(def["category"])
	m.group = cat.group_for(def)
	m.severity = int(def["severity"])
	m.tier = int(def["tier"])
	m.damage = float(def["damage"])
	m.username = String(user["name"])
	m.color = String(user.get("color", "#cfd8e3"))
	m.badge = String(user.get("badge", "none"))
	m.born_at = born
	m.lifetime = lifetime_s
	m.remaining = lifetime_s
	m.strikes = prior_category
	m.total_offenses = prior_total
	var eff := effective_ideal(def, prior_category, bal)
	m.ideal = String(eff["ideal"])
	m.alts = eff["alts"]
	m.escalated = bool(eff["escalated"])
	return m


## Contextual moderation: an escalating category becomes ban-worthy once the
## same username has enough prior offenses. Categories outside
## strikes_to_ban (a one-off criticism, a mild troll) never escalate.
static func effective_ideal(def: Dictionary, prior_offenses: int, bal: Balance) -> Dictionary:
	var category := String(def["category"])
	var ideal := String(def["ideal_action"])
	var alts: Array = (def["alt_actions"] as Array).duplicate()
	var escalated := false
	if bool(def.get("escalates", false)) and bal.escalates_at(category):
		if prior_offenses >= bal.strikes_to_ban(category) and ideal != "ban":
			ideal = "ban"
			alts = ["delete"]
			escalated = true
	return {"ideal": ideal, "alts": alts, "escalated": escalated}


func is_harmless() -> bool:
	return group in [MessageCatalog.GROUP_POSITIVE, MessageCatalog.GROUP_NEUTRAL]


func is_abuse() -> bool:
	return group in [MessageCatalog.GROUP_MINOR, MessageCatalog.GROUP_MAJOR]


func is_serious() -> bool:
	return group == MessageCatalog.GROUP_MAJOR and severity >= 3


func is_positive() -> bool:
	return group == MessageCatalog.GROUP_POSITIVE


func fraction() -> float:
	if lifetime <= 0.0:
		return 0.0
	return clampf(remaining / lifetime, 0.0, 1.0)


func badge_label() -> String:
	match badge:
		"mod":
			return "MOD"
		"vip":
			return "VIP"
		"sub":
			return "SUB"
		_:
			return ""
