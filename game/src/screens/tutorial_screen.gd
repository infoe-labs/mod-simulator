class_name TutorialScreen
extends Control

## Teaches by making you call four real messages, not by reading a wall of
## text. Every step ends with the verdict + the reason.

const STEPS := [
	{
		"kind": "intro",
		"head": "You're the mod now",
		"body": "Nori is live in a minute. Chat is about to get busy and she can't read all of it.\n\nEvery message gets one of three calls. That's the whole game.",
	},
	{
		"kind": "choose", "id": "WH01",
		"head": "Kind chat stays",
		"hint": "ALLOW keeps it. Harmless messages are also allowed if you do nothing. DELETE hides it. BAN removes the viewer.",
	},
	{
		"kind": "choose", "id": "CR01",
		"head": "A complaint is not abuse",
		"hint": "Someone disagreeing with her is normal chat. Punish it and chat stops talking.",
	},
	{
		"kind": "choose", "id": "SP01",
		"head": "Clutter gets deleted",
		"hint": "Spam isn't evil, it's just noise. Delete the noise, don't ruin someone's night.",
	},
	{
		"kind": "choose", "id": "HA01",
		"head": "Cruelty gets acted on",
		"hint": "Leave this one up and Nori sees it. That costs her mood.",
	},
	{
		"kind": "choose", "id": "RO05",
		"head": "Read the strike count",
		"hint": "The badge on the left is how many times this viewer already crossed the line. Repeat offenders get banned.",
	},
	{
		"kind": "meters",
		"head": "Two meters, two jobs",
		"body": "MOOD is how she feels right now. TRUST is how much she believes your judgment.\n\nWin the night: get MOOD to 100% and TRUST past the line before the stream ends.\n\nMiss abuse and mood tanks. Ban an innocent viewer and trust tanks - she remembers.",
	},
	{
		"kind": "outro",
		"head": "That's it. Go be good for her.",
		"body": "Tap a message to pick which one you're answering, then hit ALLOW, DELETE or BAN.\n\nKeyboard: 1 = ALLOW, 2 = DELETE, 3 = BAN, Tab = next message, Esc = pause.",
	},
]

var _index := 0
var _stage_host: SubViewportContainer
var _stage_vp: SubViewport
var _stage: VTuberStage
var _head: Label
var _body: Label
var _card_slot: Control
var _card: ChatMessageRow = null
var _actions: HBoxContainer
var _verdict: PanelContainer
var _verdict_label: Label
var _next: Button
var _dots: Label
var _answered := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_stage()
	_build_ui()
	_show()


func _build_stage() -> void:
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_stage_host = SubViewportContainer.new()
	_stage_host.stretch = true
	_stage_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_host.custom_minimum_size = Vector2(0, 300)
	add_child(_stage_host)
	_stage_vp = SubViewport.new()
	_stage_vp.own_world_3d = true
	_stage_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_stage_host.add_child(_stage_vp)
	_stage = VTuberStage.new(ProceduralVTuber.default_config())
	_stage_vp.add_child(_stage)


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Main.apply_safe_margins(margin)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var bar := HBoxContainer.new()
	root.add_child(bar)
	var back := UI.button("< MENU", UI.FS_SMALL)
	back.custom_minimum_size = Vector2(120, UI.MIN_TAP - 4)
	back.pressed.connect(func():
		AudioManager.play("back")
		Main.goto("res://scenes/MainMenu.tscn"))
	bar.add_child(back)
	_dots = UI.label("", UI.FS_SMALL, UI.TEXT_DIM)
	_dots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_dots)
	var skip := UI.button("SKIP", UI.FS_SMALL)
	skip.custom_minimum_size = Vector2(110, UI.MIN_TAP - 4)
	skip.pressed.connect(_finish)
	bar.add_child(skip)

	_head = UI.label("", UI.FS_TITLE, UI.TEXT)
	_head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_head)

	_card_slot = VBoxContainer.new()
	_card_slot.custom_minimum_size = Vector2(0, 150)
	root.add_child(_card_slot)

	_body = UI.wrap_label("", UI.FS_BODY, UI.TEXT_DIM)
	root.add_child(_body)

	_verdict = UI.panel(UI.PANEL, 16, 14, UI.PANEL_LINE)
	_verdict.visible = false
	root.add_child(_verdict)
	_verdict_label = UI.wrap_label("", UI.FS_SMALL, UI.TEXT)
	_verdict.add_child(_verdict_label)

	root.add_child(UI.vspacer(6))

	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", UI.BUTTON_GAP)
	root.add_child(_actions)
	var a := UI.tinted_button("ALLOW", UI.MINT, UI.MINT_DARK, UI.FS_BODY + 4)
	var d := UI.tinted_button("DELETE", UI.AMBER, UI.AMBER_DARK, UI.FS_BODY + 4)
	var b := UI.tinted_button("BAN", UI.CORAL, UI.CORAL_DARK, UI.FS_BODY + 4)
	for x in [a, d, b]:
		x.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		x.custom_minimum_size = Vector2(0, 116)
		_actions.add_child(x)
	a.pressed.connect(func(): _answer("allow"))
	d.pressed.connect(func(): _answer("delete"))
	b.pressed.connect(func(): _answer("ban"))

	_next = UI.tinted_button("NEXT", UI.VIOLET, Color("4a3f80"), UI.FS_BODY + 4)
	_next.custom_minimum_size = Vector2(0, 116)
	_next.visible = false
	_next.pressed.connect(_advance)
	root.add_child(_next)


func _show() -> void:
	var step: Dictionary = STEPS[_index]
	_dots.text = "%d / %d" % [_index + 1, STEPS.size()]
	_head.text = String(step["head"])
	_answered = false
	_verdict.visible = false
	_next.visible = false
	_actions.visible = false
	for c in _card_slot.get_children():
		c.queue_free()
	_card = null

	if step["kind"] == "choose":
		_body.text = String(step.get("hint", ""))
		var def := _find_def(String(step["id"]))
		if def.is_empty():
			_body.text = "(missing sample message)"
		else:
			_card = ChatMessageRow.new()
			_card_slot.add_child(_card)
			var m := SimMessage.from_def(def, ContentDB.cat(), _user_for(def), 1, 0.0,
					999.0, 3 if String(def["category"]) == "repeat_offender" else 0,
					3 if String(def["category"]) == "repeat_offender" else 0, ContentDB.bal())
			m.ideal = String(def["ideal_action"])
			m.alts = (def["alt_actions"] as Array).duplicate()
			_card.bind(m, ContentDB.cat())
			_card.set_focused(true)
			_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_actions.visible = true
		_stage.react("neutral", 0.1)
		_stage.set_expression("neutral")
	elif step["kind"] == "meters":
		_body.text = String(step["body"])
		_next.visible = true
		_stage.set_expression("happy")
	elif step["kind"] == "outro":
		_body.text = String(step["body"])
		_next.text = "START THE STREAM"
		_next.visible = true
		_stage.set_expression("excited")
	else:
		_body.text = String(step["body"])
		_next.visible = true
		_stage.set_expression("shocked")


func _find_def(id: String) -> Dictionary:
	for m in ContentDB.cat().messages:
		if String(m["id"]) == id:
			return m
	return {}


func _user_for(def: Dictionary) -> Dictionary:
	var pool := ContentDB.cat().users_for(String(def["category"]))
	if pool.is_empty():
		return {"name": "viewer", "color": "#cfd8e3", "badge": "none"}
	return pool[0]


func _answer(action: String) -> void:
	if _answered or _card == null:
		return
	_answered = true
	var m := _card.msg
	var res := ModerationEngine.decide(m, action, ContentDB.bal(), 0, 1.0)
	var correct := bool(res["correct"])
	_verdict.visible = true
	var verdict := String(res["verdict"])
	var line := String(res["explanation"])
	var coach := ModerationEngine.feedback_line(res)
	_verdict_label.text = "%s   ideal: %s\n%s\n%s" % [verdict, String(m.ideal).to_upper(), line, coach]
	var col := UI.MINT if bool(res["exact"]) else (UI.AMBER if correct else UI.CORAL)
	_verdict_label.add_theme_color_override("font_color", col)
	var sb := _verdict.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	sb.border_color = col
	sb.bg_color = Color(col, 0.10)
	_verdict.add_theme_stylebox_override("panel", sb)
	_actions.visible = false
	_next.visible = true
	_next.text = "NEXT"
	_stage.react(String(res["mood"]), 2.0)
	AudioManager.play("allow" if correct else "error")


func _advance() -> void:
	if _index >= STEPS.size() - 1:
		_finish()
		return
	_index += 1
	AudioManager.play("click")
	_show()


func _finish() -> void:
	AudioManager.play("open")
	SaveManager.mark_tutorial_done()
	Main.goto("res://scenes/MainMenu.tscn")


func _layout() -> void:
	var canvas := size
	if canvas.x <= 1.0:
		return
	_stage_host.custom_minimum_size = Vector2(0, clampf(canvas.y * 0.26, 200.0, 380.0))
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_stage.fit(1.15)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		call_deferred("_layout")
