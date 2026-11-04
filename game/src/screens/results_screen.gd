class_name ResultsScreen
extends Control

## The morning-after card: what happened, what it cost her, and one honest
## note about what to do differently.

var _summary: Dictionary = {}


func with_params(params: Dictionary) -> void:
	_summary = params.get("summary", GameState.last_summary)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _summary.is_empty():
		_summary = GameState.last_summary
	if _summary.is_empty():
		_summary = {"outcome": "aborted", "score": 0, "happiness": 0.0, "trust": 0.0,
				"accuracy": 0.0, "mode": "story", "total_messages": 0, "time": 0.0,
				"correct": 0, "partial": 0, "wrong": 0, "expired": 0, "bans": 0,
				"deletes": 0, "allows": 0, "innocent_bans": 0, "abuses_allowed": 0,
				"serious_missed": 0, "best_combo": 0, "title": "", "trust_needed": 82.0}
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var outcome := String(_summary.get("outcome", "complete"))
	var accent := UI.AMBER
	var headline := "THE STREAM ENDED"
	var sub := "She logged off thinking about it."
	if outcome == "win":
		accent = UI.MINT
		headline = "BEST STREAM EVER"
		sub = "Nori is waiting for you in DMs."
	elif outcome == "lose":
		accent = UI.CORAL
		headline = "SHE ENDED THE STREAM"
		sub = "\"I can't read chat right now.\""
	elif outcome == "aborted":
		accent = UI.TEXT_DIM
		headline = "STREAM ENDED EARLY"
		sub = "You left mid-night. She'll be back tomorrow."

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	scroll.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	var kick := UI.label("NIGHT REPORT  ·  %s" % ContentDB.mode_label(String(_summary.get("mode", "story"))).to_upper(),
			UI.FS_TINY, accent)
	root.add_child(kick)
	var h := UI.label(headline, UI.FS_BIG, UI.TEXT)
	h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(h)
	root.add_child(UI.label(sub, UI.FS_BODY, UI.TEXT_DIM))

	root.add_child(_stat_card())
	root.add_child(_advice_card())

	var again := UI.tinted_button("MODERATE AGAIN", UI.MINT, UI.MINT_DARK, UI.FS_BODY + 6)
	again.custom_minimum_size = Vector2(0, 124)
	again.pressed.connect(func():
		AudioManager.play("open")
		var m := String(_summary.get("mode", "story"))
		GameState.pending_mode = m
		GameState.pending_seed = int(Time.get_unix_time_from_system()) % 1000000
		Main.goto("res://scenes/Game.tscn", {"mode": m}))
	root.add_child(again)

	var menu := UI.button("BACK TO THE DESK", UI.FS_BODY)
	menu.custom_minimum_size.y = UI.MIN_TAP
	menu.pressed.connect(func():
		AudioManager.play("back")
		Main.goto("res://scenes/MainMenu.tscn"))
	root.add_child(menu)


func _stat_card() -> Control:
	var p := UI.panel(UI.PANEL, 20, 18, UI.PANEL_LINE)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	v.add_child(UI.label("THE NUMBERS", UI.FS_TINY, UI.TEXT_DIM))

	v.add_child(_big_row("SCORE", int(_summary.get("score", 0)), UI.GOLD))
	v.add_child(_meter_line("MOOD", float(_summary.get("happiness", 0.0)), UI.MINT))
	v.add_child(_meter_line("TRUST", float(_summary.get("trust", 0.0)), UI.VIOLET))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 6)
	v.add_child(grid)
	var rows := [
		["correct calls", int(_summary.get("correct", 0))],
		["acceptable", int(_summary.get("partial", 0))],
		["wrong calls", int(_summary.get("wrong", 0))],
		["missed entirely", int(_summary.get("expired", 0))],
		["serious abuse left up", int(_summary.get("serious_missed", 0))],
		["innocent bans", int(_summary.get("innocent_bans", 0))],
		["bans handed out", int(_summary.get("bans", 0))],
		["best combo", int(_summary.get("best_combo", 0))],
	]
	for r in rows:
		grid.add_child(UI.label(String(r[0]), UI.FS_SMALL, UI.TEXT_DIM))
		var l := UI.label(str(r[1]), UI.FS_SMALL, UI.TEXT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(l)
	# Say who wrote tonight's chat. If the model never took over, this says so.
	var ai_n := int(_summary.get("ai_messages", 0))
	var classic_n := int(_summary.get("classic_messages", 0))
	var src := String(_summary.get("chat_source", "classic"))
	var src_text := "authored script"
	var src_color: Color = UI.TEXT_FAINT
	if src == "ai":
		src_text = "AI on this device"
		src_color = UI.MINT
	elif src == "mixed":
		src_text = "AI %d · script %d" % [ai_n, classic_n]
		src_color = UI.AMBER
	grid.add_child(UI.label("chat written by", UI.FS_SMALL, UI.TEXT_DIM))
	var src_label := UI.label(src_text, UI.FS_SMALL, src_color)
	src_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grid.add_child(src_label)
	var acc := UI.label("accuracy  %d%%" % int(round(float(_summary.get("accuracy", 0.0)) * 100.0)),
			UI.FS_SMALL, UI.TEXT_DIM)
	v.add_child(acc)
	var best := "best ever  %s" % _fmt_int(SaveManager.profile.best_score)
	v.add_child(UI.label(best, UI.FS_TINY, UI.TEXT_FAINT))
	return p


func _big_row(label_text: String, value: int, color: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(UI.label(label_text, UI.FS_SMALL, UI.TEXT_DIM))
	row.add_child(UI.vspacer(2))
	var v := UI.label(_fmt_int(value), UI.FS_TITLE, color)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	return row


func _meter_line(label_text: String, value: float, color: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UI.label(label_text, UI.FS_SMALL, UI.TEXT_DIM)
	l.custom_minimum_size = Vector2(84, 0)
	row.add_child(l)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 22)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("120e1b")
	bg.set_corner_radius_all(10)
	bg.set_content_margin_all(0)
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(10)
	fill.set_content_margin_all(0)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)
	var v := UI.label("%d%%" % int(round(value)), UI.FS_SMALL, color)
	v.custom_minimum_size = Vector2(74, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	return row


func _advice_card() -> Control:
	var p := UI.panel(UI.PANEL, 20, 18, UI.PANEL_LINE)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	v.add_child(UI.label("WHAT WOULD HAVE HELPED", UI.FS_TINY, UI.TEXT_DIM))
	for line in _advice():
		v.add_child(UI.wrap_label("- " + line, UI.FS_SMALL, UI.TEXT))
	return p


func _advice() -> Array:
	var out: Array = []
	var need := float(_summary.get("trust_needed", 82.0))
	if int(_summary.get("innocent_bans", 0)) > 0:
		out.append("You banned %d viewer(s) who'd done nothing. Check the strike badge before you ban."
				% int(_summary.get("innocent_bans", 0)))
	if int(_summary.get("abuses_allowed", 0)) > 1:
		out.append("%d rude messages stayed up. She reads every one of them."
				% int(_summary.get("abuses_allowed", 0)))
	if int(_summary.get("serious_missed", 0)) > 0:
		out.append("%d serious message(s) timed out unanswered. Those hurt her most - clear them first."
				% int(_summary.get("serious_missed", 0)))
	if int(_summary.get("expired", 0)) > 6:
		out.append("A lot of chat scrolled away. Tap the oldest card and answer fast; DELETE on clutter is fine.")
	if float(_summary.get("trust", 0.0)) < need:
		out.append("Trust is earned by the hard calls: deletions and bans on real abuse, not by letting friendly chat through.")
	if int(_summary.get("bans", 0)) == 0 and int(_summary.get("total_messages", 0)) > 40:
		out.append("You never banned anyone. Some viewers do it on purpose - the strike count tells you when.")
	if out.is_empty():
		out.append("Genuinely clean moderation. Nothing to fix, mod.")
	return out


func _fmt_int(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out
