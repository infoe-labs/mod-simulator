class_name AIStatusRow
extends PanelContainer

## The one place the player can turn AI chat on, say yes to the download, and
## see what the model is actually doing. Used on the title screen and in
## Settings, so the wording can never drift between the two.
##
## Three rules this widget obeys:
##   * Nothing is downloaded before an explicit tap. The button says what it
##     costs, in megabytes, before it is pressed.
##   * If the device cannot run a model, the toggle is absent and the note says
##     so plainly. Classic Mode is never presented as a degraded state.
##   * Every label reflects the bridge's real state, polled, never assumed.

signal toggled(on: bool)

const REFRESH_EVERY := 0.4

var ai: AIChatManager
var _state_label: Label
var _detail: Label
var _note: Label
var _toggle: Button
var _action: Button
var _secondary: Button
var _bar: ProgressBar
var _accum := 0.0
var _last_text := ""


func _init(manager: AIChatManager = null) -> void:
	ai = manager if manager != null else GameState.ai_manager()
	var panel := UI.panel(UI.PANEL, 16, 14)
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	col.add_child(head)
	head.add_child(UI.label("LIVE CHAT MODEL", UI.FS_TINY, UI.VIOLET))
	head.add_child(UI.spacer())
	_state_label = UI.label("…", UI.FS_TINY, UI.TEXT_DIM)
	head.add_child(_state_label)

	_detail = UI.wrap_label("Writing chat with the authored script.", UI.FS_TINY, UI.TEXT_DIM)
	col.add_child(_detail)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.01
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 16)
	_bar.visible = false
	col.add_child(_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)

	_toggle = UI.button("AI CHAT: OFF", UI.FS_SMALL)
	_toggle.custom_minimum_size = Vector2(0, UI.MIN_TAP)
	_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toggle.pressed.connect(func():
		AudioManager.play("click")
		GameState.set_ai_enabled(not ai.enabled)
		toggled.emit(ai.enabled)
		_refresh(true))
	row.add_child(_toggle)

	_action = UI.button("DOWNLOAD", UI.FS_SMALL)
	_action.custom_minimum_size = Vector2(0, UI.MIN_TAP)
	_action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action.pressed.connect(_on_action)
	row.add_child(_action)

	_secondary = UI.button("delete model", UI.FS_TINY)
	_secondary.custom_minimum_size = Vector2(0, UI.MIN_TAP)
	_secondary.visible = false
	_secondary.pressed.connect(func():
		AudioManager.play("back")
		ai.delete_weights()
		ai.unload()
		_refresh(true))
	col.add_child(_secondary)

	_note = UI.wrap_label("", UI.FS_TINY, UI.TEXT_FAINT)
	col.add_child(_note)


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum >= REFRESH_EVERY:
		_accum = 0.0
		_refresh(false)


func _refresh(force: bool) -> void:
	if ai == null:
		return
	var has_bridge := ai.is_available()
	var state := ai.state_label()
	var detail := ai.detail_line()
	var enabled := ai.enabled
	var consented := bool(ai.status.get("consent", ai.consented))
	var phase := String(ai.status.get("phase", ai.phase))
	var mb := int(ai.last_consent_info.get("downloadMB", 0))
	var family := String(ai.last_consent_info.get("family", ""))
	var ready := ai.ready_flag

	var note := ""
	if not has_bridge:
		note = "AI chat runs in the browser. On this device the game uses the authored chat script, which is the same game."
		_toggle.visible = false
		_action.visible = false
		_secondary.visible = false
	else:
		_toggle.visible = true
		_toggle.text = "AI CHAT: ON" if enabled else "AI CHAT: OFF"
		_toggle.add_theme_color_override("font_color", UI.MINT if enabled else UI.TEXT_DIM)
		if not consented:
			_action.visible = true
			_action.text = "DOWNLOAD %s (%d MB)" % [family if family != "" else "chat model", mb] \
				if mb > 0 else "DOWNLOAD CHAT MODEL"
			_action.disabled = not enabled
			note = "One download, then it stays on this device. Nothing is sent anywhere, ever."
		elif phase == "downloading" or phase == "loading":
			_action.visible = true
			_action.text = "WAITING…"
			_action.disabled = true
			note = String(ai.status.get("progressText", "getting the model ready"))
		elif ready:
			_action.visible = true
			_action.text = "UNLOAD MODEL"
			_action.disabled = false
			_secondary.visible = true
			note = "Chat is written live by the model. Anything it says is checked against the same rules as authored chat."
		elif phase == "unsupported":
			_action.visible = false
			note = "This browser can't run the model, so chat comes from the authored script."
		elif phase == "error":
			_action.visible = true
			_action.text = "TRY AGAIN"
			_action.disabled = not enabled
			note = String(ai.status.get("error", ai.last_error))
		else:
			_action.visible = true
			_action.text = "LOAD MODEL"
			_action.disabled = not enabled
			note = "Turn AI chat on and the model loads on this device."

	var text := "%s|%s|%s|%s" % [state, detail, note, _toggle.text]
	if force or text != _last_text:
		_last_text = text
		_state_label.text = state
		_state_label.add_theme_color_override("font_color",
				UI.MINT if ready else (UI.AMBER if phase in ["downloading", "loading", "consent"] else UI.TEXT_DIM))
		_detail.text = detail
		_note.text = note
	var busy := phase in ["downloading", "loading"]
	_bar.visible = busy
	if busy:
		_bar.value = clampf(float(ai.status.get("progress", 0.0)), 0.0, 1.0)


func _on_action() -> void:
	var consented := bool(ai.status.get("consent", ai.consented))
	var ready := ai.ready_flag
	if not consented:
		AudioManager.play("open")
		GameState.set_ai_consent()
	elif ready:
		AudioManager.play("back")
		ai.unload()
	else:
		AudioManager.play("click")
		ai.request_download()
	_refresh(true)
