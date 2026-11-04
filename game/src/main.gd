extends Node

## Autoload screen router. Screens are Controls parented to the root window,
## one at a time. Also owns the two platform-ish concerns every screen would
## otherwise re-implement: the shared theme and browser safe-area insets.

const BOOT_SCREEN := "res://scenes/MainMenu.tscn"

var current: Control = null
var safe := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var e2e := false
var _pilot: RefCounted = null


func _ready() -> void:
	get_tree().root.theme = UI.build_theme()
	_update_safe_area()
	get_tree().root.size_changed.connect(_update_safe_area)
	call_deferred("_boot")


func _boot() -> void:
	if not ContentDB.is_ready():
		_show_fatal()
		return
	goto(BOOT_SCREEN)
	_maybe_start_pilot()


func _process(delta: float) -> void:
	# Re-apply the safe area on rotation; cheap, and avoids relying on signals
	# that behave differently on desktop, Android and the browser.
	if Engine.get_frames_drawn() % 20 == 0:
		_update_safe_area()
	if _pilot != null and not _pilot.is_done():
		_pilot.tick(delta)


## Automated playthrough used by tools/e2e. Desktop: `godot -- --e2e`.
## Web: load the page with `?e2e=1`. Normal players never hit either path.
func _maybe_start_pilot() -> void:
	var args: Array = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if args.has("--e2e"):
		_start_pilot()
	elif OS.has_feature("web"):
		# The query string is only reachable through the page.
		var q := String(JavaScriptBridge.eval("window.location.search || ''", true))
		if "e2e=1" in q:
			_start_pilot()


func _start_pilot() -> void:
	if e2e:
		return
	e2e = true
	var Pilot := load("res://src/e2e_pilot.gd")
	_pilot = Pilot.new()
	print("[e2e] boot")
	_pilot.start(self)


func goto(scene_path: String, params: Dictionary = {}) -> void:
	var res := load(scene_path)
	if res == null:
		push_error("Missing screen: %s" % scene_path)
		return
	_goto_instance(res.instantiate(), params)


func goto_script(script_path: String, params: Dictionary = {}) -> void:
	_goto_instance(load(script_path).new(), params)


func _goto_instance(screen: Control, params: Dictionary) -> void:
	if current != null and is_instance_valid(current):
		current.queue_free()
	var s: Control = screen
	if s.has_method("with_params"):
		s.with_params(params)
	get_tree().root.add_child(s)
	current = s
	if s.has_method("screen_entered"):
		s.screen_entered()


func _show_fatal() -> void:
	var l := UI.wrap_label(
		"The chat archive failed to load.\n\nMake sure game/data/messages.json and "
		+ "game/data/balance.json are exported with the build.", UI.FS_BODY, UI.CORAL)
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	get_tree().root.add_child(l)
	current = l


## iOS notch / Android cutout support. DisplayServer hands us OS pixels; the
## canvas is scaled, so convert to canvas units before applying as margins.
func _update_safe_area() -> void:
	safe = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var win := get_tree().root
	if win == null:
		return
	var os_size := Vector2(DisplayServer.window_get_size())
	var canvas := win.get_visible_rect().size
	if os_size.x <= 1.0 or os_size.y <= 1.0 or canvas.x <= 1.0:
		return
	var area := DisplayServer.get_display_safe_area()
	if area.size.x <= 0 or area.size.y <= 0:
		return
	var origin := Vector2(DisplayServer.window_get_position())
	var k := canvas / os_size
	var left := (float(area.position.x) - origin.x) * k.x
	var top := (float(area.position.y) - origin.y) * k.y
	var right := (origin.x + os_size.x - float(area.position.x + area.size.x)) * k.x
	var bottom := (origin.y + os_size.y - float(area.position.y + area.size.y)) * k.y
	safe = {
		"left": clampf(left, 0.0, 120.0),
		"top": clampf(top, 0.0, 170.0),
		"right": clampf(right, 0.0, 120.0),
		"bottom": clampf(bottom, 0.0, 170.0),
	}


func apply_safe_margins(c: Control) -> void:
	var m := c as MarginContainer
	if m == null:
		return
	m.add_theme_constant_override("margin_left", int(safe["left"]))
	m.add_theme_constant_override("margin_top", int(safe["top"]))
	m.add_theme_constant_override("margin_right", int(safe["right"]))
	m.add_theme_constant_override("margin_bottom", int(safe["bottom"]))


## Backgrounded tab / app switch: never let the sim keep ticking unseen.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		if current != null and current.has_method("auto_pause"):
			current.auto_pause()
