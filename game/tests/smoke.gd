extends SceneTree

## Headless boot smoke:  godot --headless --path game -s res://tests/smoke.gd
## Builds every scene, plays a real session against the sim, and asserts the
## whole UI layer survives it. Complements run_tests.gd (pure logic).

var failures := 0


func _initialize() -> void:
	print("── ModSim smoke ──")
	await process_frame
	await process_frame

	var content = root.get_node_or_null("ContentDB")
	_check(content != null and content.is_ready(), "ContentDB autoload ready")
	var saves = root.get_node_or_null("SaveManager")
	_check(saves != null and saves.profile != null, "SaveManager autoload ready")
	var audio = root.get_node_or_null("AudioManager")
	_check(audio != null, "AudioManager autoload ready")

	for scene_path in [
		"res://scenes/MainMenu.tscn",
		"res://scenes/Tutorial.tscn",
		"res://scenes/Results.tscn",
		"res://scenes/Ending.tscn",
		"res://scenes/Settings.tscn",
		"res://scenes/components/ChatMessage.tscn",
		"res://scenes/components/StreamerAvatar.tscn",
	]:
		await _boot_scene(scene_path)

	_test_streamer()
	await _play_a_session()
	await _boot_scene("res://scenes/Game.tscn")

	print("── %s ──" % ("SMOKE OK" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok  %s" % label)
	else:
		failures += 1
		printerr(" FAIL %s" % label)


func _boot_scene(path: String) -> void:
	var packed = load(path)
	if packed == null:
		_check(false, "scene loads: %s" % path)
		return
	var node = packed.instantiate()
	if node == null:
		_check(false, "scene instantiates: %s" % path)
		return
	if node is Control:
		(node as Control).size = Vector2(720, 1280)
	get_root().add_child(node)
	for i in 6:
		await process_frame
	var ok := is_instance_valid(node)
	_check(ok, "scene builds and stays alive: %s" % path.get_file())
	# Buttons must be thumb sized wherever the brief demands it.
	_small.clear()
	_buttons = 0
	_walk(node)
	var names: Array = []
	for c in _small:
		names.append("%s[%s]h=%.0f" % [c.name, c.text, (c as Control).custom_minimum_size.y])
	_check(_small.is_empty(), "%s: all %d buttons >= 76 reference px tall | %s"
			% [path.get_file(), _buttons, ", ".join(names)])
	node.free()


var _small := []
var _buttons := 0


func _walk(n: Node) -> void:
	if n is Button and (n as Control).custom_minimum_size.y > 0.0:
		_buttons += 1
		if (n as Control).custom_minimum_size.y < 76.0:
			_small.append(n)
	for c in n.get_children():
		_walk(c)


func _play_a_session() -> void:
	var packed = load("res://scenes/Game.tscn")
	var game = packed.instantiate()
	if game.has_method("with_params"):
		game.call("with_params", {"mode": "story"})
	get_root().add_child(game)
	for i in 4:
		await process_frame
	var sim = game.sim
	_check(sim != null, "game screen owns a live sim")
	if sim == null:
		game.free()
		return
	var gs = root.get_node_or_null("GameState")
	gs.pending_seed = 4242
	sim.configure("story", 4242)
	sim.start()
	# Drive 25 seconds of real time through the screen's own _process by
	# feeding ticks, then moderate with the ideal policy.
	var acted := 0
	for i in 5400:
		if sim.is_over():
			break
		sim.tick(1.0 / 30.0)
		if i % 3 == 0 and not sim.active.is_empty():
			# The screen mirrors rows from signals; check they exist.
			var f = sim.focused()
			if f != null and sim.act_timer <= 0.0:
				sim.act(f.ideal)
				acted += 1
	_check(acted > 25, "moderated %d messages through the live sim" % acted)
	_check(sim.stats["correct"] > 5, "%d correct calls registered" % int(sim.stats["correct"]))
	_check(sim.state in [Sim.State.RUNNING, Sim.State.WON, Sim.State.COMPLETE, Sim.State.LOST],
			"sim in a sane state (%d)" % sim.state)

	# Pause must stop the clock through the screen's own handler.
	game._pause()
	var before: float = sim.elapsed
	for i in 30:
		await process_frame
	_check(is_equal_approx(sim.elapsed, before), "pause through the UI freezes gameplay")
	game._resume()
	_check(sim.is_running(), "resume works")

	# Chat row recycling: rows must not accumulate without bound.
	for i in 200:
		sim._try_spawn()
	await process_frame
	_check(game._rows.size() <= 30, "row map is bounded (%d rows)" % game._rows.size())

	# Finish the run and make sure the hand-off to results is populated.
	var guard := 0
	while not sim.is_over() and guard < 20000:
		guard += 1
		sim.tick(1.0 / 30.0)
		if not sim.active.is_empty() and sim.act_timer <= 0.0:
			sim.act(sim.focused().ideal)
	_check(sim.is_over(), "session terminates (%d)" % sim.state)
	var summary: Dictionary = gs.last_summary
	_check(not summary.is_empty(), "summary handed to the results screen")
	if not summary.is_empty():
		_check(summary.has("score") and summary.has("trust"),
				"summary carries the score + meters")
	game.free()


func _test_streamer() -> void:
	var first := ProceduralVTuber.random_config(SplitMix32.new(120))
	var replay := ProceduralVTuber.random_config(SplitMix32.new(120))
	var second := ProceduralVTuber.random_config(SplitMix32.new(121))
	_check(first == replay and first != second, "streamer appearance is varied and seed reproducible")
	var avatar := ProceduralVTuber.new(first)
	root.add_child(avatar)
	avatar.set_expression("crying")
	avatar._process(1.0)
	avatar.set_expression("happy")
	_check(avatar._target["head_x"] == 0.0 and avatar._target["tear"] == 0.0,
			"sad pose and tears do not leak into happy expressions")
	avatar.react("shocked", 0.1)
	avatar.set_mood_from_happiness(10.0)
	avatar._process(0.2)
	_check(avatar.expression == "crying", "temporary reactions return to the latest baseline mood")
	avatar.set_mood_from_happiness(35.0)
	_check(avatar.expression == "worried", "middling mood has a distinct worried expression")
	avatar.set_mood_from_happiness(95.0)
	_check(avatar.expression == "excited", "great nights have an excited expression")
	avatar.free()
	var stage := VTuberStage.new(first)
	root.add_child(stage)
	stage.fit(1.5)
	_check(stage.camera.position.distance_to(Vector3(0, 1.02, 0)) > 3.0,
			"camera leaves room for hair, shoulders and expressions")
	stage.free()
