class_name Profile
extends RefCounted

## Local-only profile: records, settings, unlocks. Written as JSON to user://
## (IndexedDB on the web export). Nothing here is ever sent anywhere, and a
## corrupt or missing file silently degrades to defaults.

const PATH := "user://profile.json"

const DEFAULT_SETTINGS := {
	"master": 1.0,
	"music": 0.6,
	"sfx": 0.9,
	"mute": false,
	"haptics": true,
	"reduce_motion": false,
	"show_tips": true,
	# AI chat is opt-in: it costs a one-time download, so nothing is fetched
	# until the player says yes. "auto" picks a model the device can handle.
	"ai_enabled": false,
	"ai_consent": false,
	"ai_profile": "auto",
	"ai_model": "",
}

const DEFAULT_UNLOCKS := {
	"relaxed": true,
	"endless": false,
}

var best_score: int = 0
var best_happiness: float = 0.0
var best_accuracy: float = 0.0
var best_combo: int = 0
var games_played: int = 0
var wins: int = 0
var losses: int = 0
var total_bans: int = 0
var total_messages: int = 0
var ai_messages: int = 0
var ai_runs: int = 0
var seconds_streamed: float = 0.0
var tutorial_seen: bool = false
var last_mode: String = "story"
var settings: Dictionary = {}
var unlocks: Dictionary = {}
var per_mode_best: Dictionary = {}     # mode -> best score


func _init() -> void:
	settings = DEFAULT_SETTINGS.duplicate(true)
	unlocks = DEFAULT_UNLOCKS.duplicate(true)


static func load_from(path: String = PATH) -> Profile:
	var p := Profile.new()
	if not FileAccess.file_exists(path):
		return p
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return p
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Save file is corrupt, starting fresh: %s" % path)
		return p
	var doc: Dictionary = parsed
	p.best_score = int(doc.get("best_score", 0))
	p.best_happiness = float(doc.get("best_happiness", 0.0))
	p.best_accuracy = float(doc.get("best_accuracy", 0.0))
	p.best_combo = int(doc.get("best_combo", 0))
	p.games_played = int(doc.get("games_played", 0))
	p.wins = int(doc.get("wins", 0))
	p.losses = int(doc.get("losses", 0))
	p.total_bans = int(doc.get("total_bans", 0))
	p.total_messages = int(doc.get("total_messages", 0))
	p.ai_messages = int(doc.get("ai_messages", 0))
	p.ai_runs = int(doc.get("ai_runs", 0))
	p.seconds_streamed = float(doc.get("seconds_streamed", 0.0))
	p.tutorial_seen = bool(doc.get("tutorial_seen", false))
	p.last_mode = String(doc.get("last_mode", "story"))
	if typeof(doc.get("settings", {})) == TYPE_DICTIONARY:
		for k in DEFAULT_SETTINGS.keys():
			if doc["settings"].has(k):
				p.settings[k] = doc["settings"][k]
	if typeof(doc.get("unlocks", {})) == TYPE_DICTIONARY:
		for k in DEFAULT_UNLOCKS.keys():
			if doc["unlocks"].has(k):
				p.unlocks[k] = bool(doc["unlocks"][k])
	if typeof(doc.get("per_mode_best", {})) == TYPE_DICTIONARY:
		p.per_mode_best = doc["per_mode_best"]
	# Winning the story mode is what unlocks the endless night.
	if p.wins > 0:
		p.unlocks["endless"] = true
	return p


func save_to(path: String = PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write save file %s (storage may be full or private mode)" % path)
		return false
	var doc := {
		"version": 1,
		"best_score": best_score,
		"best_happiness": best_happiness,
		"best_accuracy": best_accuracy,
		"best_combo": best_combo,
		"games_played": games_played,
		"wins": wins,
		"losses": losses,
		"total_bans": total_bans,
		"total_messages": total_messages,
		"ai_messages": ai_messages,
		"ai_runs": ai_runs,
		"seconds_streamed": seconds_streamed,
		"tutorial_seen": tutorial_seen,
		"last_mode": last_mode,
		"settings": settings,
		"unlocks": unlocks,
		"per_mode_best": per_mode_best,
	}
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	return true


## Fold one finished run into the record book.
func record(summary: Dictionary) -> void:
	games_played += 1
	best_score = maxi(best_score, int(summary.get("score", 0)))
	best_happiness = maxf(best_happiness, float(summary.get("happiness", 0.0)))
	best_accuracy = maxf(best_accuracy, float(summary.get("accuracy", 0.0)))
	best_combo = maxi(best_combo, int(summary.get("best_combo", 0)))
	total_bans += int(summary.get("bans", 0))
	total_messages += int(summary.get("total_messages", 0))
	var ai_in_run := int(summary.get("ai_messages", 0))
	ai_messages += ai_in_run
	if ai_in_run > 0:
		ai_runs += 1
	seconds_streamed += float(summary.get("time", 0.0))
	var mode := String(summary.get("mode", "story"))
	per_mode_best[mode] = maxi(int(per_mode_best.get(mode, 0)), int(summary.get("score", 0)))
	match String(summary.get("outcome", "")):
		"win":
			wins += 1
			unlocks["endless"] = true
		"lose":
			losses += 1


func setting(key: String) -> Variant:
	return settings.get(key, DEFAULT_SETTINGS.get(key, null))


func set_setting(key: String, value: Variant) -> void:
	settings[key] = value


## Every mode is available to every player from the first run; nothing is
## locked behind progress or payment. `unlocks` is kept in the save only so
## older save files still load, and is reported as a stat.
func is_unlocked(_mode: String) -> bool:
	return true


func _legacy_is_unlocked(mode: String) -> bool:
	match mode:
		"endless":
			return bool(unlocks.get("endless", false))
		_:
			return true


func rank() -> String:
	## A tiny progression ladder for the title screen.
	if wins >= 5:
		return "Head Moderator"
	if wins >= 1:
		return "Trusted Mod"
	if games_played >= 3:
		return "Trial Mod"
	return "New Mod"
