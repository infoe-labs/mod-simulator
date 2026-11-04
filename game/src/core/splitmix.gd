class_name SplitMix32
extends RefCounted

## Tiny deterministic PRNG (V8's splitmix64 truncated to 32-bit output).
## Same seed -> same stream on every platform, which is what makes the
## gameplay simulations reproducible in tests and replays.

var state: int = 0


func _init(seed_value: int = 0) -> void:
	state = seed_value & 0xFFFFFFFF


func next_int() -> int:
	state = (state + 0x9E3779B9) & 0xFFFFFFFF
	var z := state
	# All intermediates are masked to 32 bits (so always positive in GDScript's
	# 64-bit int), which makes `>>` a logical shift without needing BitArray.
	z = (z ^ (z >> 16)) & 0xFFFFFFFF
	z = (z * 0x21F0AAAD) & 0xFFFFFFFF
	z = (z ^ (z >> 15)) & 0xFFFFFFFF
	z = (z * 0x27D4EB2F) & 0xFFFFFFFF
	z = (z ^ (z >> 18)) & 0xFFFFFFFF
	return z


func next_float() -> float:
	return float(next_int()) / 4294967296.0


func range_f(from: float, to: float) -> float:
	if to <= from:
		return from
	return from + next_float() * (to - from)


func range_i(from: int, to: int) -> int:
	if to <= from:
		return from
	return from + next_int() % (to - from + 1)


func pick(arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[next_int() % arr.size()]


func weighted(weights: Dictionary) -> Variant:
	## Keys are any type, values are numeric weights. Deterministic on ties.
	var keys := weights.keys()
	keys.sort()
	var total := 0.0
	for k in keys:
		total += maxf(0.0, float(weights[k]))
	if total <= 0.0:
		return keys[0] if not keys.is_empty() else null
	var roll := next_float() * total
	var acc := 0.0
	for k in keys:
		acc += maxf(0.0, float(weights[k]))
		if roll < acc:
			return k
	return keys[keys.size() - 1]
