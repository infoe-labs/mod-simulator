extends SceneTree

var cat: MessageCatalog


func _initialize() -> void:
	cat = MessageCatalog.load_default()
	var batch := [
		{"text": "best stream tonight", "category": "wholesome", "severity": 0, "ideal_action": "allow", "alt_actions": [], "username": "fan1", "rationale": "x"},
		{"text": "what sensitivity do you use", "category": "question", "severity": 0, "ideal_action": "allow", "alt_actions": [], "username": "fan2", "rationale": "x"},
		{"text": "FREE V-BUCKS check profile", "category": "ad", "severity": 2, "ideal_action": "delete", "alt_actions": ["ban"], "username": "promo1", "rationale": "x"},
		{"text": "best stream tonight", "category": "wholesome", "severity": 0, "ideal_action": "allow", "alt_actions": [], "username": "fan1", "rationale": "x"},
		{"text": "click http://spam.example", "category": "spam", "severity": 1, "ideal_action": "delete", "alt_actions": [], "username": "promo2", "rationale": "x"},
		{"text": "you are genuinely gifted", "category": "wholesome", "severity": 0, "ideal_action": "allow", "alt_actions": [], "username": "fan3", "rationale": "x"},
	]
	var res := AIContent.validate_batch(batch, cat, {}, 1, 3)
	print("ok=", res["ok"], " dropped=", res["dropped"], " repaired=", res["repaired"])
	for d in res["defs"]:
		print("  KEEP: ", d["username"], " | ", d["text"], " | ", d["category"], " ", d["group"], " ", d["ideal_action"], " alts=", d["alt_actions"])
	for t in ["click http://spam.example", "buy followers now cheap", "you should disappear forever"]:
		var r := AIContent.validate_message({"text": t, "category": "spam", "severity": 1, "ideal_action": "delete", "username": "probe"}, cat)
		print("PROBE '", t, "' -> ok=", r["ok"], " problems=", r.get("problems", []), " ", r.get("def", {}).get("category", "-"))
	quit()
