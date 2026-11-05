extends SceneTree

## Real GUI geometry and touch input, including content below the first screen.
var failures := 0


func _initialize() -> void:
	await process_frame
	await process_frame
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	for canvas in [Vector2i(360, 640), Vector2i(500, 900), Vector2i(720, 960), Vector2i(720, 1280), Vector2i(1280, 720)]:
		root.size = canvas
		for path in ["MainMenu", "Settings", "Tutorial", "Results", "Ending"]:
			await _audit(path, canvas)
	await _audit_chat()
	await _audit_pause()
	print("── %s ──" % ("MOBILE UI OK" if failures == 0 else "%d MOBILE UI FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok  ", label)
	else:
		failures += 1
		printerr(" FAIL ", label)


func _settle() -> void:
	for i in 5:
		await process_frame


func _audit(scene: String, canvas: Vector2i) -> void:
	var screen := load("res://scenes/%s.tscn" % scene).instantiate() as Control
	root.add_child(screen)
	await _settle()
	var page: ScrollPage = screen.get("_page")
	var tag := "%s %s" % [scene, canvas]
	_check(page != null and page.size.x <= canvas.x + 1 and page.size.y <= canvas.y + 1,
			"%s: page viewport stays inside screen" % tag)
	_check(page.content.get_combined_minimum_size().x <= page.size.x - 40,
			"%s: content fits horizontally (minimum %.0f)" % [tag, page.content.get_combined_minimum_size().x])
	_check(_horizontal_overflow(page.content, canvas.x).is_empty(),
			"%s: text and controls do not bleed across screen %s" % [tag, _horizontal_overflow(page.content, canvas.x)])

	if scene == "Settings":
		# Exercise the web-only AI controls even without a browser model.
		var status := page.find_children("*", "AIStatusRow", true, false)
		for row in status:
			row.set_process(false)
			row._toggle.visible = true
			row._action.visible = true
			row._action.text = "DOWNLOAD SMOLLM2 CHAT MODEL (705 MB)"
			row._state_label.text = "Waiting for the chat model to download"
		await _settle()
		_check(_horizontal_overflow(page.content, canvas.x).is_empty(), "%s: long download controls fit" % tag)
		await _test_scroll(page, tag)
	elif scene == "Tutorial":
		for step in range(1, screen.STEPS.size()):
			screen._index = step
			screen._show()
			if screen._card != null:
				screen._answer("ban")
			await _settle()
			_check(_horizontal_overflow(page.content, canvas.x).is_empty(), "%s: tutorial step %d fits" % [tag, step])
		await _test_scroll(page, tag)
	elif scene == "Ending":
		page.ensure_control_visible(screen._continue)
		await _settle()
		var index_before: int = screen._index
		await _tap(screen._continue)
		_check(screen._index == index_before + 1, "%s: NEXT tap advances exactly one line (%d -> %d)" % [tag, index_before, screen._index])
		for i in screen.SCRIPT.size():
			screen._advance()
		await _settle()
		_check(screen._date_buttons.visible, "%s: date choices are available" % tag)
		_check(_horizontal_overflow(page.content, canvas.x).is_empty(), "%s: all date buttons fit" % tag)
		await _test_scroll(page, tag)
		screen._pick_date(screen.DATES[0]["reply"])
		await _settle()
		_check(screen._continue.visible, "%s: continuation is reachable" % tag)
	else:
		await _test_scroll(page, tag)
	screen.free()
	await process_frame


func _horizontal_overflow(node: Node, width: float) -> Array:
	var out := []
	for child in node.get_children():
		if child is Control and child.is_visible_in_tree():
			var rect: Rect2 = child.get_global_rect()
			if rect.position.x < -1 or rect.end.x > width + 1:
				out.append("%s %.0f..%.0f" % [child.get_class(), rect.position.x, rect.end.x])
			out.append_array(_horizontal_overflow(child, width))
	return out


func _test_scroll(page: ScrollPage, tag: String) -> void:
	var bar := page.get_v_scroll_bar()
	var limit := bar.max_value - bar.page
	if limit <= 0:
		_check(true, "%s: all content fits without scrolling" % tag)
		return
	page.scroll_vertical = 0
	await _settle()
	# Drag on the page's content, not the scrollbar. ScrollContainer must
	# receive the gesture through the panels and labels painted above it.
	var start := Vector2(32, page.size.y - 100)
	var distance := minf(360, page.size.y * 0.5)
	var down := InputEventScreenTouch.new()
	down.position = start
	down.pressed = true
	Input.parse_input_event(down)
	for i in 12:
		var drag := InputEventScreenDrag.new()
		drag.position = start - Vector2(0, distance * float(i + 1) / 12.0)
		drag.relative = Vector2(0, -distance / 12.0)
		Input.parse_input_event(drag)
		await process_frame
	var up := InputEventScreenTouch.new()
	up.position = start - Vector2(0, distance)
	Input.parse_input_event(up)
	await _settle()
	_check(page.scroll_vertical > minf(20.0, limit * 0.5), "%s: finger swipe scrolls content (%d)" % [tag, page.scroll_vertical])
	page.scroll_vertical = int(bar.max_value)
	await _settle()
	var bottom := page.content.get_global_rect().end.y
	_check(bottom <= page.size.y + 1, "%s: bottom of page is reachable (%.0f <= %.0f)" % [tag, bottom, page.size.y])
	# Wheel scrolling is also needed on desktop and when a phone has a mouse.
	page.scroll_vertical = 0
	await _settle()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.position = Vector2(page.size.x * 0.5, 60)
	wheel.pressed = true
	Input.parse_input_event(wheel)
	await _settle()
	_check(page.scroll_vertical > 0, "%s: mouse wheel scrolls content" % tag)


func _tap(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var down := InputEventScreenTouch.new()
	down.position = point
	down.pressed = true
	Input.parse_input_event(down)
	await process_frame
	var up := InputEventScreenTouch.new()
	up.position = point
	Input.parse_input_event(up)
	await _settle()


func _audit_pause() -> void:
	root.size = Vector2i(720, 640)
	var game := load("res://scenes/Game.tscn").instantiate() as Control
	root.add_child(game)
	await _settle()
	game._pause()
	await _settle()
	var pages: Array = game._modal.find_children("*", "ScrollPage", true, false)
	_check(pages.size() == 1, "short screen: pause overlay has a scrollable page")
	if not pages.is_empty():
		var page := pages[0] as ScrollPage
		_check(_horizontal_overflow(page.content, 720).is_empty(), "short screen: pause controls fit horizontally")
		await _test_scroll(page, "short screen pause overlay")
	game.free()


func _audit_chat() -> void:
	root.size = Vector2i(720, 960)
	var game := load("res://scenes/Game.tscn").instantiate() as Control
	root.add_child(game)
	await _settle()
	var taps := []
	for i in 15:
		var msg := SimMessage.from_def(game.sim.catalog.pool("wholesome", 1)[0], game.sim.catalog,
				{"name": "touch_test"}, 1000 + i, 0, 999, 0, 0, game.sim.bal)
		game._on_spawned(msg)
		game._rows[msg.instance_id].tapped.connect(func(id): taps.append(id))
	await _settle()
	var scroll: ScrollContainer = game._scroll
	scroll.scroll_vertical = 0
	await _settle()
	var start := scroll.global_position + Vector2(60, scroll.size.y - 30)
	var down := InputEventScreenTouch.new()
	down.position = start
	down.pressed = true
	Input.parse_input_event(down)
	for i in 12:
		var drag := InputEventScreenDrag.new()
		drag.position = start - Vector2(0, (i + 1) * 15)
		drag.relative = Vector2(0, -15)
		Input.parse_input_event(drag)
		await process_frame
	var up := InputEventScreenTouch.new()
	up.position = start - Vector2(0, 180)
	Input.parse_input_event(up)
	await _settle()
	_check(scroll.scroll_vertical > 20, "chat: finger swipe scrolls through message rows")
	_check(taps.is_empty(), "chat: scrolling does not select a message as a tap")
	game.free()
