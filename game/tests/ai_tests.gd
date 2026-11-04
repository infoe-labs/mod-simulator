extends SceneTree

## Headless tests for the browser-LLM chat subsystem.
##
##   godot --headless --path game -s res://tests/ai_tests.gd
##
## No JavaScript, no model, no network: these cover the contracts that have to
## hold whatever the model says - validation, policy, the safety floor, queue
## bounds, ban persistence, fallback, honesty about the source, and that a slow
## or missing model can never stall or break the game.

var failures := 0
var bal: Balance
var cat: MessageCatalog


func _initialize() -> void:
	print("── ModSim AI tests ──")
	bal = Balance.load_default()
	cat = MessageCatalog.load_default()
	_test_validation()
	_test_policy()
	_test_safety_floor()
	_test_batch()
	_test_queue_bound()
	_test_bans()
	_test_fallback()
	_test_honesty()
	_test_sim_integration()
	_test_determinism()
	_test_bridge_payloads()
	print("── %s ──" % ("ALL PASS" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(0 if failures == 0 else 1)


func check(cond: bool, label: String) -> void:
	if cond:
		print("  ok  %s" % label)
	else:
		failures += 1
		printerr(" FAIL %s" % label)


func _raw(text: String, category: String, severity: int, ideal: String,
		username: String = "tester", alts: Array = [], rationale: String = "because") -> Dictionary:
	return {
		"text": text, "category": category, "severity": severity,
		"ideal_action": ideal, "alt_actions": alts, "username": username,
		"rationale": rationale, "persona": "regular", "tier": 1, "expiry": 10.0,
	}


func _manager() -> AIChatManager:
	var ai := AIChatManager.new(cat, bal)
	ai.enabled = true
	ai.bridge.force_present = true
	ai.ready_flag = true
	return ai


# ------------------------------------------------------------ 1. validation

func _test_validation() -> void:
	var ok := AIContent.validate_message(_raw("your laugh is the best part of tonight", "wholesome", 0, "allow"), cat)
	check(bool(ok["ok"]), "a clean generated message is accepted")
	var def: Dictionary = ok["def"]
	check(String(def["group"]) == "positive", "the catalog, not the model, decides the scoring group")
	check(float(def["damage"]) == AIContent.policy_damage("positive", 0),
			"damage comes from the policy table (%.1f)" % float(def["damage"]))
	check(String(def["username"]) == "tester", "username survives untouched")

	check(not bool(AIContent.validate_message({"text": "", "category": "friendly"}, cat)["ok"]),
			"an empty message is dropped")
	check(not bool(AIContent.validate_message(_raw("   ", "friendly", 0, "allow"), cat)["ok"]),
			"whitespace-only text is dropped")
	for banned_text in ["check https://evil.example.com", "click www.spam.test now",
			"you should kill yourself", "kys", "free porn at my profile",
			"🔥🔥🔥", "I will bomb this stream", "nazi stream"]:
		check(not bool(AIContent.validate_message(_raw(banned_text, "spam", 1, "delete"), cat)["ok"]),
				"blocked content never reaches the screen: %s" % banned_text.substr(0, 22))

	var promo := AIContent.validate_message(_raw("buy followers now cheap", "spam", 1, "delete", "promo3"), cat)
	check(bool(promo["ok"]) and String(promo["def"]["group"]) == "minor"
			and String(promo["def"]["ideal_action"]) != "allow",
			"advertising is kept but scored as a real infraction, not let through")
	var promo2 := AIContent.validate_message(_raw("buy followers now cheap", "friendly", 0, "allow", "promo4"), cat)
	check(bool(promo2["ok"]) and String(promo2["def"]["category"]) == "ad",
			"the same line offered as friendly chat is re-labelled as an ad")

	var long_text := ""
	for i in 90:
		long_text += "word "
	var clipped := AIContent.validate_message(_raw(long_text, "friendly", 0, "allow"), cat)
	check(bool(clipped["ok"]) and String(clipped["def"]["text"]).length() <= 220,
			"over-long text is clipped to the layout limit")

	var messy := AIContent.validate_message(_raw("hello", "friendly", 0, "allow", "@Cool  User!!"), cat)
	check(bool(messy["ok"]) and not String(messy["def"]["username"]).contains(" ")
			and not String(messy["def"]["username"]).contains("@"),
			"usernames are sanitised (%s)" % String(messy["def"]["username"]))

	var synthesised := AIContent.validate_message(_raw("greatest stream today", "compliment", 0, "allow"), cat)
	check(bool(synthesised["ok"]) and String(synthesised["def"]["category"]) == "wholesome",
			"a synonym category is mapped onto the real catalog")
	check(not bool(AIContent.validate_message(_raw("hi there", "totally-made-up", 0, "allow"), cat)["ok"]),
			"an unknown category with no mapping is dropped")

	var no_reason := AIContent.validate_message(_raw("nice map", "question", 0, "allow", "asker", [], ""), cat)
	check(bool(no_reason["ok"]) and String(no_reason["def"]["explanation"]).length() > 6
			and int(no_reason["repaired"]) > 0, "a missing rationale is filled in and counted")


# --------------------------------------------------------------- 2. policy

func _test_policy() -> void:
	var nice_but_banned := AIContent.validate_message(_raw("love you streamer", "wholesome", 0, "ban", "adorer"), cat)
	check(String(nice_but_banned["def"]["ideal_action"]) == "allow",
			"a harmless message can never be a ban, whatever the model said")
	check(not (nice_but_banned["def"]["alt_actions"] as Array).has("ban"),
			"ban is not offered as an alternative for something innocent")

	var nasty_but_kind := AIContent.validate_message(_raw("you are terrible at this game", "insult", 3, "allow", "haterx"), cat)
	check(String(nasty_but_kind["def"]["ideal_action"]) != "allow",
			"an abusive message can never be scored as allow")

	var mild_ban := AIContent.validate_message(_raw("repeat repeat repeat", "spam", 1, "ban", "bot1"), cat)
	check(String(mild_ban["def"]["ideal_action"]) == "delete"
			and not (mild_ban["def"]["alt_actions"] as Array).has("ban"),
			"a low-severity nuisance cannot demand a ban")

	var severe := AIContent.validate_message(_raw("you should disappear forever", "harassment", 4, "delete", "hater2", ["allow"]), cat)
	check((severe["def"]["alt_actions"] as Array).has("ban") and not (severe["def"]["alt_actions"] as Array).has("allow"),
			"a serious abuse offers ban but never allow as an alternative")

	var clamp := AIContent.validate_message(_raw("mild tease", "mild_troll", 99, "delete", "joker"), cat)
	check(int(clamp["def"]["severity"]) <= 4, "severity is clamped into range")
	var clamp2 := AIContent.validate_message(_raw("mild tease", "mild_troll", -3, "delete", "joker"), cat)
	check(int(clamp2["def"]["severity"]) >= 0 and int(clamp2["def"]["tier"]) >= 1,
			"out-of-range numbers are clamped, not trusted")

	var expiry := AIContent.validate_message({"text": "hmm", "category": "question", "severity": 0,
			"ideal_action": "allow", "username": "asker", "expiry": 900.0}, cat)
	check(float(expiry["def"]["expiry"]) <= 15.0 and float(expiry["def"]["expiry"]) >= 5.0,
			"expiry stays inside the readable band")


# -------------------------------------------------------- 3. safety floor

func _test_safety_floor() -> void:
	# The exact failure we saw from a 135M-parameter model in the lab.
	var wolf := AIContent.validate_message(_raw("nobody likes you, just quit streaming already",
			"wholesome", 0, "allow", "meanone"), cat)
	check(bool(wolf["ok"]), "the message is kept (we correct it, we do not silently drop real abuse)")
	check(String(wolf["def"]["group"]) == "major", "abuse dressed as a compliment is still scored major")
	check(int(wolf["def"]["severity"]) >= 3, "the floor raises severity")
	check(String(wolf["def"]["ideal_action"]) != "allow", "the floor removes allow from a real attack")
	check(int(wolf["repaired"]) > 0, "the correction is counted, not hidden")

	for pair in [
		["you're so ugly it hurts", "insult"],
		["go back to your basement", "harassment"],
		["free nitro gift card generator", "ad"],
		["how much is your rent", "invasive"],
		["who dies at the ending", "spoiler"],
	]:
		var r := AIContent.validate_message(_raw(String(pair[0]), "friendly", 0, "allow", "viewer9"), cat)
		check(String(r["def"]["group"]) in ["minor", "major"],
				"floor catches '%s' (%s -> %s)" % [String(pair[0]).substr(0, 20), pair[1], r["def"]["group"]])

	var never_softened := AIContent.validate_message(_raw("have a lovely evening", "wholesome", 0, "allow", "sweet1"), cat)
	check(String(never_softened["def"]["group"]) == "positive" and int(never_softened["repaired"]) == 0,
			"the floor never softens or touches a genuinely kind message")


# ---------------------------------------------------------------- 4. batch

func _test_batch() -> void:
	var batch := [
		_raw("best stream tonight", "wholesome", 0, "allow", "fan1"),
		_raw("what sensitivity do you use", "question", 0, "allow", "fan2"),
		_raw("FREE V-BUCKS check profile", "ad", 2, "delete", "promo1", ["ban"]),
		_raw("best stream tonight", "wholesome", 0, "allow", "fan1"),			# duplicate
		_raw("click http://spam.example", "spam", 1, "delete", "promo2"),		# blocked
		_raw("you are genuinely gifted", "wholesome", 0, "allow", "fan3"),
	]
	var res := AIContent.validate_batch(batch, cat, {}, 1, 3)
	check(bool(res["ok"]), "a good batch passes")
	check((res["defs"] as Array).size() == 4, "duplicates and blocked rows are dropped (%d kept)"
			% (res["defs"] as Array).size())
	check(int(res["dropped"]) == 2, "the drop count is reported (%d)" % int(res["dropped"]))

	var garbage := AIContent.validate_batch(["not even a dictionary", 42, null], cat, {}, 1, 2)
	check(not bool(garbage["ok"]), "a batch of garbage is rejected outright")

	var thin := AIContent.validate_batch([_raw("hi", "friendly", 0, "allow", "lonely")], cat, {}, 1, 2)
	check(not bool(thin["ok"]), "too few survivors rejects the batch (the dataset covers the gap)")

	var empty := AIContent.validate_batch(null, cat, {}, 1, 2)
	check(not bool(empty["ok"]), "a null batch is rejected, not crashed on")

	var not_list := AIContent.validate_batch({"text": "singular"}, cat, {}, 1, 1)
	check(not bool(not_list["ok"]), "a single object where a list was expected is rejected")


# ------------------------------------------------------------ 5. queue bound

func _test_queue_bound() -> void:
	var ai := _manager()
	ai.max_queue = 8
	var batch: Array = []
	for i in 60:
		batch.append(_raw("message number %d says hello" % i, "friendly", 0, "allow", "chatter%d" % i))
	var accepted := ai.ingest(batch)
	check(accepted <= ai.max_queue, "ingest respects the queue ceiling (got %d/%d)" % [accepted, ai.max_queue])
	var drained := 0
	while not ai._queue.is_empty():
		ai.next_message()
		drained += 1
	check(drained == accepted, "nothing is lost or duplicated while draining (%d)" % drained)
	check(ai.next_message().is_empty(), "an empty queue serves nothing and does not crash")
	accepted = ai.ingest(batch)
	check(accepted <= ai.max_queue, "a second flood is still bounded")


# ------------------------------------------------------------------ 6. bans

func _test_bans() -> void:
	var ai := _manager()
	ai.ingest([_raw("I will come back tomorrow", "friendly", 0, "allow", "returner")])
	ai.note_banned("Returner")
	check(ai.next_message().is_empty(), "a banned viewer's queued message is thrown away")
	check(ai.dropped >= 1, "the drop is counted")

	var res := AIContent.validate_message(_raw("back again", "friendly", 0, "allow", "returner"), cat,
			{"returner": true})
	check(not bool(res["ok"]), "a banned identity cannot be generated at all")

	# And through the sim: banning must permanently remove that identity.
	var sim := Sim.new(bal, cat)
	sim.configure("story", 31337)
	sim.set_ai(ai)
	sim.start()
	ai.ingest([_raw("back again friend", "friendly", 0, "allow", "returner"),
			_raw("hello hello hello there", "friendly", 0, "allow", "newface")])
	for i in 900:
		sim.tick(1.0 / 30.0)
		if sim.is_over():
			break
	for m in sim.active:
		check(String(m.username).to_lower() != "returner", "banned user never reappears in chat")


# --------------------------------------------------------------- 7. fallback

func _test_fallback() -> void:
	var ai := _manager()
	check(not ai.will_serve(), "no queue -> no AI messages")
	ai.enabled = false
	ai.ingest([_raw("ready to go", "friendly", 0, "allow", "waiter")])
	check(not ai.will_serve(), "AI off -> the authored dataset is used even with a full queue")
	ai.enabled = true
	check(ai.will_serve(), "enabling AI with a full queue starts serving")

	# The game must run with no bridge at all (desktop, unsupported device).
	var offline := AIChatManager.new(cat, bal)
	offline.enabled = true
	var started := Time.get_ticks_usec()
	for i in 2000:
		offline.tick(1.0 / 30.0)
		offline.next_message()
	var took_ms := float(Time.get_ticks_usec() - started) / 1000.0
	check(not offline.is_available(), "no bridge means no AI, cleanly")
	check(took_ms < 400.0, "an unavailable AI costs nothing per frame (%.1f ms for 2000 ticks)" % took_ms)
	check(offline.next_message().is_empty(), "and it never produces a message")

	var sim := Sim.new(bal, cat)
	sim.configure("story", 777)
	sim.set_ai(offline)
	sim.start()
	for i in 1800:
		sim.tick(1.0 / 30.0)
		if sim.is_over():
			break
	check(int(sim.stats["total"]) >= 10, "the game is fully playable with AI unavailable (%d messages)"
			% int(sim.stats["total"]))
	check(int(sim.stats.get("ai", 0)) == 0, "and nothing is credited to the model")


# ---------------------------------------------------------------- 8. honesty

func _test_honesty() -> void:
	var ai := _manager()
	check(ai.source_label() == "CLASSIC", "an unused AI is still reported as CLASSIC")
	ai.ingest([_raw("genuinely lovely chat", "friendly", 0, "allow", "honest1")])
	ai.next_message()
	check(ai.source_label() == "AI", "once the model has spoken, the label changes to AI")
	var off := _manager()
	off.enabled = false
	check(off.source_label() == "CLASSIC", "AI switched off always reads CLASSIC")

	var sim := Sim.new(bal, cat)
	sim.configure("story", 20250)
	var ai2 := _manager()
	sim.set_ai(ai2)
	sim.start()
	for i in 600:
		sim.tick(1.0 / 30.0)
		if sim.is_over():
			break
	check(sim.chat_source() == "classic", "a run with no AI messages says classic (%s)" % sim.chat_source())
	check(sim.chat_mix()["ai"] == 0 and sim.chat_mix()["classic"] > 0, "and the mix agrees")
	var summary := sim.summary()
	check(int(summary["ai_messages"]) == 0, "the results screen gets the same honest number")


# ------------------------------------------------------- 9. sim integration

func _test_sim_integration() -> void:
	var ai := _manager()
	var sim := Sim.new(bal, cat)
	sim.configure("story", 4242)
	sim.set_ai(ai)
	sim.start()
	var spawned_ai: Array = []
	var spawned_all: Array = []
	sim.spawned.connect(func(m: SimMessage):
		spawned_all.append(m)
		if m.source == "ai":
			spawned_ai.append(m))
	var batch := [
		_raw("your commentary makes my whole evening", "wholesome", 0, "allow", "sweetface"),
		_raw("is that the final boss already", "question", 0, "allow", "curiouscat"),
		_raw("BUY SUBS CHEAP NOW", "ad", 2, "delete", "sellbot", ["ban"]),
		_raw("nobody likes you, just quit streaming", "wholesome", 0, "allow", "fakednice"),
	]
	var dt := 1.0 / 30.0
	for i in 1500:
		if ai._queue.size() < 3:
			ai.ingest(batch)
		sim.tick(dt)
		if sim.is_over():
			break
	check(spawned_ai.size() > 0, "the sim really does put model-written messages on screen (%d)"
			% spawned_ai.size())
	check(int(sim.stats["ai"]) > 0 and int(sim.stats["classic"]) >= 0
			and int(sim.stats["ai"]) + int(sim.stats["classic"]) == int(sim.stats["total"]),
			"both sources are counted, and only the two of them (ai %d / classic %d / total %d)"
			% [int(sim.stats["ai"]), int(sim.stats["classic"]), int(sim.stats["total"])])
	check(sim.chat_source() in ["ai", "mixed"], "and the run is labelled honestly (%s)" % sim.chat_source())
	var disguised := false
	var scored_major := false
	for m in spawned_ai:
		if String(m.text).contains("quit streaming"):
			disguised = true
			if m.group == "major" and m.ideal != "allow":
				scored_major = true
	check(disguised, "the disguised attack really reached chat")
	check(scored_major, "and it was scored as major abuse, not as a compliment")
	check(int(sim.stats["total"]) >= 10, "the run still fills a full session (%d messages)"
			% int(sim.stats["total"]))

	# The manager must be told about bans so it stops proposing that identity.
	var before := ai.banned.size()
	sim.ban_user("sellbot")
	check(ai.banned.size() == before + 1, "banning a viewer tells the AI to stop writing for them")
	# And it must be given the recurring cast, so repeat offenders can recur.
	check(not ai.cast.is_empty(), "the model is told who the regulars and offenders are (%d names)"
			% ai.cast.size())
	var cast_ok := true
	for entry in ai.cast:
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("username") \
				or not (entry as Dictionary).has("offenses"):
			cast_ok = false
	check(cast_ok, "the cast report carries the username and strike count the model needs")
	ai._queue.clear()
	ai.ingest([_raw("I am back with more ads", "ad", 2, "delete", "sellbot")])
	check(ai._queue.is_empty(), "a banned viewer's next generated line is refused at ingest")
	check(ai.dropped > 0, "and the refusal is counted")


# ------------------------------------------------------------ 10. determinism

func _stream(sim: Sim, ai: AIChatManager, seconds: float, refeed: bool) -> String:
	var parts: Array = []
	sim.spawned.connect(func(m: SimMessage): parts.append("%d:%s:%s:%s:%s"
			% [m.instance_id, m.username, m.def["id"], m.category, m.source]))
	var dt := 1.0 / 30.0
	for i in int(seconds / dt):
		if refeed and ai != null and ai._queue.size() < 2:
			ai.ingest([
				_raw("a deterministic generated line", "friendly", 0, "allow", "deterministic"),
				_raw("another generated line for the run", "friendly", 0, "allow", "deterministc2"),
			])
		sim.tick(dt)
		if sim.is_over():
			break
	return "|".join(parts)


func _test_determinism() -> void:
	var a := Sim.new(bal, cat)
	var ai_a := _manager()
	a.configure("story", 909)
	a.set_ai(ai_a)
	a.start()
	var b := Sim.new(bal, cat)
	var ai_b := _manager()
	b.configure("story", 909)
	b.set_ai(ai_b)
	b.start()
	var sa := _stream(a, ai_a, 45.0, true)
	var sb := _stream(b, ai_b, 45.0, true)
	check(sa == sb and sa.length() > 20, "the same seed and the same generated batch replay identically")
	check(sa.count(":ai") > 0, "and that stream really contains AI messages")

	var plain1 := Sim.new(bal, cat)
	plain1.configure("story", 909)
	plain1.start()
	var plain2 := Sim.new(bal, cat)
	plain2.configure("story", 909)
	plain2.start()
	check(_stream(plain1, null, 45.0, false) == _stream(plain2, null, 45.0, false),
			"Classic Mode is still bit-identical with the AI code in the loop")


# --------------------------------------------------------- 11. bridge payloads

func _test_bridge_payloads() -> void:
	var bridge := BrowserAIBridge.new()
	var payload := {"text": "quotes \" and \\ backslash and <script> and \n newline",
			"nested": {"list": [1, 2, "three"]}, "unicode": "cozy ♡"}
	var encoded := bridge._b64(payload)
	var decoded_bytes: PackedByteArray = Marshalls.base64_to_raw(encoded)
	var parsed: Variant = JSON.parse_string(decoded_bytes.get_string_from_utf8())
	check(typeof(parsed) == TYPE_DICTIONARY, "bridge payloads survive base64 + JSON round-trip")
	if typeof(parsed) == TYPE_DICTIONARY:
		check(String(parsed["text"]) == payload["text"], "awkward characters are preserved exactly")
		check(String(parsed["unicode"]) == "cozy ♡", "unicode survives")

	var offline := BrowserAIBridge.new()
	check(not offline.bridge_present(), "the bridge reports honestly when there is no JavaScript")
	check(offline.status().is_empty() and offline.poll_events().is_empty()
			and offline.take_messages(5).is_empty(), "every call degrades to an empty value")
	offline.configure({"profile": "light"})			# must not error
	offline.request_batch({"count": 4})
	offline.unload()
	offline.delete_cache("x")
	check(true, "calling the bridge with no bridge does not crash")

	# The manager's own guards.
	var ai := AIChatManager.new(cat, bal)
	ai.director = DifficultyDirector.new(bal)
	ai.elapsed = 120.0
	ai.tick(1.0)
	check(ai.next_message().is_empty(), "the manager is inert without a bridge")
	var mix: Dictionary = ai._mix_for(10)
	var total := 0
	for k in mix.keys():
		total += int(mix[k])
		check(cat.categories.has(String(k)), "the requested mix only asks for real categories (%s)" % k)
	check(total >= 4 and total <= 14, "the mix asks for a sane number of messages (%d)" % total)
