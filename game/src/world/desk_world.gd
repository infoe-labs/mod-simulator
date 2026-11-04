class_name DeskWorld
extends Node3D

## The cozy night-time desk the player is sitting at: laptop, keyboard,
## trackpad, mug, lamp, plant, sticky notes, fairy lights, a wall. All
## primitives, three lights, no shadows, no shaders — it has to survive a
## single-threaded web export on a midrange phone.

const SCREEN_W := 1.16
const SCREEN_H := 0.86
const BEZEL_W := 1.30
const BEZEL_H := 1.02
const LID_TILT := -0.20
const HINGE := Vector3(0, 0.055, -0.42)

var camera: Camera3D
var screen_mesh: MeshInstance3D
var screen_mat: StandardMaterial3D
var lamp_light: OmniLight3D
var screen_light: OmniLight3D
var sun: DirectionalLight3D
var env: WorldEnvironment

var _t := 0.0
var _sway := true
var _pressure := 0.0
var _canvas := Vector2(720, 1280)
var _mats := {}
var _steam: Array[MeshInstance3D] = []
var _lights: Array[MeshInstance3D] = []
var _parts := 0


func _init() -> void:
	build("high")


func _mat(color: String, rough: float = 0.9, emissive: float = 0.0) -> StandardMaterial3D:
	var key := "%s|%f|%f" % [color, rough, emissive]
	if _mats.has(key):
		return _mats[key]
	var m := _make_mat(color, rough, emissive)
	_mats[key] = m
	return m


func _make_mat(color: String, rough: float, emissive: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = UI.hex(color)
	m.roughness = rough
	m.metallic = 0.0
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = UI.hex(color)
		m.emission_energy_multiplier = emissive
	m.vertex_color_use_as_albedo = false
	return m


func _box(parent: Node, size: Vector3, color: String, pos: Vector3,
		rot: Vector3 = Vector3.ZERO, rough: float = 0.9, emissive: float = 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, rough, emissive)
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_parts += 1
	return mi


func _cyl(parent: Node, r: float, h: float, color: String, pos: Vector3,
		rot: Vector3 = Vector3.ZERO, emissive: float = 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = maxf(0.01, h)
	cm.radial_segments = 8
	mi.mesh = cm
	mi.material_override = _mat(color, 0.85, emissive)
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_parts += 1
	return mi


func _quad(parent: Node, w: float, h: float, color: String, pos: Vector3,
		rot: Vector3 = Vector3.ZERO, emissive: float = 1.0,
		fresh: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mi.mesh = qm
	# `fresh` skips the material cache so alpha can be animated per instance.
	var m := _mat(color, 0.7, emissive) if not fresh else _make_mat(color, 0.7, emissive)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if fresh:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_parts += 1
	return mi


func build(quality: String) -> void:
	for c in get_children():
		c.queue_free()
	_mats.clear()
	_steam.clear()
	_lights.clear()
	_parts = 0
	_sway = quality != "low"

	# ---- environment ------------------------------------------------------
	var se := Environment.new()
	se.background_mode = Environment.BG_COLOR
	se.background_color = Color("100c1a")
	se.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	se.ambient_light_color = Color("6a5f8f")
	se.ambient_light_energy = 0.75
	se.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	se.tonemap_white = 1.6
	se.glow_enabled = false
	env = WorldEnvironment.new()
	env.environment = se
	add_child(env)

	sun = DirectionalLight3D.new()
	sun.light_color = Color("b9c6ff")
	sun.light_energy = 0.42
	sun.rotation_degrees = Vector3(-52, 34, 0)
	sun.shadow_enabled = false
	add_child(sun)

	# ---- room -------------------------------------------------------------
	_box(self, Vector3(4.6, 2.9, 0.12), "#241d38", Vector3(0, 1.3, -1.85))
	_box(self, Vector3(4.6, 0.06, 3.6), "#1b1628", Vector3(0, -0.32, 0.2))
	_box(self, Vector3(0.12, 2.9, 3.6), "#211a33", Vector3(-2.24, 1.3, 0.2))
	_box(self, Vector3(0.12, 2.9, 3.6), "#211a33", Vector3(2.24, 1.3, 0.2))
	# wall trim + poster + fairy lights
	_box(self, Vector3(4.5, 0.07, 0.06), "#33294f", Vector3(0, 0.12, -1.76))
	_quad(self, 0.78, 0.56, "#2e2547", Vector3(-1.05, 1.72, -1.77), Vector3.ZERO, 0.35)
	_quad(self, 0.3, 0.3, "#ff8fb1", Vector3(-1.22, 1.8, -1.75), Vector3.ZERO, 1.1)
	_quad(self, 0.16, 0.42, "#8fd8ff", Vector3(-0.92, 1.7, -1.75), Vector3.ZERO, 1.0)
	_quad(self, 0.52, 0.38, "#2e2547", Vector3(1.28, 1.62, -1.77), Vector3.ZERO, 0.35)
	_quad(self, 0.34, 0.1, "#ffd479", Vector3(1.28, 1.72, -1.75), Vector3.ZERO, 1.2)
	if quality != "low":
		for i in 7:
			var c: String = ["#ff8fb1", "#8fd8ff", "#ffd479", "#a8e6cf"][i % 4]
			var b := _quad(self, 0.07, 0.07, c,
					Vector3(-1.5 + i * 0.5, 2.16 - float(i % 2) * 0.05, -1.74),
					Vector3.ZERO, 2.2, true)
			_lights.append(b)
		_box(self, Vector3(3.1, 0.02, 0.02), "#3a3157", Vector3(0, 2.2, -1.74))

	# ---- desk -------------------------------------------------------------
	_box(self, Vector3(3.4, 0.1, 1.7), "#5a4634", Vector3(0, -0.05, 0.15))
	_box(self, Vector3(3.4, 0.06, 0.06), "#6d5540", Vector3(0, 0.01, 0.98))
	_box(self, Vector3(0.14, 0.7, 0.14), "#43342a", Vector3(-1.5, -0.42, 0.6))
	_box(self, Vector3(0.14, 0.7, 0.14), "#43342a", Vector3(1.5, -0.42, 0.6))
	# placemat under the laptop
	_box(self, Vector3(1.9, 0.012, 1.15), "#2b2340", Vector3(0, 0.008, -0.05))

	# ---- laptop -----------------------------------------------------------
	var base := Node3D.new()
	add_child(base)
	_box(base, Vector3(1.36, 0.05, 0.9), "#3b3550", Vector3(0, 0.028, 0.0))
	_box(base, Vector3(1.3, 0.014, 0.42), "#2c2740", Vector3(0, 0.056, 0.2))
	for row in 4:
		_box(base, Vector3(1.16, 0.012, 0.062), "#453e5e",
				Vector3(0, 0.062, 0.085 + row * 0.078))
	_box(base, Vector3(0.42, 0.012, 0.062), "#453e5e", Vector3(0, 0.062, 0.33))
	_box(base, Vector3(0.36, 0.01, 0.24), "#322c46", Vector3(0, 0.06, 0.5))
	# glowing keyboard underlight
	_box(base, Vector3(1.2, 0.006, 0.5), "#7a5cff", Vector3(0, 0.05, 0.2),
			Vector3.ZERO, 0.6, 1.1)

	var lid := Node3D.new()
	lid.position = HINGE
	lid.rotation.x = LID_TILT
	add_child(lid)
	_box(lid, Vector3(BEZEL_W, BEZEL_H, 0.035), "#2a2540", Vector3(0, BEZEL_H / 2.0, 0))
	_box(lid, Vector3(BEZEL_W, 0.05, 0.05), "#3b3550", Vector3(0, BEZEL_H, 0.01))
	screen_mat = _mat("#1a2740", 0.5, 1.0)
	screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var sq := QuadMesh.new()
	sq.size = Vector2(SCREEN_W, SCREEN_H)
	screen_mesh = MeshInstance3D.new()
	screen_mesh.mesh = sq
	screen_mesh.material_override = screen_mat
	screen_mesh.position = Vector3(0, BEZEL_H / 2.0, 0.022)
	lid.add_child(screen_mesh)
	_parts += 1
	# webcam dot + brand plate
	_quad(lid, 0.035, 0.035, "#7ee3b8", Vector3(0, BEZEL_H - 0.05, 0.024), Vector3.ZERO, 1.8)
	_box(lid, Vector3(0.26, 0.03, 0.02), "#4a4363", Vector3(0, 0.06, 0.022))
	screen_light = OmniLight3D.new()
	screen_light.light_color = Color("8fb7ff")
	screen_light.light_energy = 0.9
	screen_light.omni_range = 1.6
	screen_light.omni_attenuation = 1.4
	screen_light.position = Vector3(0, BEZEL_H / 2.0, 0.3)
	screen_light.shadow_enabled = false
	lid.add_child(screen_light)

	# ---- props ------------------------------------------------------------
	# mug with steam
	_cyl(self, 0.085, 0.15, "#e8f0f7", Vector3(-0.92, 0.075, 0.42))
	_cyl(self, 0.072, 0.02, "#5a3b2a", Vector3(-0.92, 0.145, 0.42))
	var handle := _cyl(self, 0.045, 0.022, "#e8f0f7", Vector3(-0.82, 0.08, 0.42),
			Vector3(0, 0, PI / 2.0))
	handle.rotation.y = PI / 2.0
	if quality != "low":
		for i in 2:
			var s := _quad(self, 0.05, 0.12, "#d8d0ff", Vector3(-0.93 + i * 0.04, 0.24, 0.42),
					Vector3.ZERO, 0.5, true)
			_steam.append(s)
	# desk lamp
	_cyl(self, 0.13, 0.03, "#2f2947", Vector3(1.16, 0.015, 0.24))
	_box(self, Vector3(0.03, 0.5, 0.03), "#3b3550", Vector3(1.16, 0.26, 0.24))
	_box(self, Vector3(0.03, 0.03, 0.28), "#3b3550", Vector3(1.16, 0.5, 0.12))
	var shade := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.13
	cone.height = 0.16
	cone.radial_segments = 8
	shade.mesh = cone
	shade.material_override = _mat("#4a4363", 0.8)
	shade.position = Vector3(1.16, 0.47, -0.02)
	shade.rotation.x = PI
	add_child(shade)
	_parts += 1
	lamp_light = OmniLight3D.new()
	lamp_light.light_color = Color("ffcf9a")
	lamp_light.light_energy = 1.35
	lamp_light.omni_range = 2.0
	lamp_light.omni_attenuation = 1.2
	lamp_light.position = Vector3(1.16, 0.42, -0.02)
	lamp_light.shadow_enabled = false
	add_child(lamp_light)
	# plant
	_cyl(self, 0.1, 0.14, "#c98f6d", Vector3(1.42, 0.07, 0.55))
	for i in 3:
		var leaf := _cyl(self, 0.05, 0.3, "#4f8f6a",
				Vector3(1.42 + (i - 1) * 0.06, 0.26, 0.55), Vector3(0.3, 0, (i - 1) * 0.4))
		leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# books
	_box(self, Vector3(0.34, 0.06, 0.24), "#ff8fb1", Vector3(-1.28, 0.03, 0.62))
	_box(self, Vector3(0.3, 0.05, 0.22), "#8fd8ff", Vector3(-1.27, 0.085, 0.62))
	_box(self, Vector3(0.26, 0.045, 0.2), "#ffd479", Vector3(-1.28, 0.13, 0.62),
			Vector3(0, 0.2, 0))
	# sticky notes on the wall
	var notes := ["#ffd479", "#ff8fb1", "#a8e6cf"]
	for i in 3:
		_quad(self, 0.17, 0.17, notes[i], Vector3(0.42 + i * 0.2, 1.28 + float(i % 2) * 0.1, -1.76),
				Vector3(0, 0, 0.06 * (i - 1)), 0.5)
	# phone face-down + coaster
	_box(self, Vector3(0.11, 0.02, 0.2), "#1d1930", Vector3(0.86, 0.012, 0.62),
			Vector3(0, 0.24, 0))
	_cyl(self, 0.11, 0.012, "#3a3157", Vector3(-0.62, 0.006, 0.66))

	# ---- camera -----------------------------------------------------------
	camera = Camera3D.new()
	camera.fov = 42.0
	camera.near = 0.05
	camera.far = 30.0
	camera.current = true
	add_child(camera)
	fit_camera(_canvas)


## Screen-space framing lives in the UI's hands; the camera only has to keep
## the display big. Portrait crops in tight so chat stays readable; landscape
## pulls back so you can see the whole laptop and the room around it.
func fit_canvas(canvas: Vector2) -> void:
	_canvas = canvas
	fit_camera(canvas)


func fit_camera(canvas: Vector2) -> void:
	if camera == null or canvas.x <= 0.0 or canvas.y <= 0.0:
		return
	var aspect := canvas.x / canvas.y
	var portrait := aspect < 1.0
	# How much of the frame height the lid should fill.
	var target := 0.66 if aspect < 0.7 else (0.52 if aspect < 1.1 else 0.42)
	var half := (BEZEL_H * 1.06) / (2.0 * target)
	var tan_half := tan(deg_to_rad(camera.fov * 0.5))
	var d := half / maxf(0.05, tan_half)
	# Never let the display become a stamp on a wide desktop window.
	if aspect > 1.1:
		var want_w := (BEZEL_W * 1.02) / 0.52
		var d_w := (want_w * 0.5) / maxf(0.05, tan_half * aspect)
		d = maxf(d, d_w)
	d = clampf(d, 0.8, 6.0)
	var focus := Vector3(0.0, 0.50, -0.42)
	var dir := Vector3(0.0, 0.44, 1.0).normalized()
	var pos := focus + dir * d
	camera.position = pos
	camera.look_at_from_position(pos, focus, Vector3.UP)
	camera.fov = 42.0 if portrait else 46.0


## The four corners of the lid rect in world space — the UI aligns itself to
## these so the chat panel looks like it lives on the display.
func screen_corners() -> Array:
	var lid := screen_mesh.get_parent() as Node3D
	var pts: Array = []
	for p in [Vector3(-BEZEL_W / 2.0, BEZEL_H, 0.03), Vector3(BEZEL_W / 2.0, BEZEL_H, 0.03),
			Vector3(BEZEL_W / 2.0, 0.0, 0.03), Vector3(-BEZEL_W / 2.0, 0.0, 0.03)]:
		pts.append(lid.to_global(p))
	return pts


func set_screen_tint(color: Color, energy: float = 1.0) -> void:
	if screen_mat == null:
		return
	screen_mat.albedo_color = color
	screen_mat.emission = color
	screen_mat.emission_energy_multiplier = energy
	if screen_light != null:
		screen_light.light_color = color.lightened(0.25)


## The night getting hotter: the room dims, the screen glow takes over.
func set_pressure(p: float) -> void:
	_pressure = clampf(p, 0.0, 1.0)
	if env != null:
		env.environment.ambient_light_energy = lerpf(0.8, 0.5, _pressure)
	if sun != null:
		sun.light_energy = lerpf(0.42, 0.24, _pressure)
	if lamp_light != null:
		lamp_light.light_energy = lerpf(1.35, 0.95, _pressure)
	if screen_light != null:
		screen_light.light_energy = lerpf(0.9, 1.5, _pressure)


func set_sway(v: bool) -> void:
	_sway = v


func set_quality(quality: String) -> void:
	set_sway(quality != "low")


func _process(delta: float) -> void:
	_t += delta
	if _sway and camera != null:
		var base := Vector3(0.0, 0.44, 1.0).normalized()
		var focus := Vector3(0.0, 0.50, -0.42)
		var d := camera.position.distance_to(focus)
		var wobble := Vector3(sin(_t * 0.31) * 0.014, cos(_t * 0.23) * 0.01, 0.0)
		camera.position = focus + base * d + wobble
		var eye := camera.position
		camera.transform = Transform3D(Basis.IDENTITY, eye).looking_at(
				focus + Vector3(0, sin(_t * 0.19) * 0.006, 0), Vector3.UP)
	for i in _steam.size():
		var s := _steam[i]
		var phase := fmod(_t * 0.5 + float(i) * 0.5, 1.0)
		s.position.y = 0.2 + phase * 0.16
		s.rotation.z = sin(_t * 1.4 + float(i)) * 0.3
		if s.material_override is StandardMaterial3D:
			(s.material_override as StandardMaterial3D).albedo_color.a = 0.34 * (1.0 - phase)
		s.visible = phase < 0.98
	for i in _lights.size():
		var b := _lights[i]
		if b.material_override is StandardMaterial3D:
			var a := 0.7 + 0.3 * sin(_t * 1.7 + float(i) * 1.3)
			(b.material_override as StandardMaterial3D).albedo_color.a = a


func part_count() -> int:
	return _parts
