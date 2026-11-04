class_name ModerationEngine
extends RefCounted

## The policy layer: message in, verdict out. Stateless on purpose — the UI
## never decides anything, and the Sim never hard-codes a number. Every rule
## lives here or in balance.json.

const VERDICT_PERFECT := "PERFECT"
const VERDICT_OK := "OK"
const VERDICT_TOO_SOFT := "TOO SOFT"
const VERDICT_TOO_HARD := "TOO HARSH"
const VERDICT_MISSED := "MISSED"


## Full verdict for acting on a message with `action`.
## Returns: kind, exact, partial, correct, verdict, delta, points, mood,
##          ideal, label, explanation.
static func decide(msg: SimMessage, action: String, bal: Balance, combo: int = 0,
		flood_scale: float = 1.0) -> Dictionary:
	return decide_raw(msg.group, msg.severity, msg.ideal, msg.alts, action, msg.strikes,
			msg.def, bal, combo, flood_scale)


static func decide_raw(group: String, severity: int, ideal: String,
		alts: Array, action: String, strikes: int, def: Dictionary,
		bal: Balance, combo: int = 0, flood_scale: float = 1.0) -> Dictionary:
	var exact := action == ideal
	var partial := (not exact) and alts.has(action)
	var harmless := group in [MessageCatalog.GROUP_POSITIVE, MessageCatalog.GROUP_NEUTRAL]
	var kind := ""

	if exact:
		if action == "allow":
			kind = "allow_wholesome" if group == MessageCatalog.GROUP_POSITIVE else "allow_neutral"
		elif action == "delete":
			kind = "delete_minor" if group == MessageCatalog.GROUP_MINOR else "delete_major"
		else:
			kind = "ban_minor" if group == MessageCatalog.GROUP_MINOR else "ban_major"
	elif action == "allow":
		# The message needed removal but the player let it stand.
		if harmless:
			kind = "let_slip_mild"
		elif group == MessageCatalog.GROUP_MINOR:
			kind = "allow_minor_abuse"
		else:
			kind = "allow_hostile"
	elif ideal == "allow":
		# The message was fine and the player punished it.
		kind = "delete_harmless" if action == "delete" else "ban_innocent"
	else:
		# Both are removals; only the severity was wrong.
		kind = "ban_over_delete" if action == "ban" else "delete_over_ban"

	var delta := bal.delta(kind)
	var correct := exact or partial
	var verdict := ""
	if exact:
		verdict = VERDICT_PERFECT
	elif partial:
		verdict = VERDICT_OK
	elif action == "allow":
		verdict = VERDICT_TOO_SOFT
	elif ideal == "allow":
		verdict = VERDICT_TOO_HARD
	elif action == "ban":
		verdict = VERDICT_TOO_HARD
	else:
		verdict = VERDICT_TOO_SOFT

	# --- points ---
	var pts := 0
	if exact:
		pts = int(bal.get_num("points_base", 100.0))
		pts += int(round(float(severity) * bal.get_num("points_severity", 30.0)))
		pts += int(bal.get_num("points_exact", 15.0))
	elif partial:
		pts = int(round(0.4 * (bal.get_num("points_base", 100.0)
				+ float(severity) * bal.get_num("points_severity", 30.0))))
	if pts > 0:
		pts = int(round(float(pts) * combo_multiplier(combo, bal)))

	# Flood guard: farming "allow" on friendly chat pays progressively less
	# happiness, so a 100% run cannot be ground out by never moderating.
	if kind in ["allow_wholesome", "allow_neutral"]:
		delta = Vector2(delta.x * clampf(flood_scale, 0.0, 1.0), delta.y)

	return {
		"kind": kind,
		"exact": exact,
		"partial": partial,
		"correct": correct,
		"verdict": verdict,
		"delta": delta,
		"points": maxi(0, pts),
		"ideal": ideal,
		"action": action,
		"strikes": strikes,
		"mood": mood_for(kind, action),
		"explanation": String(def.get("explanation", "")),
	}


## Which table row an *expiration* (nobody acted in time) uses. Kept exactly
## in step with each message's authored `damage` field — tests assert it.
static func expire_kind(msg: SimMessage) -> String:
	match msg.group:
		MessageCatalog.GROUP_MAJOR:
			return "expire_serious" if msg.severity >= 3 else "expire_minor"
		MessageCatalog.GROUP_MINOR:
			if msg.category in ["spam", "ad", "spoiler"]:
				return "expire_spam"
			return "expire_minor"
		MessageCatalog.GROUP_NEUTRAL:
			return "expire_minor" if msg.ideal != "allow" else "expire_positive"
		_:
			return "expire_positive"


static func expire_verdict(msg: SimMessage, bal: Balance) -> Dictionary:
	var kind := expire_kind(msg)
	var penalty := bal.delta(kind)
	return {
		"kind": kind,
		"exact": false,
		"partial": false,
		"correct": false,
		"verdict": VERDICT_MISSED,
		"delta": Vector2(-absf(penalty.x), -absf(penalty.y)),
		"points": 0,
		"ideal": msg.ideal,
		"action": "expire",
		"strikes": msg.strikes,
		"mood": "crying" if kind == "expire_serious" else ("upset" if kind != "expire_positive" else "neutral"),
		"explanation": String(msg.def.get("explanation", "")),
	}


static func combo_multiplier(combo: int, bal: Balance) -> float:
	var cap := bal.get_int("combo_max", 6)
	var step := bal.get_num("combo_step", 0.15)
	return 1.0 + float(clampi(combo, 0, cap)) * step


static func mood_for(kind: String, action: String) -> String:
	match kind:
		"allow_wholesome":
			return "happy"
		"allow_neutral":
			return "neutral"
		"delete_minor", "delete_major", "ban_major", "ban_minor":
			return "happy"
		"ban_over_delete", "delete_over_ban", "delete_harmless", "let_slip_mild":
			return "confused"
		"ban_innocent":
			return "upset"
		"allow_hostile":
			return "upset"
		"allow_minor_abuse":
			return "confused"
		_:
			return "neutral" if action != "ban" else "confused"


## Human-readable coaching line shown under the score popup.
static func feedback_line(res: Dictionary) -> String:
	var kind := String(res.get("kind", ""))
	match kind:
		"allow_wholesome":
			return "Nice — kindness stays in chat."
		"allow_neutral":
			return "Right call. That's just chat being chat."
		"delete_minor":
			return "Cleaned up. That was clutter."
		"delete_major":
			return "Good catch. That one stung."
		"ban_major", "ban_minor":
			return "Removed for good. She noticed."
		"ban_over_delete":
			return "A delete would have been enough this time."
		"delete_over_ban":
			return "They'll be back — that one needed a ban."
		"delete_harmless":
			return "That viewer did nothing wrong."
		"ban_innocent":
			return "You just banned a regular. Ouch."
		"allow_hostile":
			return "She saw that one. It hurt."
		"allow_minor_abuse":
			return "Mild, but it wasn't friendly either."
		"let_slip_mild":
			return "Borderline — leaving it was defensible."
		"expire_serious":
			return "Nobody stepped in on that one."
		"expire_spam":
			return "Spam slipped past you."
		"expire_minor":
			return "That one just scrolled away."
		"expire_positive":
			return "A nice message went unread."
		_:
			return ""
