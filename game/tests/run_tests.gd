extends SceneTree

## Headless logic tests:  godot --headless --path game -s res://tests/run_tests.gd
##
## Covers the ten contracts the brief calls out: dataset integrity, scoring
## policy, meter clamping, exactly-once expiration, ban persistence, difficulty
## ramp, pause semantics, save/load, queue bounds and seeded determinism.

var failures := 0
var bal: Balance
var cat: MessageCatalog


func _initialize() -> void:
	print("── ModSim core tests ──")
	bal = Balance.load_default()
	cat = MessageCatalog.load_default()
	_test_data()
	_test_scoring_policy()
	_test_escalation()
	_test_meter_clamp()
	_test_expiry_once()
	_test_bans_persist()
	_test_difficulty()
	_test_pause()
	_test_queue_bound()
	_test_determinism()
	_test_endings()
	_test_save()
	print("── %s ──" % ("ALL PASS" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func check(cond: bool, label: String) -> void:
	if cond:
		print("  ok  %s" % label)
	else:
		failures += 1
		printerr(" FAIL %s" % label)


func _sim(seed_v: int = 4242, mode: String = "story") -> Sim:
	var s := Sim.new(bal, cat)
	s.configure(mode, seed_v)
	s.start()
	return s


func _run(sim: Sim, seconds: float, dt: float = 1.0 / 30.0) -> void:
	var i := int(seconds / dt)
	for k in i:
		sim.tick(dt)
		if sim.is_over():
			break


# ---------------------------------------------------------------- 1. data

func _test_data() -> void:
	check(cat.is_loaded(), "messages.json loads")
	check(cat.count() >= 150, "at least 150 authored messages (%d)" % cat.count())
	check(cat.category_ids().size() >= 14, "at least 14 categories (%d)" % cat.category_ids().size())
	check(cat.users.size() >= 24, "at least 24 usernames (%d)" % cat.users.size())
	var raw := {}
	var f := FileAccess.open(MessageCatalog.PATH, FileAccess.READ)
	if f != null:
		raw = JSON.parse_string(f.get_as_text())
	var problems: Array = MessageCatalog.validate(raw)
	if problems.is_empty():
		check(true, "dataset passes schema validation")
	else:
		for p in problems.slice(0, 12):
			check(false, "dataset: %s" % p)
	var every_category_used := true
	for c in cat.category_ids():
		if cat.pool(String(c), 3).is_empty():
			every_category_used = false
	check(every_category_used, "every category has authored content")
	var balance_file := {}
	var bf := FileAccess.open(Balance.PATH, FileAccess.READ)
	if bf != null:
		balance_file = JSON.parse_string(bf.get_as_text())
	check(typeof(balance_file) == TYPE_DICTIONARY and balance_file.has("phases"),
			"balance.json loads with phases")
	var missing := 0
	for k in ["allow_wholesome", "allow_neutral", "delete_minor", "delete_major",
			"ban_major", "delete_harmless", "ban_innocent", "allow_hostile",
			"expire_serious", "expire_spam"]:
		if not balance_file.get("deltas", {}).has(k):
			missing += 1
	check(missing == 0, "all spec scoring rows exist in balance.json (%d missing)" % missing)


# ------------------------------------------------------- 2. scoring policy

func _msg(category: String, severity: int, ideal: String, group: String) -> SimMessage:
	var m := SimMessage.new()
	m.category = category
	m.group = group
	m.severity = severity
	m.ideal = ideal
	m.alts = []
	m.def = {"explanation": "test"}
	return m


func _d(category: String, severity: int, ideal: String, group: String, action: String) -> Vector2:
	return ModerationEngine.decide(_msg(category, severity, ideal, group), action, bal)["delta"]


func _test_scoring_policy() -> void:
	# The table from the design brief, asserted row by row.
	check(_d("wholesome", 0, "allow", "positive", "allow") == Vector2(3, 1),
			"allow wholesome = +3 / +1")
	check(_d("friendly", 0, "allow", "neutral", "allow") == Vector2(1, 1),
			"allow neutral = +1 / +1")
	check(_d("spam", 1, "delete", "minor", "delete") == Vector2(3, 2),
			"delete spam = +3 / +2")
	check(_d("attack", 3, "delete", "major", "delete") == Vector2(5, 3),
			"delete hostile attack = +5 / +3")
	check(_d("harassment", 4, "ban", "major", "ban") == Vector2(7, 4),
			"ban repeat harasser = +7 / +4")
	check(_d("friendly", 0, "allow", "neutral", "delete") == Vector2(-4, -4),
			"delete harmless = -4 / -4")
	check(_d("friendly", 0, "allow", "neutral", "ban") == Vector2(-9, -8),
			"ban innocent = -9 / -8")
	check(_d("attack", 3, "delete", "major", "allow") == Vector2(-8, -4),
			"allow hostile attack = -8 / -4")
	var serious := _msg("harassment", 3, "delete", "major")
	var r1: Dictionary = ModerationEngine.expire_verdict(serious, bal)
	check(r1["delta"] == Vector2(-10, -3), "serious harassment expires = -10 / -3")
	var spammy := _msg("spam", 1, "delete", "minor")
	var r2: Dictionary = ModerationEngine.expire_verdict(spammy, bal)
	check(r2["delta"] == Vector2(-3, -1), "spam expires = -3 / -1")

	# A complaint is not abuse: agreement-based categories must be allow-ideal,
	# and the group declared on the row is what scoring obeys.
	var allowed_harmless := true
	for m in cat.messages:
		var g: String = cat.group_for(m)
		if g in ["positive", "neutral"] and String(m["ideal_action"]) != "allow":
			allowed_harmless = false
	check(allowed_harmless, "every harmless (positive/neutral) message is allow-ideal")
	var abuse_ideal := true
	for m in cat.messages:
		var g2: String = cat.group_for(m)
		if g2 in ["minor", "major"] and String(m["ideal_action"]) == "allow":
			abuse_ideal = false
	check(abuse_ideal, "no abusive (minor/major) message is allow-ideal")
	var kindness_is_kind := true
	for m in cat.messages:
		if String(m["category"]) in ["wholesome", "friendly", "question", "joke", "criticism"] \
				and String(m["ideal_action"]) != "allow":
			kindness_is_kind = false
	check(kindness_is_kind, "nothing in a kind category asks you to punish a viewer")
	var worst_is_worst := true
	for m in cat.messages:
		if String(m["category"]) in ["harassment", "attack", "repeat_offender"] \
				and cat.group_for(m) != "major":
			worst_is_worst = false
	check(worst_is_worst, "harassment/attacks are always scored as major")

	# Authored `damage` must agree with the expiration table, or feedback lies.
	var mismatch := ""
	for m in cat.messages:
		var probe := SimMessage.from_def(m, cat, {"name": "t", "color": "#fff", "badge": "none"},
				1, 0.0, 10.0, 0, 0, bal)
		var want: float = -absf(float(m["damage"]))
		var got: float = ModerationEngine.expire_verdict(probe, bal)["delta"].x
		if absf(want - got) > 0.001:
			mismatch = "%s wants %.1f got %.1f (%s/%s)" % [m["id"], want, got, m["category"], probe.group]
			break
	check(mismatch == "", "authored damage matches the expiry table (%s)" % mismatch)

	# Alternative actions earn partial credit and never break the combo.
	var m := _msg("spam", 1, "delete", "minor")
	m.alts = ["ban"]
	var partial: Dictionary = ModerationEngine.decide(m, "ban", bal, 4)
	check(bool(partial["correct"]) and not bool(partial["exact"]),
			"alt action counts as acceptable, not perfect")
	check(int(partial["points"]) < int(ModerationEngine.decide(_msg("spam", 1, "delete", "minor"),
			"delete", bal, 4)["points"]), "partial credit scores lower than perfect")

	# Flood guard: farming friendly allows pays diminishing happiness.
	var flood_first: Vector2 = ModerationEngine.decide(_msg("wholesome", 0, "allow", "positive"),
			"allow", bal, 0, 1.0)["delta"]
	var flood_tenth: Vector2 = ModerationEngine.decide(_msg("wholesome", 0, "allow", "positive"),
			"allow", bal, 0, bal.get_num("positive_flood_floor", 0.2))["delta"]
	check(flood_first.x > flood_tenth.x and flood_tenth.x > 0.0,
			"allowing friendlies pays diminishing happiness (%.1f -> %.2f)" % [flood_first.x, flood_tenth.x])

	# Combo multiplier is monotonic and capped.
	var lo := ModerationEngine.combo_multiplier(0, bal)
	var hi := ModerationEngine.combo_multiplier(99, bal)
	check(hi > lo and absf(hi - (1.0 + bal.get_num("combo_step") * bal.get_int("combo_max"))) < 0.001,
			"combo multiplier rises then caps (%.2f -> %.2f)" % [lo, hi])


# ------------------------------------------------------- 3. escalation

func _test_escalation() -> void:
	var def := {"category": "spam", "ideal_action": "delete", "alt_actions": ["ban"],
			"escalates": true, "explanation": ""}
	var first := SimMessage.effective_ideal(def, 0, bal)
	check(String(first["ideal"]) == "delete", "first spam offense is a delete, not a ban")
	var thr := bal.strikes_to_ban("spam")
	var nth := SimMessage.effective_ideal(def, thr, bal)
	check(String(nth["ideal"]) == "ban", "spam at %d strikes escalates to ban" % thr)

	var once := {"category": "criticism", "ideal_action": "allow", "alt_actions": [],
			"escalates": false, "explanation": ""}
	var five := SimMessage.effective_ideal(once, 9, bal)
	check(String(five["ideal"]) == "allow",
			"a viewer who criticises once (or nine times) is never ban-worthy")

	var troll := cat.pool("mild_troll", 3)
	var never_ban := true
	for d in troll:
		if String(d["ideal_action"]) == "ban":
			never_ban = false
	check(never_ban, "mild trolling never escalates to a ban")


# ------------------------------------------------------- 4. meters clamp

func _test_meter_clamp() -> void:
	var s := _sim(99, "story")
	for i in 400:
		s._apply(Vector2(50, 50))
	check(s.happiness == 100.0 and s.trust == 100.0, "meters clamp at 100")
	for i in 400:
		s._apply(Vector2(-50, -50))
	check(s.happiness >= 0.0 and s.trust >= 0.0, "meters clamp at 0")
	check(s.happiness == 0.0, "happiness lands exactly on 0")

	# Fuzz: 3000 random decisions must never push a meter out of range.
	var fuzz := Sim.new(bal, cat)
	fuzz.configure("story", 7)
	fuzz.start()
	var rng := SplitMix32.new(11)
	var ok := true
	for i in 3000:
		if fuzz.active.is_empty():
			fuzz._try_spawn()
		if fuzz.active.is_empty():
			break
		var actions := ["allow", "delete", "ban"]
		fuzz.act(actions[rng.next_int() % 3])
		if fuzz.happiness < 0.0 or fuzz.happiness > 100.0 or fuzz.trust < 0.0 or fuzz.trust > 100.0:
			ok = false
			break
		if fuzz.is_over():
			fuzz.configure("story", 8)
			fuzz.start()
	check(ok, "3000 random decisions keep meters inside 0..100")


# ------------------------------------------------- 5. expiry exactly once

func _test_expiry_once() -> void:
	var s := _sim(31337)
	s._try_spawn()
	var m: SimMessage = s.active[0]
	var before_h := s.happiness
	var before_t := s.trust
	m.remaining = 0.01
	_run(s, 1.0)
	var lost_h := before_h - s.happiness
	var lost_t := before_t - s.trust
	check(lost_h > 0.0 or lost_t > 0.0, "expired message costs something (h -%.1f t -%.1f)"
			% [lost_h, lost_t])
	var again_h := s.happiness
	_run(s, 3.0)
	check(not s.active.has(m), "expired message leaves the queue")
	# A second tick pass over a long-expired message must never charge twice.
	m.remaining = -5.0
	_run(s, 2.0)
	check(is_equal_approx(s.happiness, again_h), "an expired message is never charged twice")
	# Counting: run 20s of real time and compare penalties to expiry count.
	var s2 := _sim(555)
	var penalised := []
	s2.expired.connect(func(msg, res): penalised.append(msg.instance_id))
	_run(s2, 40.0)
	var uniq := {}
	for id in penalised:
		uniq[id] = true
	check(penalised.size() == uniq.size(),
			"each message penalised exactly once (%d expiries, %d unique)" % [penalised.size(), uniq.size()])


# ---------------------------------------------------- 6. bans are sticky

func _test_bans_persist() -> void:
	var s := _sim(2024)
	var target := "spamspam_spam"
	s.ban_user(target)
	_run(s, 120.0)
	for m in s.active:
		check(m.username != target, "banned user %s never returns" % target)
	# Also verified across the whole message stream.
	var seen := {}
	var s2 := _sim(777)
	s2.ban_user("saltysocks")
	s2.resolved.connect(func(msg, res): seen[msg.username] = true)
	s2.expired.connect(func(msg, res): seen[msg.username] = true)
	_run(s2, 240.0)
	check(not seen.has("saltysocks"), "banned username absent from the whole session")
	check(s2.banned.has("saltysocks"), "ban list persists for the session")
	# Banning clears that viewer's other pending messages.
	var s3 := _sim(4)
	while s3.active.size() < 2:
		s3._try_spawn()
	var who: String = s3.active[0].username
	s3.active[1].username = who
	var pending := s3.active.size()
	s3.ban_user(who)
	check(s3.active.is_empty(), "ban sweeps the offender's other messages (%d -> 0)" % pending)


# ------------------------------------------------------ 7. difficulty

func _test_difficulty() -> void:
	var dirn := DifficultyDirector.new(bal)
	var prev_interval := 99.0
	var prev_expiry := 99.0
	var prev_active := 0
	var rising := true
	for t in [5.0, 50.0, 100.0, 160.0, 230.0]:
		var rng := SplitMix32.new(1)
		var iv := dirn.interval(rng, t)
		var es := dirn.expiry_scale(t)
		var ma := dirn.max_active(t)
		if iv > prev_interval or es > prev_expiry or ma < prev_active:
			rising = false
		prev_interval = iv
		prev_expiry = es
		prev_active = ma
	check(rising, "intervals shrink, expiry windows shrink, queue cap grows")
	check(dirn.phase_at(10.0).get("id") == "warmup" and dirn.phase_at(200.0).get("id") == "final",
			"phase boundaries match the brief (warmup@10s, final@200s)")
	check(dirn.phase_at(40.0).get("id") == "growing" and dirn.phase_at(80.0).get("id") == "busy"
			and dirn.phase_at(140.0).get("id") == "viral", "all five phases are reachable")
	var w := dirn.weights(10.0)
	var w2 := dirn.weights(230.0)
	check(float(w.get("wholesome", 0)) > float(w2.get("wholesome", 0)),
			"positives thin out as the night goes on")
	check(float(w2.get("harassment", 0)) > float(w.get("harassment", 0)),
			"hostility ramps up later")
	check(float(w.get("harassment", 0)) == 0.0 and float(w.get("attack", 0)) == 0.0,
			"the warmup phase contains no abuse at all")
	check(dirn.max_tier(10.0) == 1 and dirn.max_tier(230.0) == 3,
			"hard/ambiguous content unlocks with time")


# ---------------------------------------------------------- 8. pause

func _test_pause() -> void:
	var s := _sim(808)
	_run(s, 10.0)
	var t0 := s.elapsed
	var n0 := s.active.size()
	s.pause()
	check(s.state == Sim.State.PAUSED, "pause sets PAUSED")
	for i in 300:
		s.tick(1.0 / 30.0)
	check(is_equal_approx(s.elapsed, t0), "pause freezes the clock")
	check(s.active.size() == n0, "pause freezes the queue")
	var h0 := s.happiness
	for i in 600:
		s.tick(1.0 / 30.0)
	check(is_equal_approx(s.happiness, h0), "pause freezes the meters")
	s.resume()
	_run(s, 2.0)
	check(s.elapsed > t0, "resume restarts the clock")
	# Acting is refused while paused.
	s.pause()
	var res: Dictionary = s.act("ban")
	check(res.is_empty(), "no moderation input while paused")


# ------------------------------------------------- 9. queue is bounded

func _test_queue_bound() -> void:
	var s := _sim(606, "endless")
	var limit := bal.get_int("queue_limit", 24)
	var peak := 0
	for i in 4000:
		s.tick(1.0 / 30.0)
		peak = maxi(peak, s.active.size())
		if s.is_over():
			s.configure("endless", 607 + i)
			s.start()
	check(peak <= limit, "queue never exceeds queue_limit (peak %d <= %d)" % [peak, limit])
	var phase_peak := 0
	var s2 := _sim(608)
	for i in 8000:
		s2.tick(1.0 / 30.0)
		phase_peak = maxi(phase_peak, s2.active.size())
		if s2.is_over():
			break
	check(phase_peak <= bal.get_int("max_active", 5),
			"queue respects the phase cap (peak %d <= %d)" % [phase_peak, bal.get_int("max_active", 5)])


# ------------------------------------------------ 10. determinism

func _stream_of(sim: Sim, seconds: float) -> String:
	var parts: Array = []
	sim.spawned.connect(func(m: SimMessage): parts.append("%d:%s:%s" % [m.instance_id, m.username, m.def["id"]]))
	_run(sim, seconds)
	return "|".join(parts)


func _test_determinism() -> void:
	var a := _sim(12345)
	var b := _sim(12345)
	var c := _sim(12346)
	var sa := _stream_of(a, 60.0)
	var sb := _stream_of(b, 60.0)
	var sc := _stream_of(c, 60.0)
	check(sa == sb and sa.length() > 10, "same seed -> byte-identical stream (%d messages)"
			% sa.split("|").size())
	check(sa != sc, "a different seed produces a different stream")
	check(is_equal_approx(a.happiness, b.happiness) and is_equal_approx(a.trust, b.trust),
			"same seed -> same meters (%.1f/%.1f)" % [a.happiness, a.trust])
	# Deterministic policy replay.
	var d1 := _sim(4242)
	var d2 := _sim(4242)
	for s in [d1, d2]:
		var guard := 0
		while not s.is_over() and guard < 20000:
			guard += 1
			s.tick(1.0 / 30.0)
			if not s.active.is_empty():
				s.act(s.focused().ideal)
	check(d1.score == d2.score and d1.state == d2.state,
			"ideal-policy replay is reproducible (score %d)" % d1.score)


# ----------------------------------------------------- 11. endings

func _test_endings() -> void:
	# Perfect play wins; always-allow loses. Both must be reachable.
	var win_sim := _sim(2)
	var guard := 0
	while not win_sim.is_over() and guard < 20000:
		guard += 1
		win_sim.tick(1.0 / 30.0)
		if not win_sim.active.is_empty() and win_sim.act_timer <= 0.0:
			win_sim.act(win_sim.focused().ideal)
	check(win_sim.state in [Sim.State.WON, Sim.State.COMPLETE],
			"ideal play ends the stream (state %d)" % win_sim.state)

	var doom := _sim(2)
	guard = 0
	while not doom.is_over() and guard < 20000:
		guard += 1
		doom.tick(1.0 / 30.0)
		if not doom.active.is_empty() and doom.act_timer <= 0.0:
			doom.act("allow")
	check(doom.state == Sim.State.LOST, "allowing everything gets the stream cancelled")

	var tyrant := _sim(3)
	guard = 0
	while not tyrant.is_over() and guard < 20000:
		guard += 1
		tyrant.tick(1.0 / 30.0)
		if not tyrant.active.is_empty() and tyrant.act_timer <= 0.0:
			tyrant.act("ban")
	check(tyrant.state == Sim.State.LOST, "banning everyone also loses")

	# Trust gate: 100% happiness without trust must not declare victory.
	var gate := _sim(5)
	gate.happiness = 100.0
	gate.trust = 10.0
	var gated := []
	gate.trust_gated.connect(func(need): gated.append(need))
	gate._check_end()
	check(gate.state == Sim.State.RUNNING, "100%% happiness with low trust is not a win")
	check(gated.size() == 1, "the trust gate explains itself exactly once")

	# Timing gate: hitting both targets before the final stretch is not a win.
	var early := _sim(6)
	early.happiness = 100.0
	early.trust = 95.0
	early.elapsed = 100.0
	var locked := []
	early.victory_locked.connect(func(): locked.append(1))
	early._check_end()
	check(early.state == Sim.State.RUNNING, "maxed meters before the final wave is not a win")
	check(locked.size() == 1, "the 'hold it to the end' hint fires once")
	var full := _sim(7)
	full.happiness = 100.0
	full.trust = 95.0
	full.elapsed = full.win_from + 1.0
	full._check_end()
	check(full.state == Sim.State.WON, "maxed meters in the final wave wins")


# ----------------------------------------------------- 12. save/load

func _test_save() -> void:
	var path := "user://test_profile.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var p := Profile.new()
	p.best_score = 12345
	p.best_happiness = 88.0
	p.games_played = 7
	p.wins = 2
	p.settings["music"] = 0.5
	p.settings["mute"] = true
	p.unlocks["endless"] = true
	p.tutorial_seen = true
	check(p.save_to(path), "profile saves")
	var q := Profile.load_from(path)
	check(q.best_score == 12345 and q.best_happiness == 88.0 and q.games_played == 7
			and q.wins == 2, "profile numbers round-trip")
	check(bool(q.settings.get("mute", false)) and absf(float(q.settings.get("music", 0.0)) - 0.5) < 0.001,
			"settings round-trip")
	check(q.unlocks.get("endless", false) and q.tutorial_seen, "unlocks + tutorial flag round-trip")

	# Corrupted file must degrade to defaults, never crash.
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ this is not json ]")
	f.close()
	var r := Profile.load_from(path)
	check(r.best_score == 0 and r.games_played == 0, "corrupt save falls back to defaults")
	var missing := Profile.load_from("user://nope_never_written.json")
	check(missing != null and missing.games_played == 0, "missing save falls back to defaults")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
