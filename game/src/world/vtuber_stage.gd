class_name VTuberStage
extends Node3D

## The little 3D world the streamer lives in. Rendered into its own
## SubViewport so the chat UI stays crisp while she can still bob, blink and
## cry in real 3D. Swapping in an imported GLB later only means replacing
## `_vtuber` — nothing in the gameplay layer knows the difference.

const HEAD_Y := 1.32

var camera: Camera3D
var key: OmniLight3D
var rim: OmniLight3D
var env: WorldEnvironment
var _vtuber: ProceduralVTuber
var _cfg: Dictionary = {}
var _aspect := 1.2
var _quality := "high"


func _init(config: Dictionary = {}) -> void:
	_cfg = config if not config.is_empty() else ProceduralVTuber.default_config()
	_build()


func _build() -> void:
	for c in get_children():
		c.queue_free()

	var se := Environment.new()
	se.background_mode = Environment.BG_COLOR
	se.background_color = Color("141022")
	se.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	se.ambient_light_color = Color("8d80b8")
	se.ambient_light_energy = 1.05
	se.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	se.tonemap_white = 1.5
	env = WorldEnvironment.new()
	env.environment = se
	add_child(env)

	key = OmniLight3D.new()
	key.light_color = Color("#ffe6d5")
	key.light_energy = 1.5
	key.omni_range = 4.0
	key.omni_attenuation = 1.1
	key.position = Vector3(0.8, 2.0, 1.4)
	key.shadow_enabled = false
	add_child(key)

	rim = OmniLight3D.new()
	rim.light_color = Color("#8fb7ff")
	rim.light_energy = 1.1
	rim.omni_range = 3.6
	rim.omni_attenuation = 1.2
	rim.position = Vector3(-0.9, 1.5, -0.5)
	rim.shadow_enabled = false
	add_child(rim)

	camera = Camera3D.new()
	camera.fov = 34.0
	camera.near = 0.05
	camera.far = 14.0
	camera.current = true
	add_child(camera)

	_vtuber = ProceduralVTuber.new(_cfg)
	_vtuber.set_low_quality(_quality == "low")
	add_child(_vtuber)
	fit(_aspect)


func configure(config: Dictionary) -> void:
	_cfg = config.duplicate(true)
	if _vtuber != null:
		_vtuber.generate(_cfg)
		_vtuber.set_low_quality(_quality == "low")


func config() -> Dictionary:
	return _cfg.duplicate(true)


func set_quality(q: String) -> void:
	_quality = q
	if _vtuber != null:
		_vtuber.set_low_quality(q == "low")
		if rim != null:
			rim.visible = q != "low"


func fit(aspect: float) -> void:
	_aspect = clampf(aspect, 0.4, 2.4)
	if camera == null:
		return
	# Frame head + shoulders, keeping her slightly high so chat can sit below.
	var focus := Vector3(0.0, HEAD_Y - 0.14, 0.0)
	var dir := Vector3(0.0, 0.06, 1.0).normalized()
	var half := 0.62
	var tan_half := tan(deg_to_rad(camera.fov * 0.5))
	var d := half / maxf(0.05, tan_half)
	# Widen out on tall slots so her head never gets cropped.
	if _aspect < 1.0:
		d *= clampf(1.0 / maxf(0.45, _aspect) * 0.72, 1.0, 1.5)
	var pos := focus + dir * d
	camera.position = pos
	camera.look_at_from_position(pos, focus, Vector3.UP)


func set_expression(name: String) -> void:
	if _vtuber != null:
		_vtuber.set_expression(name)


func react(name: String, seconds: float = 2.2) -> void:
	if _vtuber != null:
		_vtuber.react(name, seconds)


func say_for(seconds: float) -> void:
	if _vtuber != null:
		_vtuber.say_for(seconds)


func set_mood_from_happiness(h: float) -> void:
	if _vtuber != null:
		_vtuber.set_mood_from_happiness(h)


func expression() -> String:
	return _vtuber.expression if _vtuber != null else "neutral"
