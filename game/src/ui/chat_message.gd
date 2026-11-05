class_name ChatMessageRow
extends PanelContainer

## One row in the moderation tray. Tap to pick it; never tap-to-moderate, so a
## scrolling thumb can't accidentally ban somebody.

signal tapped(instance_id: int)

const IDLE := Color("241d33")
const FOCUSED_BG := Color("33264f")

var msg: SimMessage = null
var is_focused := false

var _badge: Label
var _strikes: Label
var _username: Label
var _chips: Label
var _text: Label
var _timer: ProgressBar
var _timer_fill: StyleBoxFlat
var _style: StyleBoxFlat
var _press_pos := Vector2.ZERO
var _press_time := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, 104)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_contents = false

	_style = StyleBoxFlat.new()
	_style.bg_color = IDLE
	_style.set_corner_radius_all(16)
	_style.set_content_margin_all(10)
	_style.shadow_color = Color(0, 0, 0, 0.35)
	_style.shadow_size = 0
	_style.shadow_offset = Vector2(0, 3)
	add_theme_stylebox_override("panel", _style)

	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(outer)

	var badge_col := VBoxContainer.new()
	badge_col.custom_minimum_size = Vector2(64, 0)
	badge_col.alignment = BoxContainer.ALIGNMENT_CENTER
	badge_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(badge_col)
	_badge = UI.label("", UI.FS_TINY, UI.TEXT_DIM)
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.custom_minimum_size = Vector2(64, 0)
	badge_col.add_child(_badge)
	_strikes = UI.label("", UI.FS_TINY, UI.CORAL)
	_strikes.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_strikes.custom_minimum_size = Vector2(64, 0)
	badge_col.add_child(_strikes)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)
	_username = UI.label("", UI.FS_NAME)
	_username.clip_text = true
	_username.custom_minimum_size.x = 120.0
	_username.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_username)
	_chips = UI.label("", UI.FS_TINY, UI.TEXT_DIM)
	# Chips must never hand out the verdict. A real moderator sees role, account
	# history and what the message says - not "this one is Harassment" - so the
	# chips carry *facts* and the category is only revealed after you decide.
	_chips.clip_text = true
	_chips.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chips.size_flags_stretch_ratio = 0.8
	head.add_child(_chips)

	_text = UI.label("", UI.FS_CHAT)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.max_lines_visible = 3
	_text.ellipsis_char = "…"
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_text)

	var track := Panel.new()
	var track_sb := StyleBoxFlat.new()
	track_sb.bg_color = Color("120e1b")
	track_sb.set_corner_radius_all(6)
	track_sb.set_content_margin_all(0)
	track.add_theme_stylebox_override("panel", track_sb)
	track.custom_minimum_size = Vector2(0, 10)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(track)
	_timer = ProgressBar.new()
	_timer.min_value = 0.0
	_timer.max_value = 1.0
	_timer.show_percentage = false
	_timer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0)
	bg.set_corner_radius_all(6)
	bg.set_content_margin_all(0)
	_timer.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UI.MINT
	fill.set_corner_radius_all(6)
	fill.set_content_margin_all(0)
	_timer.add_theme_stylebox_override("fill", fill)
	_timer_fill = fill
	track.add_child(_timer)

	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)


func bind(m: SimMessage, catalog: MessageCatalog) -> void:
	msg = m
	if msg == null:
		return
	_username.text = msg.username
	_username.add_theme_color_override("font_color", UI.hex(msg.color))
	var badge_text := msg.badge_label()
	_badge.text = badge_text
	_badge.add_theme_color_override("font_color", _badge_color(msg.badge))
	_badge.visible = badge_text != ""
	_chips.text = _history_chips(msg)
	_text.text = msg.text
	_refresh_strikes(catalog)
	set_focused(false)


## What a moderator can actually see before deciding: how long this account has
## been around tonight and whether it has been warned. Deliberately *not* the
## moderation category - that would turn the game into reading a label.
func _history_chips(m: SimMessage) -> String:
	var parts: Array = []
	if m.prior_messages == 0:
		parts.append("first tonight")
	elif m.prior_messages == 1:
		parts.append("2nd post")
	elif m.prior_messages < 4:
		parts.append("%d posts" % (m.prior_messages + 1))
	else:
		parts.append("posting a lot (%d)" % (m.prior_messages + 1))
	if m.total_offenses > 0:
		parts.append("warned x%d" % m.total_offenses)
	return "  ·  ".join(parts)


## Called once the player has committed: only now does the row name the category
## and the best call, so a wrong decision teaches instead of confusing.
func reveal_category(catalog: MessageCatalog, chosen: String) -> void:
	if msg == null:
		return
	var best := String(msg.ideal).to_upper()
	var fair := chosen.to_upper() == best or (chosen in msg.alts)
	_chips.text = "%s  ·  best: %s%s" % [catalog.label(msg.category), best,
			"" if fair else "  (you: %s)" % chosen.to_upper()]
	_chips.add_theme_color_override("font_color", UI.TEXT_DIM if fair else UI.CORAL)


func _badge_color(badge: String) -> Color:
	match badge:
		"mod":
			return UI.MINT
		"vip":
			return UI.GOLD
		"sub":
			return UI.PINK
		_:
			return UI.TEXT_DIM


func _refresh_strikes(catalog: MessageCatalog) -> void:
	if msg == null:
		return
	var relevant := msg.strikes if catalog.escalates_at(msg.category) else msg.total_offenses
	if relevant <= 0:
		_strikes.text = ""
		_strikes.visible = false
		return
	_strikes.text = "! %d" % relevant
	_strikes.visible = true
	_strikes.add_theme_color_override("font_color",
			UI.CORAL if relevant >= 2 else UI.AMBER)


func leave_in_chat() -> void:
	set_focused(false)
	_timer.get_parent().visible = false
	_chips.text = ""
	_strikes.visible = false
	custom_minimum_size.y = 80
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_focused(v: bool) -> void:
	is_focused = v
	_style.bg_color = FOCUSED_BG if v else IDLE
	_style.border_width_left = 0 if not v else 4
	_style.border_width_right = 0 if not v else 4
	_style.border_width_top = 0 if not v else 4
	_style.border_width_bottom = 0 if not v else 4
	_style.border_color = UI.VIOLET if v else Color(0, 0, 0, 0)
	_style.shadow_size = 4 if v else 0
	_style.shadow_color = Color(UI.VIOLET, 0.45) if v else Color(0, 0, 0, 0.35)
	pivot_offset = size * 0.5
	scale = Vector2.ONE
	_intended_alpha = 1.0 if v else 0.92
	modulate = Color(1, 1, 1, _intended_alpha) if v else Color(0.86, 0.84, 0.95, _intended_alpha)


func update_timer() -> void:
	if msg == null:
		return
	var f := msg.fraction()
	_timer.value = f
	var col := UI.MINT
	if f < 0.28:
		col = UI.CORAL
	elif f < 0.6:
		col = UI.AMBER
	_timer_fill.bg_color = col
	_timer.visible = msg.lifetime > 0.0


## Pop-in / pop-out animation so the tray feels alive rather than a list.
var rest_x := 0.0
var born_ms := 0
## Unfocused rows are deliberately dimmed a little; settle() must restore that
## intended alpha rather than blasting everything to fully opaque.
var _intended_alpha := 1.0

## Slide-in only. Opacity deliberately stays at 1: a tween that never runs
## (paused tree, browser focus loss, node added before it was in the tree)
## used to leave the row fully transparent forever, i.e. an empty chat.
func animate_in() -> void:
	modulate.a = 1.0
	process_mode = Node.PROCESS_MODE_ALWAYS
	born_ms = Time.get_ticks_msec()
	rest_x = position.x
	if not is_inside_tree():
		return
	position.x -= 48.0
	var tw := create_tween()
	tw.tween_property(self, "position:x", rest_x, 0.18).set_trans(
			Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Safety net for the case where the tween is interrupted: never leave a row
## stuck off to the side or faded out.
func settle() -> void:
	if modulate.a < _intended_alpha - 0.01:
		modulate.a = _intended_alpha
	if absf(position.x - rest_x) > 1.0 and Time.get_ticks_msec() - born_ms > 400:
		position.x = rest_x


func animate_out(dir: float = 1.0) -> void:
	# Gone immediately; the fade is a bonus, not a requirement.
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "modulate:a", 0.0, 0.2)
	tw.tween_property(self, "position:x", position.x + 140.0 * dir, 0.22).set_trans(
			Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "custom_minimum_size", Vector2(0, 0), 0.22)
	tw.chain().tween_callback(queue_free)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		var pressed := false
		var pos := Vector2.ZERO
		if event is InputEventScreenTouch:
			pressed = event.pressed
			pos = event.position
		else:
			pressed = event.pressed
			pos = event.position
		if pressed:
			_press_pos = pos
			_press_time = float(Time.get_ticks_msec()) / 1000.0
		else:
			var moved := pos.distance_to(_press_pos)
			var held := float(Time.get_ticks_msec()) / 1000.0 - _press_time
			if moved < 44.0 and held < 0.9 and msg != null and msg.state == "pending":
				AudioManager.play("click", -6.0, 1.3)
				tapped.emit(msg.instance_id)
