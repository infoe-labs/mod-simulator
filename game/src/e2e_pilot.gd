extends RefCounted

## Automated playthrough used by tools/e2e (Playwright) and by the headless
## screenshot run. Enabled only when the page is loaded with ?e2e=1, so normal
## players never see it. Each step prints an `[e2e] ...` console line that the
## driver waits for before taking a screenshot.

const STEP_LOG := "[e2e]"

var _main: Node
var _done := false
var _steps: Array = []
var _i := 0
var _wait := 0.0
var _hold := 0.0
var _acted := false
var _chat_seen := 0.0
var _frame := 0


func start(main: Node) -> void:
	_main = main
	# If the page carries an AI bridge (real, or the e2e mock), let the pilot
	# use it for one step. In-memory only: it never touches the saved profile.
	# Turn AI chat on through the same call the title screen uses, so the run
	# is configured exactly the way a player's would be. The e2e profile is a
	# throwaway browser profile, so persisting it here is harmless.
	var g = _main.get_node_or_null("/root/GameState")
	if g != null and g.has_method("set_ai_enabled") and g.has_method("ai_manager"):
		var manager = g.call("ai_manager")
		if manager != null and manager.is_available():
			g.call("set_ai_enabled", true)
			manager.enabled = true
			if manager.status.is_empty():
				manager.probe()
	# Each entry: {"to": scene path, "params": {}, "log": "text", "hold": frames}
	_steps = [
		{"to": "res://scenes/MainMenu.tscn", "log": "menu", "hold": 90, "then": "geom"},
		{"to": "res://scenes/Tutorial.tscn", "log": "tutorial", "hold": 70, "then": "advance"},
		{"to": "res://scenes/Tutorial.tscn", "log": "tutorial-card", "hold": 70, "then": "advance"},
		{"to": "res://scenes/Tutorial.tscn", "log": "tutorial-card-2", "hold": 70, "then": "advance"},
		{"to": "res://scenes/Game.tscn", "params": {"mode": "story"}, "log": "game", "hold": 200,
			"then": "chat"},
		{"to": "res://scenes/Game.tscn", "params": {"mode": "story", "jump": 150.0},
			"log": "game-late", "hold": 220},
		# The AI integration step. Harmless when no bridge exists (the driver
		# injects window.ModSimAIMock with ?aimock=1); it reports what it saw.
		{"to": "res://scenes/Game.tscn", "params": {"mode": "story", "jump": 150.0},
			"log": "game-ai", "hold": 1800, "then": "ai-report"},
		{"to": "res://scenes/Results.tscn", "params": {"won": true}, "log": "results", "hold": 90},
		{"to": "res://scenes/Results.tscn", "params": {"won": false}, "log": "results-lost", "hold": 90},
		{"to": "res://scenes/Ending.tscn", "params": {"won": true}, "log": "ending-win", "hold": 260},
		{"to": "res://scenes/Ending.tscn", "params": {"won": false}, "log": "ending-lose", "hold": 200},
		{"to": "res://scenes/Settings.tscn", "log": "settings", "hold": 600, "then": "geom"},
		{"to": "res://scenes/MainMenu.tscn", "log": "menu-progress", "hold": 90},
	]
	print(STEP_LOG + " start steps=" + str(_steps.size()))


func is_done() -> bool:
	return _done


## Called from Main._process while the pilot owns navigation.
func tick(delta: float) -> void:
	if _done or _steps.is_empty():
		return
	_frame += 1
	var step: Dictionary = _steps[_i]
	# Feed the live game so the chat actually moves and messages get moderated.
	var gs = _main.get_node_or_null("/root/GameState")
	_chat_seen += delta
	if _chat_seen > 0.8:
		_chat_seen = 0.0
		_dump_chat()
	if gs != null and gs.sim != null and gs.sim.is_running():
		if _frame % 6 == 0:
			var f = gs.sim.focused()
			if f != null:
				# Play the ideal answer most of the time so the late-game UI
				# (combos, verdicts, meters) is exercised the way a real mod
				# would drive it.
				gs.sim.act(f.ideal if _frame % 30 != 0 else "ban")
	if _wait > 0.0:
		_wait -= delta
		if not _acted and _wait < _hold * 0.45:
			_acted = true
			_do_then(step)
		if _wait <= 0.0:
			_i += 1
			if _i >= _steps.size():
				_done = true
				print(STEP_LOG + " done")
			else:
				_enter(_steps[_i])
		return
	# Idle: nothing scheduled, advance immediately.
	if _wait <= 0.0 and step.has("to"):
		_enter(step)


## Layout evidence for the browser run: without this a mis-sized container
## looks identical to a correct one from the outside.
func _dump_geometry() -> void:
	var scr = _main.current
	if scr == null:
		return
	var parts: Array = []
	_geom(scr, 0, parts)
	print(STEP_LOG + " geom " + " | ".join(parts))


## The chat is the one thing that must always be on screen; log enough of it to
## diagnose "empty tray" reports from a real browser run.
func _dump_chat() -> void:
	var scr = _main.current
	if scr != null and "_page" in scr:
		_dump_page(scr)
		return
	if scr == null or not ("_scroll" in scr):
		print(STEP_LOG + " chat n/a (screen=%s)" % [scr])
		return
	var parts: Array = []
	var scroll = scr._scroll
	var tray = scr._tray
	parts.append("frame=%s" % scr._frame.size)
	parts.append("scroll=%s@%s vis=%s" % [scroll.size, scroll.position, scroll.visible])
	parts.append("tray=%s@%s vis=%s" % [tray.size, tray.position, tray.visible])
	var n := 0
	for id in scr._rows.keys():
		var r = scr._rows[id]
		if r == null or not is_instance_valid(r):
			continue
		n += 1
		if n <= 3:
			parts.append("row%d=%s@%s vis=%s a=%.2f txt=%s" % [
				n, r.size, r.position, r.visible, r.modulate.a,
				String(r._text.text).left(14)])
	parts.append("rows=%d" % scr._rows.size())
	if "_btn_ban" in scr:
		parts.append("allow=%s" % scr._btn_allow.global_position + " ban=%s" % scr._btn_ban.global_position)
		parts.append("canvas=%s" % scr.size)
	print(STEP_LOG + " chat " + " | ".join(parts))


## Evidence for the browser-LLM integration: what the bridge reported, how many
## messages really came from it, and what the honesty chip says. The driver
## (tools/e2e/e2e.mjs) asserts on this line.
func _dump_ai() -> void:
	var gs = _main.get_node_or_null("/root/GameState")
	if gs == null:
		print(STEP_LOG + " ai unavailable=1 reason=no-gamestate")
		return
	var m = gs.get("ai")
	if m == null or not m.is_available():
		print(STEP_LOG + " ai unavailable=1 reason=no-bridge")
		return
	var sim = gs.sim
	var parts: Array = []
	parts.append("unavailable=0")
	parts.append("enabled=%d" % (1 if m.enabled else 0))
	parts.append("ready=%d" % (1 if m.ready_flag else 0))
	parts.append("phase=%s" % String(m.status.get("phase", m.phase)))
	parts.append("model=%s" % String(m.status.get("model", "-")))
	parts.append("runtime=%s" % String(m.status.get("runtime", "-")))
	if sim != null:
		parts.append("ai=%d" % int(sim.stats.get("ai", 0)))
		parts.append("classic=%d" % int(sim.stats.get("classic", 0)))
		parts.append("source=%s" % sim.chat_source())
		parts.append("total=%d" % int(sim.stats.get("total", 0)))
		parts.append("active=%d" % sim.active.size())
		parts.append("clock=%d" % int(sim.elapsed))
	var scr = _main.current
	if scr != null and "_source_chip" in scr:
		parts.append("chip=%s" % String(scr._source_chip.text).replace(" ", "_"))
	var sample := ""
	for r in (m._recent as Array):
		sample = String(r.get("text", "")).left(18).replace(" ", "_")
		parts.append("sample=%s" % sample)
		break
	parts.append("dropped=%d" % int(m.dropped))
	parts.append("queue=%d" % int(m.status.get("queue", 0)))
	parts.append("bridgeerr=%s" % String(m.bridge.last_error).replace(" ", "_"))
	parts.append("calls=%d" % int(m.bridge.calls))
	parts.append("code=%s" % String(m.bridge.last_code).left(160).replace(" ", "_"))
	parts.append("repaired=%d" % int(m.repaired))
	parts.append("pulled=%d" % int(m.pulled_total))
	parts.append("qsize=%d" % int((m._queue as Array).size()))
	parts.append("batches=%d/%d" % [int(m.batches_ok), int(m.batches_ok + m.batches_failed)])
	var probs := PackedStringArray()
	for x in m.last_problems:
		probs.append(String(x))
	parts.append("problems=%s" % "|".join(probs))
	print(STEP_LOG + " ai " + " ".join(parts))


func _geom(n: Node, depth: int, out: Array) -> void:
	if depth > 3:
		return
	if n is Control:
		var c := n as Control
		var vis := "" if c.visible else " HIDDEN"
		out.append("%s%s[%d,%d %dx%d]%s" % [
			"  ".repeat(depth), String(n.name).left(14),
			int(c.position.x), int(c.position.y),
			int(c.size.x), int(c.size.y), vis])
	for ch in n.get_children():
		_geom(ch, depth + 1, out)


func _enter(step: Dictionary) -> void:
	var to := String(step.get("to", ""))
	var params: Dictionary = step.get("params", {})
	if not params.is_empty():
		_main.goto(to, params)
	else:
		_main.goto(to)
	print(STEP_LOG + " " + str(step.get("log", to.get_file())))
	_hold = float(step.get("hold", 60)) / 60.0
	_wait = _hold
	_acted = false


func _do_then(step: Dictionary) -> void:
	var scr = _main.current
	if scr == null:
		return
	match String(step.get("then", "")):
		"advance":
			# Answer the practice card correctly, then move on.
			if scr.has_method("_answer"):
				scr.call("_answer", "allow")
			if scr.has_method("_advance"):
				scr.call("_advance")
		"geom":
			_dump_geometry()
		"chat":
			_dump_chat()
		"ai-report":
			_dump_ai()
		"finish":
			var gs = _main.get_node_or_null("/root/GameState")
			if gs != null and gs.sim != null:
				gs.sim.happiness = 100.0
				gs.sim.trust = 100.0
				gs.sim.elapsed = (gs.sim.session_seconds if gs.sim.session_seconds > 0.0 else 240.0) - 0.05


func _dump_page(screen: Control) -> void:
	var page: ScrollPage = screen.get("_page")
	if page == null:
		return
	var bar := page.get_v_scroll_bar()
	print(STEP_LOG + " page " + JSON.stringify({
		"screen": screen.get_script().get_global_name(),
		"canvas": [screen.size.x, screen.size.y],
		"viewport": [page.size.x, page.size.y],
		"content_width": page.content.size.x,
		"scroll": page.scroll_vertical,
		"max_scroll": maxf(0, bar.max_value - bar.page),
	}))
