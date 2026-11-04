extends SceneTree

## Balance harness:  godot --headless --path game -s res://tests/sim_tests.gd
##
## Runs the same seeds through four fictional moderators. The tuning contract
## from the brief: ideal play usually wins, ordinary play is a real challenge,
## random play almost never wins.

const SEEDS := 40
const DT := 1.0 / 30.0

var failures := 0
var bal: Balance
var cat: MessageCatalog


func _initialize() -> void:
	print("── ModSim balance harness (%d seeds per policy) ──" % SEEDS)
	bal = Balance.load_default()
	cat = MessageCatalog.load_default()

	var ideal := _batch("ideal")
	var competent := _batch("competent")
	var random_play := _batch("random")
	var allow_all := _batch("allow_all")
	var ban_all := _batch("ban_all")
	var relaxed := _batch("competent", "relaxed")

	_report("ideal", ideal)
	_report("competent", competent)
	_report("random", random_play)
	_report("allow_all", allow_all)
	_report("ban_all", ban_all)
	_report("competent/relaxed", relaxed)

	_check("ideal play usually wins", ideal["win_rate"] >= 0.70,
			"win rate %.0f%% (want >=70%%)" % (ideal["win_rate"] * 100.0))
	_check("ideal play is near-perfect at reading chat", ideal["accuracy"] >= 0.97,
			"accuracy %.0f%%" % (ideal["accuracy"] * 100.0))
	_check("ordinary play is a challenge, not a coin flip",
			competent["win_rate"] >= 0.10 and competent["win_rate"] <= 0.60,
			"win rate %.0f%% (want 10..60%%)" % (competent["win_rate"] * 100.0))
	_check("ordinary play survives most of the stream", competent["time_rate"] >= 0.55,
			"survived %.0f%% of the night" % (competent["time_rate"] * 100.0))
	_check("random play almost never wins", random_play["win_rate"] <= 0.10,
			"win rate %.0f%% (want <=10%%)" % (random_play["win_rate"] * 100.0))
	_check("random play is punished", random_play["lose_rate"] >= 0.80,
			"cancel rate %.0f%%" % (random_play["lose_rate"] * 100.0))
	_check("letting abuse through cancels the stream", allow_all["lose_rate"] >= 0.90,
			"cancel rate %.0f%%" % (allow_all["lose_rate"] * 100.0))
	_check("banning everyone cancels the stream", ban_all["lose_rate"] >= 0.90,
			"cancel rate %.0f%%" % (ban_all["lose_rate"] * 100.0))
	_check("relaxed mode is gentler than story", relaxed["win_rate"] >= competent["win_rate"]
			and relaxed["lose_rate"] <= competent["lose_rate"],
			"relaxed %.0f%% win / %.0f%% lose vs %.0f%% / %.0f%%" % [
				relaxed["win_rate"] * 100.0, relaxed["lose_rate"] * 100.0,
				competent["win_rate"] * 100.0, competent["lose_rate"] * 100.0])
	_check("the streamer is happy on a good night", ideal["happiness"] >= 95.0,
			"avg happiness %.1f" % ideal["happiness"])
	_check("trust only comes from judgment", ideal["trust"] >= bal.get_num("trust_to_win", 70.0),
			"avg trust %.1f (need %.0f)" % [ideal["trust"], bal.get_num("trust_to_win", 70.0)])
	_check("nobody wins by spamming ALLOW", allow_all["win_rate"] <= 0.02,
			"win rate %.0f%%" % (allow_all["win_rate"] * 100.0))
	_check("traffic stays inside a bounded queue", ideal["peak_queue"] <= bal.get_int("max_active", 5),
			"peak queue %d" % ideal["peak_queue"])
	_check("late chat piles up for a real player", competent["peak_queue"] >= 3,
			"peak queue %d (want >=3)" % competent["peak_queue"])
	_check("a perfect mod keeps the backlog shallow", ideal["peak_queue"] <= 3,
			"peak queue %d" % ideal["peak_queue"])
	_check("a full night has real volume", ideal["total"] >= 100,
			"%.0f messages per night on average" % ideal["total"])

	print("── %s ──" % ("BALANCE OK" if failures == 0 else "%d BALANCE FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func _check(label: String, cond: bool, detail: String) -> void:
	if cond:
		print("  ok  %s — %s" % [label, detail])
	else:
		failures += 1
		printerr(" FAIL %s — %s" % [label, detail])


func _report(name: String, r: Dictionary) -> void:
	print(("  %-17s win %3.0f%%  survive %3.0f%%  cancel %3.0f%%  acc %3.0f%%  "
			+ "happy %5.1f  trust %5.1f  score %6d  msgs %3.0f  queue %d") % [
		name,
		r["win_rate"] * 100.0, r["time_rate"] * 100.0, r["lose_rate"] * 100.0,
		r["accuracy"] * 100.0, r["happiness"], r["trust"], int(r["score"]),
		r["total"], r["peak_queue"]])


func _batch(policy: String, mode: String = "story") -> Dictionary:
	var acc := {"win": 0, "lose": 0, "complete": 0, "other": 0,
		"happiness": 0.0, "trust": 0.0, "score": 0.0, "accuracy": 0.0,
		"time": 0.0, "total": 0.0, "peak_queue": 0}
	for i in SEEDS:
		var r := _play(policy, 1000 + i * 7919, mode)
		match String(r["outcome"]):
			"win":
				acc["win"] += 1
			"lose":
				acc["lose"] += 1
			"complete":
				acc["complete"] += 1
			_:
				acc["other"] += 1
		acc["happiness"] += float(r["happiness"])
		acc["trust"] += float(r["trust"])
		acc["score"] += float(r["score"])
		acc["accuracy"] += float(r["accuracy"])
		acc["time"] += float(r["time"])
		acc["total"] += float(r["total_messages"])
		acc["peak_queue"] = maxi(acc["peak_queue"], int(r["peak_queue"]))
	var n := float(SEEDS)
	return {
		"win_rate": float(acc["win"]) / n,
		"lose_rate": float(acc["lose"]) / n,
		"complete_rate": float(acc["complete"]) / n,
		"time_rate": clampf(acc["time"] / n / maxf(1.0, bal.session_length(mode)), 0.0, 1.0),
		"happiness": acc["happiness"] / n,
		"trust": acc["trust"] / n,
		"score": acc["score"] / n,
		"accuracy": acc["accuracy"] / n,
		"total": acc["total"] / n,
		"peak_queue": acc["peak_queue"],
	}


func _play(policy: String, seed_value: int, mode: String = "story") -> Dictionary:
	var s := Sim.new(bal, cat)
	s.configure(mode, seed_value)
	s.start()
	var rng := SplitMix32.new(seed_value ^ 0xB0B0)
	var react := 0.7
	var act_at := 0.7
	var peak := 0
	var guard := 0
	while not s.is_over() and guard < 40000:
		guard += 1
		s.tick(DT)
		peak = maxi(peak, s.active.size())
		if s.elapsed >= act_at and s.act_timer <= 0.0 and not s.active.is_empty():
			var m := s.focused()
			s.act(_action_for(policy, m, rng))
			act_at = s.elapsed + _reaction(policy, rng)
	var summary: Dictionary = s.summary()
	summary["peak_queue"] = peak
	return summary


func _reaction(policy: String, rng: SplitMix32) -> float:
	match policy:
		"ideal":
			return rng.range_f(0.42, 0.62)
		"competent":
			return rng.range_f(0.62, 1.05)
		"random":
			return rng.range_f(0.45, 0.75)
		_:
			return rng.range_f(0.5, 0.8)


func _action_for(policy: String, m: SimMessage, rng: SplitMix32) -> String:
	match policy:
		"ideal":
			return m.ideal
		"allow_all":
			return "allow"
		"ban_all":
			return "ban"
		"random":
			return ["allow", "delete", "ban"][rng.next_int() % 3]
		"competent":
			var roll := rng.next_float()
			if roll < 0.80:
				return m.ideal
			if roll < 0.90:
				# The classic mistake: read a complaint as abuse, or miss one.
				return "delete" if m.ideal == "allow" else "allow"
			# ...or the wrong severity.
			if m.ideal == "ban":
				return "delete"
			if m.ideal == "delete":
				return "ban"
			return "delete"
		_:
			return m.ideal
