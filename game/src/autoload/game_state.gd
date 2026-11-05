extends Node

## Autoload: transient hand-off between screens. The live Sim lives here so
## the results/ending screens can read it without re-serialising anything.
##
## It also owns the one browser-LLM chat manager: a model takes a minute to
## download, so it must survive title -> game -> results, and it has to keep
## ticking (and keep downloading) while the player is sitting in a menu.

var sim: Sim = null
var last_summary: Dictionary = {}
var pending_mode: String = "story"
var pending_seed: int = 0
var ending_seen: bool = false
var ai: AIChatManager = null


func _process(delta: float) -> void:
	if ai != null and (sim == null or not sim.is_running()):
		# Running simulations tick the manager themselves.
		ai.tick(delta)


## The shared chat manager, created on first use.
func ai_manager() -> AIChatManager:
	if ai == null:
		ai = AIChatManager.new(ContentDB.cat(), ContentDB.bal())
		apply_ai_settings()
		ai.probe()
		# A player who already opted in gets a head start before the run.
		if ai.enabled and ai.consented:
			ai.request_download()
	return ai


## Push the saved preferences into the live manager.
func apply_ai_settings() -> void:
	if ai == null:
		return
	var p := SaveManager.profile
	ai.enabled = bool(p.setting("ai_enabled"))
	ai.consented = bool(p.setting("ai_consent"))
	ai.profile = String(p.setting("ai_profile"))
	ai.model_id = String(p.setting("ai_model"))
	ai.configure(null, {"title": "nori", "game": "cozy horror", "streamer": "Nori"}, {
		"enabled": ai.enabled,
		"consented": ai.consented,
		"profile": ai.profile,
		"model_id": ai.model_id,
	})


func set_ai_enabled(on: bool) -> void:
	SaveManager.set_setting("ai_enabled", on)
	var m := ai_manager()
	m.enabled = on
	if on and m.consented and not m.ready_flag:
		m.request_download()


func set_ai_consent() -> void:
	SaveManager.set_setting("ai_consent", true)
	ai_manager().request_download()


func set_ai_profile(which: String) -> void:
	SaveManager.set_setting("ai_profile", which)
	apply_ai_settings()


func begin_run(mode: String, seed_value: int) -> Sim:
	pending_mode = mode
	pending_seed = seed_value
	sim = ContentDB.new_sim(mode, seed_value)
	var manager := ai_manager()
	var opts := {
		"enabled": bool(SaveManager.setting("ai_enabled")),
		"consented": bool(SaveManager.setting("ai_consent")),
		"profile": String(SaveManager.setting("ai_profile")),
		"model_id": String(SaveManager.setting("ai_model")),
	}
	manager.configure(sim.director, {"title": sim.title, "streamer": "Nori", "mode": mode}, opts)
	sim.set_ai(manager)
	# One fresh session per run: this is the only place the queue is cleared.
	manager.begin_session(sim.director, {"title": sim.title, "streamer": "Nori", "mode": mode})
	return sim


func finish_run() -> void:
	if sim != null:
		last_summary = sim.summary()
		SaveManager.record(last_summary)
		if String(last_summary.get("outcome", "")) == "win":
			ending_seen = true
		sim = null
