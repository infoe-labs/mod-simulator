class_name GameScreen
extends Control

## The whole play session: the 3D desk behind, the streaming app aligned to
## the laptop display in front, and the moderation tray you actually touch.

const ROW_POOL := 10

var sim: Sim = null
var mode: String = "story"

var _bg: ColorRect
var _world_host: SubViewportContainer
var _world_vp: SubViewport
var _world: DeskWorld
var _stage_host: SubViewportContainer
var _stage_vp: SubViewport
var _stage: VTuberStage
var _frame: PanelContainer
var _frame_body: VBoxContainer
var _toast: Control
var _modal: Control

var _live_dot: Panel
var _title_label: Label
var _viewers_label: Label
var _source_chip: Label
## e2e/pilot only: jump the run's clock into a later phase (see with_params).
var _jump := 0.0
var _mood_label: Label
var _happy_bar: ProgressBar
var _happy_label: Label
var _trust_bar: ProgressBar
var _trust_label: Label
var _phase_label: Label
var _score_label: Label
var _combo_label: Label
var _tray_header: Label
var _tray: VBoxContainer
var _scroll: ScrollContainer
var _outer: VBoxContainer
var _flash_rect: ColorRect = null
var _split: HBoxContainer
var _split_active := false
var _idx_stage := -1
var _idx_scroll := -1
## Test seam: the layout audit pins a canvas size instead of relying on the
## (fixed) window size of a headless run.
var audit_canvas := Vector2.ZERO
var _bubble: PanelContainer
var _bubble_label: Label
var _hint: Label

var _btn_allow: Button
var _btn_delete: Button
var _btn_ban: Button
var _btn_next: Button
var _btn_pause: Button

var _rows := {}
var _last_total := -1
var _pitch := 0.9
var _quality := "high"
var _last_happy_shown := 50.0
var _last_trust_shown := 35.0
var _banner_tween: Tween
var _bubble_tween: Tween
var _paused := false
var _started := false
var _resume_existing := false


func with_params(params: Dictionary) -> void:
	mode = String(params.get("mode", "story"))
	_resume_existing = bool(params.get("resume", false))
	_jump = float(params.get("jump", 0.0))


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_quality = _detect_quality()
	_build_background()
	_build_world()
	_build_frame()
	_build_toasts()
	_build_modal()
	_begin()
	_layout()


# ------------------------------------------------------------------ build

func _detect_quality() -> String:
	if bool(SaveManager.setting("reduce_motion")):
		return "low"
	var screen := DisplayServer.screen_get_size()
	if OS.has_feature("Web") or OS.has_feature("Mobile") or OS.has_feature("Android") \
			or OS.has_feature("iOS"):
		if min(screen.x, screen.y) < 900:
			return "low"
	return "high"


func _build_background() -> void:
	_bg = ColorRect.new()
	_bg.color = UI.BG
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)


func _build_world() -> void:
	_world_host = SubViewportContainer.new()
	_world_host.stretch = true
	_world_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_world_host)

	_world_vp = SubViewport.new()
	_world_vp.own_world_3d = true
	_world_vp.transparent_bg = false
	_world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_world_vp.msaa_3d = Viewport.MSAA_DISABLED
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_world_host.add_child(_world_vp)

	_world = DeskWorld.new()
	_world.build(_quality)
	_world_vp.add_child(_world)


func _build_frame() -> void:
	_frame = UI.panel(UI.PANEL, 26, 16, UI.PANEL_LINE)
	_frame.z_index = 10
	# PASS, not STOP: the panel itself must never absorb a tap meant for a
	# button that is drawn on top of it.
	_frame.mouse_filter = Control.MOUSE_FILTER_PASS
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_frame)

	var outer := VBoxContainer.new()
	_outer = outer
	outer.add_theme_constant_override("separation", 10)
	_frame.add_child(outer)

	# ---- header ----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	outer.add_child(head)

	var live := UI.panel(UI.CORAL_DARK, 10, 8, UI.LIVE)
	live.custom_minimum_size = Vector2(0, 46)
	head.add_child(live)
	var live_row := HBoxContainer.new()
	live_row.add_theme_constant_override("separation", 8)
	live.add_child(live_row)
	_live_dot = Panel.new()
	_live_dot.custom_minimum_size = Vector2(20, 20)
	_live_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_live_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_sb := StyleBoxFlat.new()
	dot_sb.bg_color = UI.LIVE
	dot_sb.set_corner_radius_all(12)
	dot_sb.set_content_margin_all(0)
	_live_dot.add_theme_stylebox_override("panel", dot_sb)
	live_row.add_child(_live_dot)
	live_row.add_child(UI.label("LIVE", UI.FS_TINY, Color("ffe6ea")))

	# Honesty chip: who is writing tonight's chat. It reads the sim's own
	# counters, so it can only ever say AI once the model has really spoken.
	_source_chip = UI.label("SCRIPT", UI.FS_TINY, UI.TEXT_FAINT)
	_source_chip.custom_minimum_size = Vector2(0, 46)
	_source_chip.clip_text = true
	head.add_child(_source_chip)

	_title_label = UI.label("cozy stream <3", UI.FS_SMALL, UI.TEXT)
	_title_label.clip_text = true
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)

	_viewers_label = UI.label("VIEWERS 0", UI.FS_SMALL, UI.SKY)
	_viewers_label.custom_minimum_size = Vector2(110, 0)
	_viewers_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_viewers_label)

	_btn_pause = UI.icon_button("", "||")
	_btn_pause.focus_mode = Control.FOCUS_NONE
	_btn_pause.pressed.connect(_on_pause_pressed)
	head.add_child(_btn_pause)

	# ---- streamer identity + meters ----
	var meters := VBoxContainer.new()
	meters.add_theme_constant_override("separation", 6)
	outer.add_child(meters)

	var who := HBoxContainer.new()
	who.add_theme_constant_override("separation", 10)
	meters.add_child(who)
	who.add_child(UI.label("noriwave", UI.FS_SMALL, UI.PINK))
	_phase_label = UI.label("Warmup", UI.FS_TINY, UI.TEXT_DIM)
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.add_child(_phase_label)
	_mood_label = UI.label("", UI.FS_TINY, UI.TEXT_FAINT)
	who.add_child(_mood_label)
	_score_label = UI.label("0", UI.FS_SMALL, UI.GOLD)
	_score_label.custom_minimum_size = Vector2(120, 0)
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	who.add_child(_score_label)

	meters.add_child(_meter_row("MOOD", UI.MINT, true))
	meters.add_child(_meter_row("TRUST", UI.VIOLET, false))

	# ---- the streamer feed ----
	_stage_host = SubViewportContainer.new()
	_stage_host.stretch = true
	_stage_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage_host.custom_minimum_size = Vector2(0, 300)
	outer.add_child(_stage_host)

	_stage_vp = SubViewport.new()
	_stage_vp.own_world_3d = true
	_stage_vp.transparent_bg = false
	_stage_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_stage_vp.msaa_3d = Viewport.MSAA_DISABLED
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_stage_host.add_child(_stage_vp)

	var seed_v := int(GameState.pending_seed)
	var vr := SplitMix32.new(seed_v ^ 0x7E4B)
	_stage = VTuberStage.new(ProceduralVTuber.random_config(vr))
	_stage.set_quality(_quality)
	_stage_vp.add_child(_stage)

	_bubble = UI.panel(Color(UI.PANEL_LIGHT, 0.94), 18, 12, UI.PINK)
	_bubble.visible = false
	_bubble.z_index = 5
	add_child(_bubble)
	_bubble_label = UI.wrap_label("", UI.FS_SMALL, UI.TEXT)
	_bubble.add_child(_bubble_label)

	# ---- moderation tray ----
	_tray_header = UI.label("MODERATION TRAY", UI.FS_TINY, UI.TEXT_DIM)
	# The header text grows as the run goes on; never let it set the panel's
	# minimum width (that pushed the whole frame off a 720 px canvas).
	_tray_header.clip_text = true
	_tray_header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	outer.add_child(_tray_header)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	# The chat is the game: it must never be squeezed out of existence by the
	# feed and buttons sharing this column (a collapsed tray means no game).
	_scroll.custom_minimum_size = Vector2(0, 240)
	outer.add_child(_scroll)

	_tray = VBoxContainer.new()
	_tray.add_theme_constant_override("separation", 10)
	_tray.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_tray)

	# Landscape phones are short but wide: the feed moves beside the chat
	# instead of above it. Both live in a row that is swapped in on rotation.
	_split = HBoxContainer.new()
	_split.add_theme_constant_override("separation", 12)
	_idx_stage = _stage_host.get_index()
	_idx_scroll = _scroll.get_index()

	# ---- actions ----
	var hints := HBoxContainer.new()
	hints.add_theme_constant_override("separation", 10)
	outer.add_child(hints)
	_hint = UI.label("tap a message to pick it · 1 / 2 / 3 on a keyboard",
			UI.FS_TINY, UI.TEXT_FAINT)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Long helper text must never dictate the panel's minimum width.
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hints.add_child(_hint)
	_combo_label = UI.label("", UI.FS_TINY, UI.GOLD)
	_combo_label.clip_text = true
	_combo_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hints.add_child(_combo_label)
	_btn_next = UI.button(">  NEXT", UI.FS_SMALL)
	_btn_next.custom_minimum_size = Vector2(140, 82)
	_btn_next.focus_mode = Control.FOCUS_NONE
	_btn_next.pressed.connect(func(): sim.focus_next(); _refresh_focus())
	hints.add_child(_btn_next)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UI.BUTTON_GAP)
	outer.add_child(bar)
	_btn_allow = UI.tinted_button("ALLOW", UI.MINT, UI.MINT_DARK)
	_btn_delete = UI.tinted_button("DELETE", UI.AMBER, UI.AMBER_DARK)
	_btn_ban = UI.tinted_button("BAN", UI.CORAL, UI.CORAL_DARK)
	for b in [_btn_allow, _btn_delete, _btn_ban]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 124)
		bar.add_child(b)
	_btn_allow.pressed.connect(func(): _act("allow"))
	_btn_delete.pressed.connect(func(): _act("delete"))
	_btn_ban.pressed.connect(func(): _act("ban"))


func _meter_row(title: String, color: Color, is_happy: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var t := UI.label(title, UI.FS_TINY, UI.TEXT_DIM)
	t.custom_minimum_size = Vector2(78, 0)
	row.add_child(t)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 26)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("120e1b")
	bg.set_corner_radius_all(12)
	bg.set_content_margin_all(0)
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.border_color = UI.PANEL_LINE
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(12)
	fill.set_content_margin_all(0)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)
	var val := UI.label("50%", UI.FS_TINY, color)
	val.custom_minimum_size = Vector2(74, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	if is_happy:
		_happy_bar = bar
		_happy_label = val
	else:
		_trust_bar = bar
		_trust_label = val
	return row


func _build_toasts() -> void:
	_toast = Control.new()
	_toast.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.z_index = 20
	_toast.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_toast)


func _build_modal() -> void:
	_modal = Control.new()
	_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal.visible = false
	_modal.z_index = 40
	_modal.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_modal)


# ------------------------------------------------------------------- flow

func _begin() -> void:
	var seed_v := GameState.pending_seed
	if seed_v == 0:
		seed_v = int(Time.get_unix_time_from_system()) % 1000000
	# Coming back from Settings keeps the same run; otherwise start fresh.
	if _resume_existing and GameState.sim != null and not GameState.sim.is_over():
		sim = GameState.sim
		mode = sim.mode
	else:
		sim = GameState.begin_run(mode, seed_v)
	sim.spawned.connect(_on_spawned)
	sim.resolved.connect(_on_resolved)
	sim.expired.connect(_on_expired)
	sim.purged.connect(_on_purged)
	sim.meters.connect(_on_meters)
	sim.speech.connect(_on_speech)
	sim.phase_changed.connect(_on_phase_changed)
	sim.state_changed.connect(_on_state_changed)
	sim.trust_gated.connect(_on_trust_gated)
	sim.victory_locked.connect(_on_victory_locked)
	if not _resume_existing or sim.state == Sim.State.READY:
		sim.start()
		for m in sim.active:
			_on_spawned(m)
	_started = true
	_title_label.text = sim.title
	if _jump > 0.0 and sim.state == Sim.State.RUNNING:
		# The e2e pilot uses this to see the late-game phases without waiting
		# four minutes. It moves the clock, not the world: difficulty, spawn
		# cadence and the tier gate all read sim.elapsed.
		sim.elapsed = clampf(_jump, 0.0, sim.session_seconds - 0.5) if sim.session_seconds > 0.0 else _jump
		_jump = 0.0
	if GameState.ai != null:
		GameState.ai.stream_info = {"title": sim.title, "streamer": "Nori", "mode": sim.mode}
	_on_meters(sim.happiness, sim.trust)
	_refresh_focus()
	AudioManager.play_music("loop_cozy")
	AudioManager.play("open")


func _process(delta: float) -> void:
	if sim == null:
		return
	if sim.is_running():
		sim.tick(delta)
	# Smoothly-eased meters so the bar glides instead of jumping.
	_last_happy_shown = lerpf(_last_happy_shown, sim.happiness, clampf(delta * 6.0, 0.0, 1.0))
	_last_trust_shown = lerpf(_last_trust_shown, sim.trust, clampf(delta * 6.0, 0.0, 1.0))
	_happy_bar.value = _last_happy_shown
	_trust_bar.value = _last_trust_shown
	_happy_label.text = "%d%%" % int(round(sim.happiness))
	_trust_label.text = "%d%%" % int(round(sim.trust))
	var hc := UI.MINT
	if sim.happiness < 25.0:
		hc = UI.CORAL
	elif sim.happiness < 50.0:
		hc = UI.AMBER
	_happy_label.add_theme_color_override("font_color", hc)
	for id in _rows.keys():
		var row: ChatMessageRow = _rows[id]
		if row != null and is_instance_valid(row):
			row.update_timer()
			row.settle()
	_live_dot.modulate.a = 0.55 + 0.45 * absf(sin(Time.get_ticks_msec() * 0.003))
	if int(sim.stats["total"]) != _last_total:
		_last_total = int(sim.stats["total"])
		_viewers_label.text = "VIEWERS %s" % _fmt_count(sim.viewer_count)
	_update_tray_header()


func _fmt_count(n: int) -> String:
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)


func _act(action: String) -> void:
	if sim == null or _paused:
		return
	if sim.active.is_empty():
		AudioManager.play("error", -12.0)
		return
	var target := sim.focused()
	if target == null:
		return
	var res := sim.act(action)
	if res.is_empty() or bool(res.get("blocked", false)):
		return
	AudioManager.play({"allow": "allow", "delete": "delete", "ban": "ban"}.get(action, "click"))
	if not bool(res.get("correct", false)):
		AudioManager.play("error", -4.0)
		_haptics(60)
	elif int(res.get("points", 0)) > 260:
		AudioManager.play("combo")
		_haptics(25)
	_stage.say_for(1.1)
	var row: ChatMessageRow = _rows.get(target.instance_id)
	if row != null and is_instance_valid(row):
		_popup_over(row, res)
		_rows.erase(target.instance_id)
		match action:
			"allow":
				row.animate_out(-1.0)
			"delete":
				row.animate_out(1.0)
			"ban":
				row.animate_out(1.0)
	else:
		_popup_center(res)
	_flash(action, bool(res.get("correct", false)))
	_refresh_focus()


func _haptics(ms: int) -> void:
	if bool(SaveManager.setting("haptics")):
		Input.vibrate_handheld(ms, 0.7)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or _modal.visible:
		if _modal.visible and event.is_action_pressed("pause_game"):
			_resume()
		return
	if event.is_action_pressed("mod_allow"):
		_act("allow")
	elif event.is_action_pressed("mod_delete"):
		_act("delete")
	elif event.is_action_pressed("mod_ban"):
		_act("ban")
	elif event.is_action_pressed("mod_focus_next"):
		sim.focus_next()
		_refresh_focus()
	elif event.is_action_pressed("pause_game"):
		_pause()


# ------------------------------------------------------------------ signals

func _on_spawned(m: SimMessage) -> void:
	var row := ChatMessageRow.new()
	_tray.add_child(row)
	row.bind(m, ContentDB.cat())
	row.tapped.connect(_on_row_tapped)
	_rows[m.instance_id] = row
	row.animate_in()
	AudioManager.play("msg_new", -14.0, rng_pitch())
	if _rows.size() > ROW_POOL + 6:
		_trim_rows()


func rng_pitch() -> float:
	_pitch = 0.85 + float(_rows.size() % 5) * 0.06
	return _pitch


func _trim_rows() -> void:
	var keys := _rows.keys()
	while keys.size() > ROW_POOL:
		var k = keys.pop_front()
		var r: ChatMessageRow = _rows.get(k)
		_rows.erase(k)
		if r != null and is_instance_valid(r):
			r.queue_free()


func _on_row_tapped(instance_id: int) -> void:
	if sim.focus_message(instance_id):
		_refresh_focus()
		AudioManager.play("click", -10.0, 1.1)


func _on_resolved(m: SimMessage, res: Dictionary) -> void:
	var mood := String(res.get("mood", "neutral"))
	_stage.react(mood, 1.9)
	if bool(res.get("correct", false)):
		_stage.set_mood_from_happiness(sim.happiness)


func _on_expired(m: SimMessage, res: Dictionary) -> void:
	var row: ChatMessageRow = _rows.get(m.instance_id)
	if row != null and is_instance_valid(row):
		row.reveal_category(ContentDB.cat(), "nobody")
		_rows.erase(m.instance_id)
		row.animate_out(1.0)
	_stage.react(String(res.get("mood", "upset")), 2.4)
	_flash("expire", false)


func _on_purged(msgs: Array) -> void:
	for m in msgs:
		var row: ChatMessageRow = _rows.get(m.instance_id)
		_rows.erase(m.instance_id)
		if row != null and is_instance_valid(row):
			row.reveal_category(ContentDB.cat(), "purged")
			row.animate_out(1.0)


func _on_meters(h: float, t: float) -> void:
	_world.set_pressure(1.0 - clampf(h / 100.0, 0.0, 1.0))
	var tint := Color("8fb7ff")
	if h >= 80.0:
		tint = Color("ffc0e0")
	elif h <= 30.0:
		tint = Color("6a5a8a")
	_world.set_screen_tint(tint, lerpf(0.8, 1.5, h / 100.0))
	_stage.set_mood_from_happiness(h)


func _on_speech(text: String, mood: String) -> void:
	_stage.react(mood, 2.4)
	if mood in ["happy", "excited", "laughing"]:
		_stage.react(mood, 1.6)
	_show_bubble(text)
	if mood in ["excited", "laughing"]:
		AudioManager.play("heart", -8.0)


func _on_phase_changed(index: int, phase: Dictionary) -> void:
	_phase_label.text = String(phase.get("label", "…"))
	_banner(String(phase.get("label", "")).to_upper(), UI.VIOLET)
	AudioManager.play("phase")
	if index >= 3:
		AudioManager.play_music("loop_tense")
	# Give the model a chance to have something to say about the moment; the
	# lines it writes queue up and may replace the next scripted streamer line.
	if GameState.ai != null:
		GameState.ai.request_reaction("the stream just entered the %s phase" % String(phase.get("label", "busy")))


func _on_state_changed(next: int) -> void:
	match next:
		Sim.State.WON:
			_finish()
		Sim.State.LOST:
			_finish()
		Sim.State.COMPLETE:
			_finish()


func _on_trust_gated(need: float) -> void:
	_banner("SHE LIKES YOU - BUT DOES SHE TRUST YOU?  (%d%% NEEDED)" % int(need), UI.PINK)


func _on_victory_locked() -> void:
	_banner("SHE'S BEAMING - HOLD IT UNTIL THE STREAM ENDS", UI.GOLD)


# ------------------------------------------------------------------ juice

func _refresh_focus() -> void:
	for id in _rows.keys():
		var row: ChatMessageRow = _rows[id]
		if row != null and is_instance_valid(row):
			row.set_focused(sim != null and sim.focus_id == int(id))
	_update_tray_header()


func _update_tray_header() -> void:
	if sim == null:
		return
	var waiting := sim.active.size()
	var handled := int(sim.stats["handled"])
	var extra := ""
	if waiting > 1:
		extra = "  ·  %d WAITING - OLDEST FIRST" % waiting
	_tray_header.text = "MODERATION TRAY  ·  %d moderated%s" % [handled, extra]
	_tray_header.add_theme_color_override("font_color",
			UI.CORAL if waiting >= 3 else UI.TEXT_DIM)
	_update_source_chip()


## The header chip mirrors the sim's counters, never a hope or a setting: it
## says AI only once the model has really written the majority of the chat.
func _update_source_chip() -> void:
	if _source_chip == null:
		return
	var manager := GameState.ai
	var src := sim.chat_source()
	var text := "SCRIPT"
	var color := UI.TEXT_FAINT
	if src == "ai":
		text = "AI CHAT"
		color = UI.MINT
	elif src == "mixed":
		text = "AI + SCRIPT"
		color = UI.AMBER
	elif manager != null and manager.enabled and not manager.ready_flag:
		# Asked for AI, still waiting on the model: say so instead of lying.
		text = "AI WARMING UP"
		color = UI.AMBER
	elif manager != null and manager.enabled and manager.last_error != "":
		text = "AI OFFLINE"
		color = UI.AMBER
	_source_chip.text = text
	_source_chip.add_theme_color_override("font_color", color)


func _popup_over(row: ChatMessageRow, res: Dictionary) -> void:
	var global_pos := row.get_global_transform_with_canvas().origin + Vector2(30, 0)
	# Only now - the decision is locked in - do we name the category and the
	# best call. Before this the row deliberately withholds the verdict.
	row.reveal_category(ContentDB.cat(), String(res.get("action", "")))
	_spawn_popup(global_pos, res)


## The panel's rect, with a canvas-derived fallback: before the first layout
## pass (or when a signal fires during _ready) `_frame.size` is still 0, and
## anything that sized itself from it collapsed to one character per line.
func _frame_rect() -> Rect2:
	var r := Rect2(_frame.position, _frame.size)
	if r.size.x > 40.0 and r.size.y > 40.0:
		return r
	var c := size
	if c.x <= 1.0 or c.y <= 1.0:
		c = get_viewport_rect().size
	if c.x <= 1.0:
		c = Vector2(720.0, 1280.0)
	return Rect2(Vector2(c.x * 0.06, c.y * 0.06), Vector2(c.x * 0.88, c.y * 0.88))


func _popup_center(res: Dictionary) -> void:
	var r := _frame_rect()
	_spawn_popup(r.position + r.size * Vector2(0.06, 0.34), res)


func _spawn_popup(at: Vector2, res: Dictionary) -> void:
	var correct := bool(res.get("correct", false))
	var exact := bool(res.get("exact", false))
	var verdict := String(res.get("verdict", ""))
	var pts := int(res.get("points", 0))
	var main := "+%d  %s" % [pts, verdict] if correct else verdict
	var col := UI.MINT
	if not correct:
		col = UI.CORAL
	elif not exact:
		col = UI.AMBER
	var r := _frame_rect()
	var w: float = clampf(r.size.x * 0.8, 240.0, 460.0)
	var card := UI.panel(Color(UI.PANEL, 0.96), 18, 14, col)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.z_index = 25
	card.custom_minimum_size = Vector2(w, 0)
	var text_w: float = maxf(120.0, w - 28.0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	card.add_child(box)
	var l := UI.wrap_label(main, UI.FS_SECTION, col)
	l.custom_minimum_size = Vector2(text_w, 0)
	box.add_child(l)
	var sub := UI.wrap_label(ModerationEngine.feedback_line(res), UI.FS_SMALL, UI.TEXT)
	sub.custom_minimum_size = Vector2(text_w, 0)
	box.add_child(sub)
	# The teaching line: what it actually was, and what the best call was.
	var m: SimMessage = res.get("message", null)
	if m != null:
		var was := UI.wrap_label("was  %s   ·   best  %s" % [
				ContentDB.cat().label(m.category), String(m.ideal).to_upper()],
				UI.FS_TINY, UI.TEXT_FAINT)
		was.custom_minimum_size = Vector2(text_w, 0)
		box.add_child(was)
	card.position = Vector2(
			clampf(at.x, r.position.x + 8.0, maxf(r.position.x + 8.0, r.end.x - w - 8.0)),
			clampf(at.y, r.position.y + 60.0, maxf(r.position.y + 60.0, r.end.y - 240.0)))
	_toast.add_child(card)
	# Start fully visible: if the tween never runs (paused tree, backgrounded
	# tab) the feedback still shows and then gets cleaned up below.
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(card, "position:y", card.position.y - 90.0, 0.9).set_trans(
			Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "modulate:a", 0.0, 0.9).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func():
		if is_instance_valid(card):
			card.queue_free())
	# Failsafe cleanup if the tween is interrupted by a pause.
	get_tree().create_timer(2.0).timeout.connect(func():
		if is_instance_valid(card):
			card.queue_free())


func _flash(kind: String, correct: bool) -> void:
	if _quality == "low":
		return
	var c := ColorRect.new()
	c.color = Color(UI.MINT, 0.0)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.z_index = 30
	add_child(c)
	# One flash at a time: a stalled tween used to leave full-screen tints
	# stacked over the whole UI, which dimmed the chat into unreadability.
	if _flash_rect != null and is_instance_valid(_flash_rect):
		_flash_rect.get_parent().remove_child(_flash_rect)
		_flash_rect.queue_free()
	_flash_rect = c
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var target := Color(UI.MINT, 0.16)
	match kind:
		"ban":
			target = Color(UI.CORAL, 0.18)
		"delete":
			target = Color(UI.AMBER, 0.14)
		"expire":
			target = Color(UI.CORAL, 0.2)
	if not correct and kind != "expire":
		target = Color(UI.CORAL, 0.16)
	var tw := create_tween()
	tw.tween_property(c, "color", target, 0.08)
	tw.tween_property(c, "color:a", 0.0, 0.4)
	tw.tween_callback(c.queue_free)
	# Failsafe: if the tween never finishes (tab backgrounded, tree paused),
	# the tint must still disappear.
	get_tree().create_timer(0.8).timeout.connect(func():
		if is_instance_valid(c):
			c.visible = false
			c.queue_free())


func _banner(text: String, color: Color) -> void:
	var b := UI.label(text, UI.FS_SMALL, color)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var fr := _frame_rect()
	b.custom_minimum_size = Vector2(fr.size.x * 0.9, 0)
	b.position = fr.position + Vector2(fr.size.x * 0.05, fr.size.y * 0.26)
	b.z_index = 32
	b.modulate.a = 0.0
	_toast.add_child(b)
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(b, "modulate:a", 1.0, 0.18)
	_banner_tween.tween_interval(1.5)
	_banner_tween.tween_property(b, "modulate:a", 0.0, 0.5)
	_banner_tween.tween_callback(b.queue_free)


func _show_bubble(text: String) -> void:
	_bubble_label.text = text
	_bubble.visible = true
	_layout_bubble()
	_bubble.modulate.a = 0.0
	_bubble.scale = Vector2(0.85, 0.85)
	_bubble.pivot_offset = _bubble.size * 0.5
	if _bubble_tween != null and _bubble_tween.is_valid():
		_bubble_tween.kill()
	_bubble_tween = create_tween()
	_bubble_tween.set_parallel(true)
	_bubble_tween.tween_property(_bubble, "modulate:a", 1.0, 0.14)
	_bubble_tween.tween_property(_bubble, "scale", Vector2.ONE, 0.2).set_trans(
			Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_bubble_tween.chain().tween_interval(2.6)
	_bubble_tween.tween_property(_bubble, "modulate:a", 0.0, 0.4)
	_bubble_tween.tween_callback(func(): _bubble.visible = false)
	_stage.say_for(minf(2.6, 0.35 + float(text.length()) * 0.035))


func _layout_bubble() -> void:
	var fr := _frame_rect()
	var w := clampf(fr.size.x * 0.72, 240.0, 520.0)
	# An autowrapping Label has a minimum width of one character, so reset_size()
	# alone collapsed the bubble into a very tall one-word-per-line column. Give
	# the label the wrap width as its minimum first; then the panel sizes to it.
	_bubble_label.custom_minimum_size = Vector2(maxf(120.0, w - 32.0), 0)
	_bubble.custom_minimum_size = Vector2(w, 0)
	_bubble.size = Vector2(w, 0)
	_bubble.reset_size()
	_bubble.position = fr.position + Vector2(fr.size.x - w - 18,
			fr.size.y * 0.30)


# ------------------------------------------------------------------- pause

func _on_pause_pressed() -> void:
	if _paused:
		_resume()
	else:
		_pause()


func auto_pause() -> void:
	if sim != null and sim.is_running():
		_pause()


func _pause() -> void:
	if _paused:
		return
	_paused = true
	sim.pause()
	AudioManager.play("back")
	_rebuild_modal(false)


func _resume() -> void:
	if not _paused:
		return
	_paused = false
	_modal.visible = false
	sim.resume()
	AudioManager.play("click")


func _finish() -> void:
	if not _started:
		return
	_started = false
	AudioManager.stop_music()
	GameState.finish_run()
	var summary: Dictionary = GameState.last_summary
	if String(summary.get("outcome", "")) == "win":
		Main.goto("res://scenes/Ending.tscn", {"vtuber": _stage.config() if _stage != null else {}})
	else:
		Main.goto("res://scenes/Results.tscn", {})


func _rebuild_modal(from_start: bool) -> void:
	for c in _modal.get_children():
		c.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.06, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The dimmer must never eat the taps that belong to the buttons above it.
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal.add_child(dim)
	_modal.visible = true
	_modal.move_to_front()

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal.add_child(center)
	var panel := UI.panel(UI.PANEL, 24, 26, UI.PANEL_LINE)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(v)
	# One width for every row: the panel must never be wider than the canvas,
	# or the buttons below end up off the edge of the screen.
	var row_w: float = clampf(_frame_rect().size.x * 0.8 - 52.0, 220.0, 520.0)
	var title := UI.label("PAUSED" if not from_start else "READY?", UI.FS_TITLE, UI.TEXT)
	title.custom_minimum_size = Vector2(row_w, 0)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(title)
	var s := UI.label("Take a breath. Chat waits for you.", UI.FS_SMALL, UI.TEXT_DIM)
	# Width from the canvas, never from a container that has no size yet: a
	# 0-width wrap turns the panel into a one-word-per-line column and pushes
	# the buttons off the bottom of the screen.
	var text_w: float = clampf(_frame_rect().size.x * 0.72, 240.0, 520.0)
	s.custom_minimum_size = Vector2(row_w, 0)
	s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(s)
	if sim != null:
		var stats := UI.label("score %d   ·   mood %d%%   ·   trust %d%%   ·   moderated %d" % [
			sim.score, int(sim.happiness), int(sim.trust), int(sim.stats["handled"])],
				UI.FS_SMALL, UI.TEXT_DIM)
		stats.custom_minimum_size = Vector2(row_w, 0)
		stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(stats)
	var resume := UI.tinted_button("RESUME", UI.MINT, UI.MINT_DARK)
	resume.custom_minimum_size = Vector2(row_w, 110)
	resume.pressed.connect(_resume)
	v.add_child(resume)
	var settings := UI.button("SETTINGS", UI.FS_BODY)
	settings.custom_minimum_size = Vector2(row_w, UI.MIN_TAP)
	settings.pressed.connect(func():
		AudioManager.play("click")
		Main.goto("res://scenes/Settings.tscn", {"return_to": "game"}))
	v.add_child(settings)
	var quit := UI.button("END THE STREAM", UI.FS_BODY)
	quit.custom_minimum_size = Vector2(row_w, UI.MIN_TAP)
	quit.pressed.connect(func():
		AudioManager.play("back")
		_started = false
		GameState.finish_run()
		Main.goto("res://scenes/MainMenu.tscn"))
	v.add_child(quit)


# ------------------------------------------------------------------ layout

func _layout() -> void:
	if not is_inside_tree():
		return
	var canvas := size
	if audit_canvas.x > 1.0 and audit_canvas.y > 1.0:
		canvas = audit_canvas
	if canvas.x <= 1.0 or canvas.y <= 1.0:
		canvas = get_viewport_rect().size
	var portrait := canvas.x < canvas.y

	# Render the 3D world at a fraction of the canvas: chunky pixels, cheap.
	var scale := 0.5 if (_quality == "low" or portrait) else 0.62
	var vw := maxi(160, int(canvas.x * scale))
	var vh := maxi(160, int(canvas.y * scale))
	# The SubViewportContainer (stretch = true) owns the viewport pixel size.
	_world.fit_canvas(Vector2(vw, vh))

	# Usable area: the canvas minus the notch/cutout insets and a small margin.
	var margin := 10.0
	var safe_top: float = Main.safe["top"]
	var safe_bottom: float = Main.safe["bottom"]
	var safe_left: float = Main.safe["left"]
	var safe_right: float = Main.safe["right"]
	var bounds := Rect2(safe_left + margin, safe_top + margin,
			canvas.x - (safe_left + safe_right) - margin * 2.0,
			canvas.y - (safe_top + safe_bottom) - margin * 2.0)

	# The panel that holds meters, chat and buttons is laid out against the
	# safe area, not against the projected laptop display. Aligning it to the 3D
	# screen looked nice and made the geometry fragile on short windows (chat
	# rows falling off the bottom of the screen). The world stays behind it and
	# the streamer feed inside it, so the desk still reads as one scene.
	var aligned := bounds
	if not portrait:
		# Landscape: keep the panel narrow enough that the room shows either side.
		var w: float = minf(bounds.size.x, maxf(420.0, bounds.size.y * 0.92))
		aligned = Rect2(bounds.position.x + (bounds.size.x - w) * 0.5,
				bounds.position.y, w, bounds.size.y)

	_frame.position = aligned.position
	_frame.size = aligned.size

	# Landscape phones are short: spend the vertical space on the chat, not on
	# chrome. Everything here is reachable either way (keyboard hints are also
	# on screen in portrait, and the actions have no hover-only affordance).
	var btn_h := 124.0
	if not portrait:
		btn_h = 96.0
	# On a narrow phone the three labels alone are wider than the window; drop
	# the type size and the button padding until the row genuinely fits.
	var act_font := UI.FS_BODY
	if bounds.size.x < 620.0:
		act_font = UI.FS_TINY + 4
	for b in [_btn_allow, _btn_delete, _btn_ban]:
		b.custom_minimum_size.y = btn_h
		b.add_theme_font_size_override("font_size", act_font)
		# A Button's minimum width is its label; allow it to shrink (with an
		# ellipsis) so a narrow phone cannot push the row off screen.
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var sb := b.get_theme_stylebox("normal") as StyleBoxFlat
		if sb != null:
			sb.content_margin_left = 4 if act_font < UI.FS_BODY else 10
			sb.content_margin_right = 4 if act_font < UI.FS_BODY else 10
	_hint.visible = portrait
	_tray_header.visible = portrait

	# Split whatever the header, meters and buttons leave between the streamer
	# feed and the chat. Hard-coded minimums here are what once let the tray
	# collapse to nothing on a short window, so the split is derived from the
	# space that is really available: measure the panel with the two flexible
	# parts at zero, then hand out what is left.
	# Priority when space is short: chat > buttons > meters > 3D feed.
	_ensure_split(not portrait)
	if _split_active:
		# Side by side: the feed costs width, not height. The row still needs an
		# explicit height or the containers collapse it to nothing.
		var other: float = _frame.get_combined_minimum_size().y
		var row_h: float = maxf(220.0, aligned.size.y - other + _split.get_combined_minimum_size().y)
		_stage_host.custom_minimum_size = Vector2.ZERO
		_scroll.custom_minimum_size = Vector2(0, row_h)
		_split.custom_minimum_size = Vector2(0, row_h)
		_stage_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_stage_host.size_flags_stretch_ratio = 0.85
		_scroll.size_flags_stretch_ratio = 1.15
		var feed_w: float = maxf(160.0, aligned.size.x * 0.34)
		_stage_host.custom_minimum_size = Vector2(feed_w, 0)
		_scroll.custom_minimum_size = Vector2(210.0, 0)
		_stage_host.visible = true
		var feed_room: float = _frame.get_combined_minimum_size().y
		_stage.fit(aligned.size.x / maxf(1.0, maxf(120.0, aligned.size.y - feed_room + 200.0)))
		_layout_bubble()
		_refresh_focus()
		_frame.position = aligned.position
		_frame.size = aligned.size
		return
	_stage_host.custom_minimum_size = Vector2(0, 0)
	_scroll.custom_minimum_size = Vector2(0, 0)
	var chrome: float = _frame.get_combined_minimum_size().y
	var room: float = maxf(0.0, aligned.size.y - chrome)
	var feed_h: float = clampf(room * (0.40 if portrait else 0.46), 0.0, 360.0)
	if room < 260.0:
		feed_h = 0.0
	var scroll_h: float = maxf(0.0, room - feed_h)
	if scroll_h < 168.0 and room >= 168.0:
		scroll_h = 168.0
	_stage_host.custom_minimum_size = Vector2(0, feed_h)
	_scroll.custom_minimum_size = Vector2(0, scroll_h)
	# A feed thinner than a thumbnail is worse than no feed.
	_stage_host.visible = feed_h >= 100.0
	# The SubViewportContainer (stretch = true) owns the viewport size.
	_stage.fit(aligned.size.x / maxf(1.0, feed_h))
	# Last, because reset_size() in the fit pass above can grow the panel back
	# to its content minimum: the frame must end up exactly inside the bounds.
	_frame.position = aligned.position
	_frame.size = aligned.size
	_layout_bubble()
	_refresh_focus()


## Move the feed and the tray between the stacked portrait column and the
## side-by-side landscape row.
func _ensure_split(want_split: bool) -> void:
	if want_split == _split_active:
		return
	if want_split:
		_outer.add_child(_split)
		_outer.move_child(_split, _idx_stage)
		_stage_host.reparent(_split, false)
		_scroll.reparent(_split, false)
	else:
		# reparent() unlinks from the row first; add_child() would fail because
		# the node still has a parent.
		_stage_host.reparent(_outer, false)
		_outer.move_child(_stage_host, _idx_stage)
		_scroll.reparent(_outer, false)
		_outer.move_child(_scroll, _idx_scroll)
		if _split.get_parent() != null:
			_split.get_parent().remove_child(_split)
	_split_active = want_split


func _projected_screen_rect(vp_size: Vector2, canvas: Vector2) -> Rect2:
	if _world == null or _world.camera == null or _world.screen_mesh == null:
		return Rect2()
	var cam := _world.camera
	var pts := PackedVector2Array()
	for c in _world.screen_corners():
		pts.append(cam.unproject_position(c))
	if pts.size() != 4:
		return Rect2()
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	var k := canvas / Vector2(maxf(1.0, vp_size.x), maxf(1.0, vp_size.y))
	return Rect2(r.position * k, r.size * k)


func _fallback_rect(canvas: Vector2, portrait: bool, bounds: Rect2) -> Rect2:
	if portrait:
		var w := canvas.x * 0.94
		var h := canvas.y * 0.78
		return Rect2((canvas.x - w) * 0.5, bounds.position.y + (bounds.size.y - h) * 0.42, w, h)
	var w2 := minf(canvas.x * 0.66, canvas.y * 1.35)
	var h2 := canvas.y * 0.86
	return Rect2((canvas.x - w2) * 0.5, bounds.position.y + (bounds.size.y - h2) * 0.5, w2, h2)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		call_deferred("_layout")
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		auto_pause()
