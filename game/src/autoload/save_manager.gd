extends Node

## Autoload: the local profile. user:// is IndexedDB on the web export, so a
## saved game survives a reload and works offline. If storage is unavailable
## (private tab, quota) the game still runs — it just forgets on exit.

const SAVE_PATH := Profile.PATH

var profile: Profile
var storage_ok := true
var dirty := false


func _ready() -> void:
	profile = Profile.load_from(SAVE_PATH)
	# Touch the file once so the title screen can warn about no-persistence.
	storage_ok = profile.save_to(SAVE_PATH)


func save() -> void:
	dirty = false
	if not profile.save_to(SAVE_PATH):
		storage_ok = false


func touch() -> void:
	dirty = true


func record(summary: Dictionary) -> void:
	profile.record(summary)
	save()


func setting(key: String) -> Variant:
	return profile.setting(key)


func set_setting(key: String, value: Variant) -> void:
	profile.set_setting(key, value)
	save()


func is_unlocked(mode: String) -> bool:
	return profile.is_unlocked(mode)


func mark_tutorial_done() -> void:
	profile.tutorial_seen = true
	save()


func reset_everything() -> void:
	profile = Profile.new()
	save()
