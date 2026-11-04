extends SceneTree
func _initialize():
	UI.ensure_theme()
	var g = load("res://scenes/Game.tscn").instantiate()
	g.call("with_params", {"mode": "story"})
	get_root().add_child(g)
	await process_frame
	for i in 40:
		g.sim.tick(0.25)
		await process_frame
	print("probe: screen=", g)
	g.free()
	quit()
