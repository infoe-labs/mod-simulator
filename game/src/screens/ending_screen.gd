class_name EndingScreen
extends Control

## The payoff: she signs off, thanks you, and asks you out. Kept short, sweet
## and entirely fictional - tap through, pick a date, get the good ending.

const SCRIPT := [
	"wait... the stream ended and you're still here?",
	"okay. so. I've been meaning to say this all night but I kept chickening out.",
	"you were incredible up there. I felt... safe, basically the whole time.",
	"nobody has ever looked after my chat like that. I noticed. I notice everything, you know.",
	"so. um. I'm going to say it before I lose my nerve.",
	"would you want to go on a date? Like a real one. I already picked a place, is that too much?",
	"you don't have to answer instantly. ...please answer instantly.",
]

const DATES := [
	{"label": "THE LITTLE RAMEN PLACE", "reply": "the ramen place!! you GET me. seven o'clock. I'll wear the hoodie from the thumbnail."},
	{"label": "ARCADE + CLAW MACHINES", "reply": "arcade, yes. I will win you a very ugly plush and I will never let you forget it."},
	{"label": "MOVIE MARATHON AT YOURS", "reply": "a movie marathon?? you're dangerous. I'm bringing the good snacks and terrible opinions."},
]

var _stage_host: SubViewportContainer
var _stage_vp: SubViewport
var _stage: VTuberStage
var _line_label: Label
var _name_label: Label
var _index := -1
var _phase := "dialogue"
var _date_buttons: VBoxContainer
var _continue: Button
var _skip: Button


func with_params(params: Dictionary) -> void:
	if params.has("vtuber") and typeof(params["vtuber"]) == TYPE_DICTIONARY:
		_cfg = params["vtuber"]


var _cfg: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color("120d1c")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_stage_host = SubViewportContainer.new()
	_stage_host.stretch = true
	_stage_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_host.custom_minimum_size = Vector2(0, 420)
	_stage_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_stage_host)
	_stage_vp = SubViewport.new()
	_stage_vp.own_world_3d = true
	_stage_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_stage_host.add_child(_stage_vp)
	_stage = VTuberStage.new(_cfg if not _cfg.is_empty() else ProceduralVTuber.default_config())
	_stage.set_expression("happy")
	_stage_vp.add_child(_stage)

	# A warm vignette so she reads as "lit by the stream".
	var glow := ColorRect.new()
	glow.color = Color(UI.PINK, 0.06)
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	var tap := Control.new()
	tap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tap)
	tap.gui_input.connect(_on_tap)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Main.apply_safe_margins(margin)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(root)
	root.add_child(UI.vspacer(30))

	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	top.add_child(UI.label("NORI  ·  SIGNING OFF", UI.FS_TINY, UI.PINK))
	top.add_child(UI.vspacer(6))
	_skip = UI.button("SKIP", UI.FS_TINY)
	_skip.custom_minimum_size = Vector2(110, 78)
	_skip.pressed.connect(_to_results)
	top.add_child(_skip)

	root.add_child(UI.vspacer(200))

	var card := UI.panel(Color(UI.PANEL, 0.95), 20, 16, UI.PINK)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 8)
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(cv)
	_name_label = UI.label("noriwave", UI.FS_TINY, UI.PINK)
	cv.add_child(_name_label)
	_line_label = UI.wrap_label("", UI.FS_CHAT, UI.TEXT)
	cv.add_child(_line_label)

	_date_buttons = VBoxContainer.new()
	_date_buttons.add_theme_constant_override("separation", 10)
	_date_buttons.visible = false
	root.add_child(_date_buttons)
	for d in DATES:
		var b := UI.tinted_button(String(d["label"]), UI.VIOLET, Color("4a3f80"), UI.FS_BODY + 2)
		b.custom_minimum_size = Vector2(0, 112)
		b.pressed.connect(_pick_date.bind(String(d["reply"])))
		_date_buttons.add_child(b)

	_continue = UI.tinted_button("CONTINUE", UI.MINT, UI.MINT_DARK, UI.FS_BODY + 4)
	_continue.custom_minimum_size = Vector2(0, 112)
	_continue.visible = false
	_continue.pressed.connect(_to_results)
	root.add_child(_continue)

	_advance()


func _advance() -> void:
	_index += 1
	if _index < SCRIPT.size():
		_line_label.text = SCRIPT[_index]
		_stage.react(_mood_for(_index), 2.2)
		_stage.say_for(1.6)
		AudioManager.play("heart", -14.0, 1.0 + float(_index % 3) * 0.08)
		_confetti(2)
		return
	if _phase == "dialogue":
		_phase = "ask"
		_line_label.text = "So... where are we going?"
		_date_buttons.visible = true
		_stage.set_expression("blushing")
		AudioManager.play_music("loop_cozy")
		_confetti(14)


func _mood_for(i: int) -> String:
	if i <= 1:
		return "shocked"
	if i <= 3:
		return "happy"
	if i <= 4:
		return "blushing"
	return "excited"


func _pick_date(reply: String) -> void:
	if _phase == "done":
		return
	_phase = "done"
	_date_buttons.visible = false
	_line_label.text = reply
	_name_label.text = "noriwave  ·  <3"
	_stage.set_expression("laughing")
	_stage.say_for(2.4)
	AudioManager.play("win")
	_confetti(30)
	_continue.visible = true


func _on_tap(event: InputEvent) -> void:
	if _phase != "dialogue":
		return
	var pressed := false
	if event is InputEventScreenTouch:
		pressed = event.pressed
	elif event is InputEventMouseButton:
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventKey:
		pressed = event.pressed and (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER)
	if pressed:
		_advance()


func _confetti(n: int) -> void:
	if bool(SaveManager.setting("reduce_motion")):
		return
	var cols := [UI.PINK, UI.MINT, UI.GOLD, UI.VIOLET, UI.SKY]
	for i in n:
		var p := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = cols[i % cols.size()]
		sb.set_corner_radius_all(10)
		sb.set_content_margin_all(0)
		p.add_theme_stylebox_override("panel", sb)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.z_index = 30
		var s := 10.0 + float(i % 4) * 6.0
		p.custom_minimum_size = Vector2(s, s)
		p.size = Vector2(s, s)
		p.position = Vector2(randf() * size.x, size.y * (0.3 + randf() * 0.4))
		p.rotation = randf() * PI
		add_child(p)
		var tw := create_tween().set_parallel(true)
		tw.tween_property(p, "position:y", p.position.y - 260.0 - randf() * 240.0, 1.6 + randf())
		tw.tween_property(p, "rotation", p.rotation + (randf() - 0.5) * 6.0, 2.0)
		tw.tween_property(p, "modulate:a", 0.0, 1.9)
		tw.chain().tween_callback(p.queue_free)


func _to_results() -> void:
	if _phase != "done":
		_phase = "done"
	_index = -1
	GameState.last_summary = GameState.last_summary.duplicate()
	GameState.last_summary["ending_seen"] = true
	AudioManager.play("click")
	Main.goto("res://scenes/Results.tscn", {"summary": GameState.last_summary})


func _layout() -> void:
	var canvas := size
	if canvas.x <= 1.0:
		return
	_stage_host.custom_minimum_size = Vector2(0, clampf(canvas.y * 0.46, 240.0, 620.0))
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_stage.fit(canvas.x / maxf(1.0, canvas.y * 0.46))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		call_deferred("_layout")
