class_name SettingsScreen
extends Control

## Audio + accessibility. Everything lives in the local profile; nothing is
## sent anywhere, and there is no account anywhere in this game.

var _return_to := "menu"
var _confirm_reset := false
var _page: ScrollPage


func with_params(params: Dictionary) -> void:
	_return_to = String(params.get("return_to", "menu"))


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_page = ScrollPage.new()
	add_child(_page)
	var root := _page.content

	root.add_child(UI.label("SETTINGS", UI.FS_TITLE, UI.TEXT))
	root.add_child(UI.wrap_label("Sound, comfort and saved data. All of it stays on this device.",
			UI.FS_SMALL, UI.TEXT_DIM))

	var card := UI.panel(UI.PANEL, 20, 18, UI.PANEL_LINE)
	root.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	card.add_child(v)

	v.add_child(_slider_row("Master volume", "master", 1.0))
	v.add_child(_slider_row("Music", "music", 0.6))
	v.add_child(_slider_row("Sound effects", "sfx", 0.9))
	v.add_child(_check_row("Mute everything", "mute"))
	v.add_child(_check_row("Vibration (supported devices)", "haptics"))
	v.add_child(_check_row("Reduce motion / low detail", "reduce_motion"))

	# ---- the chat model -----------------------------------------------------
	var ai_card := UI.panel(UI.PANEL, 20, 18, UI.PANEL_LINE)
	root.add_child(ai_card)
	var av := VBoxContainer.new()
	av.add_theme_constant_override("separation", 10)
	ai_card.add_child(av)
	av.add_child(UI.wrap_label(
		"AI CHAT\nWhen it is on, an AI written into this page writes the viewers' messages on your "
		+ "device. Turn it off and the game generates chat locally instead - same rules, same "
		+ "scoring, same you.", UI.FS_SMALL, UI.TEXT))
	av.add_child(AIStatusRow.new(GameState.ai_manager()))
	av.add_child(_ai_profile_row())
	var lifetime := SaveManager.profile
	av.add_child(UI.wrap_label(
		"this device: %d AI-written messages across %d streams" % [lifetime.ai_messages, lifetime.ai_runs],
		UI.FS_TINY, UI.TEXT_FAINT))

	var data := UI.panel(UI.PANEL, 20, 18, UI.PANEL_LINE)
	root.add_child(data)
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 10)
	data.add_child(dv)
	dv.add_child(UI.wrap_label("SAVED ON THIS DEVICE", UI.FS_TINY, UI.TEXT_DIM))
	var p := SaveManager.profile
	dv.add_child(UI.wrap_label(
			"streams %d   ·   wins %d   ·   best score %d   ·   bans %d" % [
				p.games_played, p.wins, p.best_score, p.total_bans], UI.FS_SMALL, UI.TEXT))
	if not SaveManager.storage_ok:
		dv.add_child(UI.wrap_label("Storage is unavailable (private browsing?). The game still plays; it just won't remember.",
				UI.FS_TINY, UI.AMBER))
	var reset := UI.button("ERASE ALL LOCAL DATA" if not _confirm_reset else "TAP AGAIN TO ERASE",
			UI.FS_SMALL)
	reset.custom_minimum_size.y = UI.MIN_TAP
	reset.pressed.connect(_reset)
	dv.add_child(reset)
	var back := UI.tinted_button("BACK", UI.VIOLET, Color("4a3f80"), UI.FS_BODY + 4)
	back.custom_minimum_size = Vector2(0, 116)
	back.pressed.connect(_back)
	root.add_child(back)

	var note := UI.label("Offline: once the game has loaded once, it runs without a network. "
			+ "Install it from your browser menu to add it to your home screen.",
			UI.FS_TINY, UI.TEXT_FAINT)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(note)


func _ai_profile_row() -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := UI.label("model size", UI.FS_TINY, UI.TEXT_DIM)
	l.custom_minimum_size = Vector2(120, UI.MIN_TAP)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	var choices := HBoxContainer.new()
	choices.add_theme_constant_override("separation", 10)
	row.add_child(choices)
	var current := String(SaveManager.setting("ai_profile"))
	for entry in [["light", "LIGHT"], ["auto", "AUTO"], ["standard", "STRONG"]]:
		var key := String(entry[0])
		var b := UI.button(String(entry[1]), UI.FS_TINY)
		b.custom_minimum_size = Vector2(0, UI.MIN_TAP)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_color_override("font_color", UI.GOLD if current == key else UI.TEXT_DIM)
		b.pressed.connect(func():
			AudioManager.play("click")
			GameState.set_ai_profile(key)
			Main.goto("res://scenes/Settings.tscn", {"return_to": _return_to}))
		choices.add_child(b)
	return row


func _slider_row(title: String, key: String, fallback: float) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := UI.wrap_label(title, UI.FS_SMALL, UI.TEXT)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 12)
	row.add_child(controls)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = float(SaveManager.setting(key))
	if s.value <= 0.0 and fallback > 0.0 and SaveManager.setting(key) == null:
		s.value = fallback
	s.custom_minimum_size = Vector2(0, UI.MIN_TAP)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var val := UI.label("%d" % int(s.value * 100), UI.FS_SMALL, UI.TEXT_DIM)
	val.custom_minimum_size = Vector2(64, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	controls.add_child(s)
	controls.add_child(val)
	s.value_changed.connect(func(sv):
		SaveManager.set_setting(key, sv)
		val.text = "%d" % int(sv * 100)
		AudioManager.refresh_from_settings()
		AudioManager.play("click", -8.0, 1.0 + sv * 0.3))
	return row


func _check_row(title: String, key: String) -> Control:
	var b := CheckBox.new()
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	b.text = title
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.button_pressed = bool(SaveManager.setting(key))
	b.add_theme_font_size_override("font_size", UI.FS_SMALL)
	b.custom_minimum_size = Vector2(0, UI.MIN_TAP)
	b.focus_mode = Control.FOCUS_NONE
	b.toggled.connect(func(on):
		SaveManager.set_setting(key, on)
		AudioManager.refresh_from_settings()
		if key == "mute":
			AudioManager.set_muted(on)
		if key == "reduce_motion":
			AudioManager.play("click"))
	return b


func _reset() -> void:
	if not _confirm_reset:
		_confirm_reset = true
		AudioManager.play("error")
		_back_refresh()
		return
	SaveManager.reset_everything()
	_confirm_reset = false
	AudioManager.play("back")
	_back_refresh()


func _back_refresh() -> void:
	Main.goto("res://scenes/Settings.tscn", {"return_to": _return_to})


func _back() -> void:
	AudioManager.play("back")
	if _return_to == "game" and GameState.sim != null and not GameState.sim.is_over():
		Main.goto("res://scenes/Game.tscn", {"mode": GameState.sim.mode, "resume": true})
	else:
		Main.goto("res://scenes/MainMenu.tscn")
