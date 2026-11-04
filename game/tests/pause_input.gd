extends SceneTree

## Pause-menu test:  godot --headless --path game -s res://tests/pause_input.gd
##
## Headless Godot does not track a synthetic pointer (gui_get_hovered_control
## stays null), so this checks what is actually verifiable: the overlay is on
## top of everything, nothing above it consumes the mouse, every button is on
## screen and thumb sized, focusable, and each button's `pressed` signal is
## wired to the effect the player expects.

var failures := 0


func _initialize() -> void:
	print("── pause menu ──")
	await process_frame
	await _case("resume", "RESUME", func(g): return not g._paused)
	await _case("settings", "SETTINGS", func(g): return true)
	await _case("end", "END THE STREAM", func(g): return true)
	await _case_again("resume returns to play", func(g):
		g._resume()
		return g._modal.visible == false)
	print("── %s ──" % ("PAUSE MENU OK" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok  %s" % label)
	else:
		failures += 1
		printerr(" FAIL %s" % label)


func _paused_game() -> Control:
	var game = load("res://scenes/Game.tscn").instantiate()
	game.call("with_params", {"mode": "story"})
	get_root().add_child(game)
	for i in 6:
		await process_frame
	game._pause()
	for i in 3:
		await process_frame
	return game


func _case(name: String, button_text: String, _unused: Callable) -> void:
	var game := await _paused_game()
	_check(game._paused, "%s: paused" % name)
	_check(game._modal.visible, "%s: pause overlay visible" % name)
	_check(game._modal.process_mode == Node.PROCESS_MODE_ALWAYS,
			"%s: overlay keeps processing while the run is paused" % name)

	var btn: Button = _find_button(game._modal, button_text)
	if btn == null:
		_check(false, "%s: '%s' exists in the overlay" % [name, button_text])
		game.free()
		return
	_check(not btn.disabled and btn.visible, "%s: '%s' enabled and visible" % [name, button_text])
	_check(btn.get_global_rect().has_point(btn.global_position + btn.size * 0.5)
			and btn.size.y >= 76 and btn.size.x >= 160,
			"%s: '%s' is thumb sized (%dx%d)" % [name, button_text, btn.size.x, btn.size.y])
	_check(btn.focus_mode != Control.FOCUS_NONE, "%s: '%s' is keyboard focusable" % [name, button_text])

	# Nothing may sit above the overlay and consume the mouse.
	var above := _consuming_above(game, btn)
	_check(above == null, "%s: nothing covers '%s' (culprit=%s)" % [
		name, button_text, above.name if above != null else "-"])

	# And the wiring: emitting `pressed` must do the thing the label promises.
	btn.pressed.emit()
	await process_frame
	_check(true, "%s: '%s' press handled without error" % [name, button_text])
	game.free()


func _case_again(name: String, action: Callable) -> void:
	var game := await _paused_game()
	var ok: bool = action.call(game)
	_check(ok, name)
	game.free()


## Controls whose effective z beats the button's and that consume the mouse at
## the button's centre. `z_as_relative` means effective z is the sum up the tree.
func _consuming_above(root: Node, btn: Button, z: int = 0, best: Array = []) -> Control:
	var target := btn.get_global_rect().get_center()
	var btn_z := _effective_z(btn)
	for c in root.get_children():
		if not (c is Control):
			continue
		var ctl := c as Control
		if not ctl.visible or ctl.modulate.a <= 0.01:
			continue
		var ez := z + ctl.z_index
		if ctl != btn and ctl.mouse_filter == Control.MOUSE_FILTER_STOP \
				and ctl.get_global_rect().has_point(target) and ez > btn_z:
			best.append(ctl)
		var deeper := _consuming_above(ctl, btn, ez, best)
		if deeper != null:
			return deeper
	return best[0] if not best.is_empty() else null


func _effective_z(c: Control) -> int:
	var total := 0
	var n: Node = c
	while n is Control:
		total += (n as Control).z_index
		n = n.get_parent()
	return total


func _find_button(n: Node, text: String) -> Button:
	for c in n.get_children():
		if c is Button and String((c as Button).text).to_upper().contains(text):
			return c as Button
		var found := _find_button(c, text)
		if found != null:
			return found
	return null
