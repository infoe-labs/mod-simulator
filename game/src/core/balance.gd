class_name Balance
extends RefCounted

## Every tunable number in the game, loaded once from res://data/balance.json.
## Missing keys fall back to DEFAULTS so a half-edited file can never brick a run.

const PATH := "res://data/balance.json"

const DEFAULTS := {
	"session_seconds": 240.0,
	"starting_happiness": 50.0,
	"starting_trust": 35.0,
	"trust_to_win": 82.0,
	"win_from_fraction": 0.8,
	"max_active": 5,
	"queue_limit": 24,
	"act_cooldown": 0.14,
	"combo_step": 0.15,
	"combo_max": 6,
	"combo_points": 30,
	"points_base": 100,
	"points_severity": 30,
	"points_exact": 15,
	"positive_flood_decay": 0.14,
	"positive_flood_floor": 0.2,
	"trust_positive_cap": 48.0,
	"heal_strength": 0.88,
	"heal_exponent": 3.0,
	"heal_floor": 0.10,
	"trust_heal_strength": 0.82,
	"trust_heal_exponent": 2.2,
	"trust_heal_floor": 0.14,
	"strikes_to_ban": {
		"spam": 3, "ad": 2, "insult": 2, "harassment": 2, "attack": 2,
		"invasive": 3, "spoiler": 4,
	},
	"deltas": {
		"allow_wholesome": [3.0, 1.0],
		"allow_neutral": [1.0, 1.0],
		"delete_minor": [3.0, 2.0],
		"delete_major": [5.0, 3.0],
		"ban_major": [7.0, 4.0],
		"ban_minor": [5.5, 3.0],
		"ban_over_delete": [0.5, -1.0],
		"delete_over_ban": [1.0, -1.5],
		"let_slip_mild": [-1.5, -0.5],
		"delete_harmless": [-4.0, -4.0],
		"ban_innocent": [-9.0, -8.0],
		"allow_hostile": [-8.0, -4.0],
		"allow_minor_abuse": [-4.0, -2.0],
		"expire_serious": [-10.0, -3.0],
		"expire_spam": [-3.0, -1.0],
		"expire_minor": [-1.5, -0.5],
		"expire_positive": [-1.0, 0.0],
	},
	"phases": [
		{
			"id": "warmup", "label": "Warmup", "from": 0.0, "to": 30.0,
			"spawn_min": 3.0, "spawn_max": 4.0, "expiry_scale": 1.15,
			"max_active": 3, "repeat_offenders": false, "burst": 0.0,
			"weights": {
				"wholesome": 26, "friendly": 26, "question": 16, "joke": 12,
				"criticism": 6, "mild_troll": 8, "spam": 6,
			},
		},
	],
	"modes": {
		"story": {"label": "Tonight's Stream", "session_seconds": 240.0,
			"expiry_penalty_scale": 1.0, "wrong_penalty_scale": 1.0, "unlock": "none"},
		"relaxed": {"label": "Relaxed", "session_seconds": 300.0,
			"expiry_penalty_scale": 0.25, "wrong_penalty_scale": 0.4, "unlock": "none"},
		"endless": {"label": "Viral Night", "session_seconds": -1.0,
			"expiry_penalty_scale": 1.15, "wrong_penalty_scale": 1.0, "unlock": "win"},
	},
}

var data: Dictionary = {}


static func load_default() -> Balance:
	return load_path(PATH)


static func load_path(path: String) -> Balance:
	var b := Balance.new()
	b.data = _read_json(path)
	if b.data.is_empty():
		b.data = DEFAULTS.duplicate(true)
	return b


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("Balance file missing: %s (using defaults)" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("Balance unreadable: %s" % path)
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Balance is not valid JSON: %s" % path)
		return {}
	return parsed


func get_num(key: String, fallback: float = 0.0) -> float:
	if data.has(key) and data[key] is float:
		return data[key]
	if data.has(key) and data[key] is int:
		return float(data[key])
	var d: Variant = DEFAULTS.get(key, fallback)
	return float(d)


func get_int(key: String, fallback: int = 0) -> int:
	if data.has(key) and (data[key] is int or data[key] is float):
		return int(data[key])
	return int(DEFAULTS.get(key, fallback))


func deltas() -> Dictionary:
	var d: Variant = data.get("deltas", {})
	return d if typeof(d) == TYPE_DICTIONARY else DEFAULTS["deltas"]


func delta(key: String) -> Vector2:
	var table := deltas()
	var pair: Variant = table.get(key, DEFAULTS["deltas"].get(key, [0.0, 0.0]))
	if typeof(pair) != TYPE_ARRAY or pair.size() < 2:
		return Vector2.ZERO
	return Vector2(float(pair[0]), float(pair[1]))


func strikes_to_ban(category: String) -> int:
	var s: Variant = data.get("strikes_to_ban", DEFAULTS["strikes_to_ban"])
	if typeof(s) == TYPE_DICTIONARY and s.has(category):
		return int(s[category])
	return 999


func escalates_at(category: String) -> bool:
	return strikes_to_ban(category) < 999


func phases() -> Array:
	var p: Variant = data.get("phases", DEFAULTS["phases"])
	if typeof(p) != TYPE_ARRAY or p.is_empty():
		return DEFAULTS["phases"]
	return p


func phase_at(t: float) -> Dictionary:
	var list := phases()
	var chosen: Dictionary = list[0]
	for p in list:
		if t >= float(p.get("from", 0.0)):
			chosen = p
	return chosen


func phase_index_at(t: float) -> int:
	var list := phases()
	var idx := 0
	for i in list.size():
		if t >= float(list[i].get("from", 0.0)):
			idx = i
	return idx


func session_length(mode: String) -> float:
	var m := mode_config(mode)
	return float(m.get("session_seconds", get_num("session_seconds", 240.0)))


func mode_config(mode: String) -> Dictionary:
	var m: Variant = data.get("modes", DEFAULTS["modes"])
	if typeof(m) == TYPE_DICTIONARY and m.has(mode):
		return m[mode]
	return DEFAULTS["modes"].get(mode, DEFAULTS["modes"]["story"])


func mode_list() -> Array:
	## Ordered mode ids available in the menu.
	return ["story", "relaxed", "endless"]
