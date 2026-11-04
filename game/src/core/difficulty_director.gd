class_name DifficultyDirector
extends RefCounted

## Time -> pressure. Pure function of elapsed seconds + balance.json, so a
## run at second 137 always behaves the same no matter who is watching.

const TIER_BY_PHASE := [1, 2, 2, 3, 3]

var bal: Balance


func _init(balance: Balance = null) -> void:
	bal = balance if balance != null else Balance.load_default()


func phase_at(t: float) -> Dictionary:
	return bal.phase_at(t)


func phase_index(t: float) -> int:
	return bal.phase_index_at(t)


func phase_count() -> int:
	return bal.phases().size()


func interval(rng: SplitMix32, t: float) -> float:
	var p := phase_at(t)
	var lo := float(p.get("spawn_min", 2.0))
	var hi := float(p.get("spawn_max", 3.0))
	return maxf(0.35, rng.range_f(lo, hi))


func expiry_scale(t: float) -> float:
	return float(phase_at(t).get("expiry_scale", 1.0))


func max_active(t: float) -> int:
	var p := phase_at(t)
	return maxi(1, int(p.get("max_active", bal.get_int("max_active", 5))))


func burst(t: float) -> float:
	## Chance that a second message lands immediately after one spawn — chat
	## piling on. Bounded by the queue cap, so pressure never becomes luck.
	return clampf(float(phase_at(t).get("burst", 0.0)), 0.0, 0.6)


func max_tier(t: float) -> int:
	var idx := clampi(phase_index(t), 0, TIER_BY_PHASE.size() - 1)
	return TIER_BY_PHASE[idx]


func allows_repeat_offenders(t: float) -> bool:
	return bool(phase_at(t).get("repeat_offenders", false))


func weights(t: float) -> Dictionary:
	var raw: Dictionary = phase_at(t).get("weights", {})
	var out := {}
	for k in raw.keys():
		var w := float(raw[k])
		if w > 0.0:
			out[k] = w
	if out.is_empty():
		out = {"friendly": 1.0}
	return out


## 0..1 — drives the "pressure" meter, camera sway and chat speed lines.
func pressure(t: float) -> float:
	var list := bal.phases()
	var last: Dictionary = list[list.size() - 1]
	var end := float(last.get("to", 240.0))
	var span := 90.0
	var start := maxf(0.0, end - span)
	return clampf((t - start) / maxf(1.0, end - start), 0.0, 1.0)
