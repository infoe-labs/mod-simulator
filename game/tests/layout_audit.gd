extends SceneTree

## Layout audit:  godot --headless --path game -s res://tests/layout_audit.gd
##
## Builds the real screens at the reference resolution and a couple of awkward
## device shapes, then asserts the parts the player must be able to see and hit
## actually have non-zero, in-bounds geometry. The chat tray collapsing to zero
## height (invisible chat) is the regression this exists to catch.

var failures := 0


func _initialize() -> void:
	print("── layout audit ──")
	await process_frame
	for size in [Vector2(720, 1280), Vector2(720, 1420), Vector2(1280, 720), Vector2(500, 1080)]:
		await _audit_game(size)
	await _audit_menu(Vector2(720, 1280))
	print("── %s ──" % ("LAYOUT OK" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok  %s" % label)
	else:
		failures += 1
		printerr(" FAIL %s" % label)


func _audit_game(canvas: Vector2) -> void:
	var game = load("res://scenes/Game.tscn").instantiate()
	game.audit_canvas = canvas
	# A script that fails to compile silently degrades to a bare Control, which
	# would otherwise "pass" every geometry check by having no children at all.
	if not game.has_method("with_params"):
		_check(false, "game screen script compiled (no with_params)")
		game.free()
		return
	game.call("with_params", {"mode": "story"})
	get_root().add_child(game)
	# Pin the screen to the canvas we are testing: an anchored Control would
	# otherwise keep reporting the (headless, fixed) window size.
	game.call("_layout")
	for i in 8:
		await process_frame
	var sim = game.sim
	# Guarantee a full tray regardless of spawn timing.
	sim.elapsed = 150.0
	for i in 10:
		sim._try_spawn()
	game.size = canvas
	for i in 12:
		await process_frame	# let the slide-in tweens and settle() run
	game.call("_layout")

	var scroll = game._scroll
	var tray = game._tray
	var rows = game._rows
	print("  [%dx%d] screen size=%s frame=%s@%s frame_min_h=%.0f feed_min=%.0f scroll_min=%.0f" % [
			canvas.x, canvas.y, game.size, game._frame.size, game._frame.position,
			game._frame.get_combined_minimum_size().y,
			game._stage_host.custom_minimum_size.y, game._scroll.custom_minimum_size.y])
	_check(scroll.size.x > 200, "    chat scroll width %d" % scroll.size.x)
	_check(scroll.size.y >= 200, "    chat scroll height %d (never collapses)" % scroll.size.y)
	_check(tray.size.x > 200, "    tray width %d" % tray.size.x)
	_check(not rows.is_empty(), "    %d rows present" % rows.size())

	var visible_rows := 0
	var min_row_h := 1e9
	for id in rows.keys():
		var row = rows[id]
		if row != null and is_instance_valid(row) and row.visible and row.size.x > 100 and row.size.y >= 60:
			visible_rows += 1
			min_row_h = minf(min_row_h, row.size.y)
		elif row != null and is_instance_valid(row):
			print("      (row %dx%d at %s, visible=%s)" % [row.size.x, row.size.y, row.global_position, row.visible])
	_check(visible_rows >= 3, "    %d rows rendered with real size" % visible_rows)
	# "Exists but invisible" is the failure mode that hid the whole chat once:
	# a row faded to zero alpha looks identical to an empty tray.
	var faded := 0
	var offscreen := 0
	for id in rows.keys():
		var r = rows[id]
		if r == null or not is_instance_valid(r) or not r.visible:
			continue	# an exiting row is allowed to be mid-fade
		if r.modulate.a < 0.15:
			faded += 1	# a fully transparent row reads as "no chat at all"
		if absf(r.position.x - r.rest_x) > 2.0:
			offscreen += 1
	_check(faded == 0, "    no row left transparent (faded=%d)" % faded)
	_check(offscreen == 0, "    no row stuck off-position (offset=%d)" % offscreen)
	var widest := 0.0
	var who := ""
	var widest_node: Control = null
	for c in _all_controls(game._frame):
		if c.get_combined_minimum_size().x > widest:
			widest = c.get_combined_minimum_size().x
			who = String(c.name)
			widest_node = c
	if game._frame.size.x > canvas.x + 1.0:
		var kids := _all_controls(widest_node)
		var parts: Array = []
		for k in kids:
			parts.append("%s%.0fx%.0f" % [String(k.name).left(12),
					k.get_combined_minimum_size().x, k.get_combined_minimum_size().y])
		print("      widest subtree: ", " | ".join(parts))
	_check(game._frame.size.x <= canvas.x + 1.0,
			"    panel inside the canvas (w=%.0f, widest child %s=%.0f)" % [game._frame.size.x, who, widest])
	if visible_rows > 0:
		_check(min_row_h >= 76.0, "    smallest row height %.0f px (>= 44 CSS px)" % min_row_h)

	# The three decisions must be on screen and thumb-sized.
	for pair in [["allow", game._btn_allow], ["delete", game._btn_delete], ["ban", game._btn_ban]]:
		var b = pair[1]
		var inside: bool = b.global_position.x >= -1 and b.global_position.y >= -1 \
				and b.global_position.x + b.size.x <= canvas.x + 2 \
				and b.global_position.y + b.size.y <= canvas.y + 2
		_check(b.size.x > 60 and b.size.y >= 76 and inside,
				"    %s button %dx%d at %s" % [pair[0], b.size.x, b.size.y, b.global_position])
		# A button must be readable as drawn: compare the label ink against the
		# stylebox it actually paints, not against the theme's nominal colour.
		var sb: StyleBoxFlat = b.get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			var ink: Color = b.get_theme_color("font_color")
			var ratio := UI.contrast(sb.bg_color, ink)
			_check(ratio >= 4.5,
					"    %s label contrast %.2f (>= 4.5) on %s" % [pair[0], ratio, sb.bg_color])
			_check(sb.bg_color.get_luminance() > 0.35,
					"    %s keeps its accent colour (luminance %.2f)" % [pair[0], sb.bg_color.get_luminance()])
	# A pending row must not print its own answer. The category is only allowed
	# to appear after the player commits (reveal_category), so this catches any
	# future change that puts the verdict back on the row.
	var spoilers := 0
	var spoiler_who := ""
	var cat_db = game.sim.catalog
	for id in rows.keys():
		var r = rows[id]
		var m = r.get("msg")
		if m == null:
			continue
		var chips := String(r.get("_chips").text).to_lower()
		var cat := String(m.category)
		var lbl := String(cat_db.label(cat)).to_lower()
		var sh := String(cat_db.short(cat)).to_lower()
		for token in [lbl, sh, cat.replace("_", " "), cat]:
			if token.length() > 2 and chips == token or (token.length() > 3 and ("  " + token) in chips):
				spoilers += 1
				spoiler_who = "%s -> '%s'" % [cat, chips]
				break
	_check(spoilers == 0,
			"    no pending row reveals its category (leaks=%d %s)" % [spoilers, spoiler_who])
	# Chat text must be readable on the row background it actually paints.
	if not rows.is_empty():
		var row = rows.values()[0]
		var rsb: StyleBoxFlat = row.get_theme_stylebox("panel")
		if rsb is StyleBoxFlat:
			var labs: Array = row.find_children("*", "Label", true, false)
			var checked := 0
			for lab in labs:
				if checked >= 3:
					break
				var l := lab as Label
				if l == null or String(l.text).is_empty():
					continue
				var r2 := UI.contrast(rsb.bg_color, l.modulate)
				_check(r2 >= 4.5,
						"    chat label '%s' contrast %.2f (>= 4.5)" % [String(l.text).left(14), r2])
				checked += 1
	_check(game._stage_host.size.y >= 120 or not game._stage_host.visible,
			"    streamer feed visible or hidden by design (%d)" % game._stage_host.size.y)

	# Feedback popups and the speech bubble must be readable cards, not
	# one-character-per-line columns (the bug: they sized themselves from a
	# frame that had no size yet).
	var f = sim.focused()
	if f != null:
		sim.act("ban")
	for i in 3:
		await process_frame
	var popups := 0
	var too_tall := 0
	var too_narrow := 0
	for c in game._toast.get_children():
		if not (c is Control) or not (c as Control).visible:
			continue
		popups += 1
		var ctl := c as Control
		if ctl.size.x < 160.0:
			too_narrow += 1
		if ctl.size.y > 320.0:
			too_tall += 1
	_check(popups > 0, "    feedback popup spawned (%d)" % popups)
	_check(too_narrow == 0, "    no popup collapsed to a sliver (narrow=%d)" % too_narrow)
	_check(too_tall == 0, "    no popup wrapping one word per line (tall=%d)" % too_tall)

	# Streamer speech bubble.
	game._bubble.visible = true
	game._bubble_label.text = "nice save, mod! that one was clearly a troll"
	game.call("_layout_bubble")
	await process_frame
	_check(game._bubble.size.x >= 160.0,
			"    speech bubble has real width (%.0f)" % game._bubble.size.x)
	_check(game._bubble_label.get_combined_minimum_size().y <= 200.0,
			"    speech bubble is not a tall thin column (%.0f)"
			% game._bubble_label.get_combined_minimum_size().y)
	game.free()


func _audit_menu(canvas: Vector2) -> void:
	var menu = load("res://scenes/MainMenu.tscn").instantiate()
	if not menu.has_method("_ready"):
		_check(false, "menu screen script compiled")
		menu.free()
		return
	get_root().add_child(menu)
	menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	menu.size = canvas
	menu.reset_size()
	menu.size = canvas
	if menu.has_method("_layout"):
		menu.call("_layout")
	elif menu.has_method("_layout_world"):
		menu.call("_layout_world")
	for i in 6:
		await process_frame
	print("  [menu %dx%d]" % [canvas.x, canvas.y])
	var biggest := 0.0
	for c in _all_controls(menu):
		biggest = maxf(biggest, c.size.y)
	_check(biggest > 0, "    menu laid out (largest control height %.0f)" % biggest)
	menu.free()


func _all_controls(n: Node, out: Array = []) -> Array:
	if n is Control:
		out.append(n)
	for c in n.get_children():
		_all_controls(c, out)
	return out
