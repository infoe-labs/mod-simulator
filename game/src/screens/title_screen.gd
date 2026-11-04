class_name TitleScreen
extends Control

## The front door. You are already sitting at the desk — the menu is the
## laptop lid opening on tonight's stream.

var _world_host: SubViewportContainer
var _world_vp: SubViewport
var _world: DeskWorld
var _title: Label
var _sub: Label
var _records: Label
var _buttons: VBoxContainer
var _mode_row: HBoxContainer
var _selected_mode := "story"
var _booted := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_world()
	_build_ui()
	_refresh_records()
	AudioManager.refresh_from_settings()
	if not SaveManager.storage_ok:
		_show_storage_warning()


func _build_world() -> void:
	_world_host = SubViewportContainer.new()
	_world_host.stretch = true
	_world_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_world_host)
	_world_vp = SubViewport.new()
	_world_vp.own_world_3d = true
	_world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_world_host.add_child(_world_vp)
	_world = DeskWorld.new()
	_world.build("high")
	_world.set_screen_tint(Color("3a2f57"), 0.7)
	_world.set_pressure(0.15)
	_world_vp.add_child(_world)
	_layout_world()


func _build_ui() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.06, 0.04, 0.11, 0.62)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Main.apply_safe_margins(margin)
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 26)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	root.add_child(UI.vspacer(10))

	var kicker := UI.label("STREAMLET  ·  TONIGHT 9PM", UI.FS_TINY, UI.VIOLET)
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(kicker)

	_title = UI.label("STREAMER\nMOD SIMULATOR", UI.FS_HUGE, UI.TEXT)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_constant_override("line_spacing", -6)
	root.add_child(_title)

	_sub = UI.label("Keep chat kind. Keep Nori smiling. Don't ban the wrong person.",
			UI.FS_BODY, UI.TEXT_DIM)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_sub)

	root.add_child(UI.vspacer(16))
	_records = UI.label("", UI.FS_SMALL, UI.TEXT_DIM)
	_records.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_records.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_records)
	root.add_child(UI.vspacer(10))

	_mode_row = HBoxContainer.new()
	_mode_row.add_theme_constant_override("separation", 10)
	_mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(_mode_row)
	_rebuild_modes()

	# The chat model lives on the front door because it is a real choice: it
	# costs a download, and the player should see what it does before playing.
	root.add_child(AIStatusRow.new(GameState.ai_manager()))

	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 12)
	root.add_child(_buttons)

	var play := UI.tinted_button("START MODERATING", UI.MINT, UI.MINT_DARK, UI.FS_TITLE - 6)
	play.custom_minimum_size = Vector2(0, 132)
	play.pressed.connect(_play)
	_buttons.add_child(play)

	var tut := UI.button("HOW TO MOD  (2 min)", UI.FS_BODY + 2)
	tut.custom_minimum_size = Vector2(0, UI.MIN_TAP + 12)
	tut.pressed.connect(func():
		AudioManager.play("click")
		Main.goto("res://scenes/Tutorial.tscn"))
	_buttons.add_child(tut)

	var settings := UI.button("SETTINGS", UI.FS_BODY)
	settings.custom_minimum_size = Vector2(0, UI.MIN_TAP)
	settings.pressed.connect(func():
		AudioManager.play("click")
		Main.goto("res://scenes/Settings.tscn"))
	_buttons.add_child(settings)

	if SaveManager.profile.wins > 0:
		var cut := UI.button("REWATCH THE DATE SCENE", UI.FS_SMALL)
		cut.custom_minimum_size.y = UI.MIN_TAP
		cut.pressed.connect(func():
			AudioManager.play("click")
			GameState.last_summary = {"outcome": "win", "mode": "story", "score": 0,
					"happiness": 100.0, "trust": 90.0, "accuracy": 1.0, "best_combo": 0,
					"total_messages": 0, "time": 240.0, "title": "replay"}
			Main.goto("res://scenes/Ending.tscn"))
		_buttons.add_child(cut)

	root.add_child(UI.vspacer(20))
	var foot := UI.label("saves on this device  ·  no account  ·  works offline once loaded",
			UI.FS_TINY, UI.TEXT_FAINT)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(foot)


func _rebuild_modes() -> void:
	for c in _mode_row.get_children():
		c.queue_free()
	for m in ContentDB.bal().mode_list():
		# Every mode is open from the first launch: this game is free to play
		# and nothing is earned, sold or gated.
		var label_text := ContentDB.mode_label(m)
		var b := UI.button(label_text, UI.FS_TINY)
		b.custom_minimum_size = Vector2(0, 80)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = false
		var is_sel: bool = (m == _selected_mode)
		b.add_theme_color_override("font_color", UI.GOLD if is_sel else UI.TEXT_DIM)
		var sb := StyleBoxFlat.new()
		sb.bg_color = UI.PANEL_LIGHT if is_sel else UI.PANEL
		sb.set_corner_radius_all(12)
		sb.set_content_margin_all(8)
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_width_top = 2
		sb.border_width_bottom = 2
		sb.border_color = UI.GOLD if is_sel else UI.PANEL_LINE
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			b.add_theme_stylebox_override(st, sb)
		var mode: String = m
		b.pressed.connect(func():
			_selected_mode = mode
			AudioManager.play("click", -6.0, 1.2)
			_rebuild_modes())
		_mode_row.add_child(b)


func _refresh_records() -> void:
	var p := SaveManager.profile
	var bits: Array = []
	bits.append("%s" % p.rank())
	bits.append("best %s" % _fmt(p.best_score))
	bits.append("top mood %d%%" % int(p.best_happiness))
	bits.append("%d wins / %d streams" % [p.wins, p.games_played])
	_records.text = "   ·   ".join(bits)


func _fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


func _play() -> void:
	if not SaveManager.profile.tutorial_seen:
		SaveManager.profile.tutorial_seen = true
		SaveManager.save()
	AudioManager.play("open")
	GameState.pending_mode = _selected_mode
	Main.goto("res://scenes/Game.tscn", {"mode": _selected_mode})


func _show_storage_warning() -> void:
	var l := UI.label("Private tab: scores won't be saved this session.",
			UI.FS_TINY, UI.AMBER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_records.get_parent().add_child(l)
	_records.get_parent().move_child(l, _records.get_index() + 1)


func _layout_world() -> void:
	var canvas := size
	if canvas.x <= 1.0:
		canvas = get_viewport_rect().size
	var w := maxi(160, int(canvas.x * 0.5))
	var h := maxi(160, int(canvas.y * 0.5))
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_world.fit_canvas(Vector2(w, h))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		call_deferred("_layout_world")
