class_name ProceduralVTuber
extends Node3D

## A low-poly VTuber built entirely from Godot primitives — no meshes, no
## external assets, no rig. Same seed => same girl, and every expression is
## tween/lerp driven so she stays cheap enough for a phone browser.

const SKIN_TONES := [
	"#f6d7c4", "#f0c8ac", "#e3b394", "#c98f6d", "#a9704f", "#f9e3d6",
]
const HAIR_COLORS := [
	"#f7a8c4", "#b8a6ff", "#8fd8ff", "#ffd479", "#f4978e", "#a8e6cf",
	"#e0aaff", "#ffe5d9", "#7ee3b8", "#c9c3ff",
]
const EYE_COLORS := [
	"#7a5cff", "#ff8fb1", "#4fc3f7", "#8bc34a", "#ffb74d", "#b39ddb", "#26c6da",
]
const CLOTH_COLORS := [
	"#6c5ce7", "#00b894", "#e17055", "#fdcb6e", "#81ecec", "#ff7675",
	"#a29bfe", "#ffeaa7", "#55efc4", "#fab1a0",
]
const HAIR_STYLES := ["bob", "twintails", "long", "short", "bun"]
const OUTFIT_STYLES := ["hoodie", "sailor", "sweater"]
const ACCESSORIES := ["none", "headset", "glasses", "hairclip", "cat ears"]
const BACKDROPS := ["shelf", "neon", "window"]

const FACE_BASE_Y := 1.32

var cfg: Dictionary = {}
var expression: String = "neutral"
var _expr_timer: float = 0.0
var _expr_default: String = "neutral"

var _t: float = 0.0
var _blink_at: float = 1.0
var _blinking: float = 0.0
var _talking: float = 0.0
var _bounce: float = 0.0
var _low_quality := false

var _mats := {}
var _head: Node3D
var _torso: MeshInstance3D
var _eyes: Array[MeshInstance3D] = []
var _pupils: Array[MeshInstance3D] = []
var _brows: Array[MeshInstance3D] = []
var _mouth: MeshInstance3D
var _blush: Array[MeshInstance3D] = []
var _tears: Array[MeshInstance3D] = []
var _heart: MeshInstance3D
var _parts: Array[Node3D] = []

# Smoothed pose targets.
var _pose := {
	"head_x": 0.0, "head_z": 0.0, "brow_x": 0.0, "mouth_x": 1.0, "mouth_y": 0.25,
	"eye_open": 1.0, "bounce": 0.0, "blush": 0.0, "tear": 0.0, "heart": 0.0,
}
const REST_POSE := {
	"head_x": 0.0, "head_z": 0.0, "brow_x": 0.0, "mouth_x": 1.0, "mouth_y": 0.25,
	"eye_open": 1.0, "bounce": 0.0, "blush": 0.0, "tear": 0.0, "heart": 0.0,
}
var _target := REST_POSE.duplicate(true)


static func default_config() -> Dictionary:
	return {
		"seed": 20260,
		"skin": SKIN_TONES[0],
		"hair": "#b8a6ff",
		"hair_style": "twintails",
		"hair_length": 1.15,
		"eyes": "#7a5cff",
		"eye_size": 1.0,
		"eye_spacing": 1.0,
		"face_width": 1.0,
		"outfit": "hoodie",
		"cloth": "#6c5ce7",
		"cloth_accent": "#ffeaa7",
		"accessory": "headset",
		"backdrop": "shelf",
		"blush_amount": 0.6,
	}


static func random_config(rng: SplitMix32) -> Dictionary:
	var c := default_config()
	c["seed"] = rng.next_int()
	c["skin"] = String(rng.pick(SKIN_TONES))
	c["hair"] = String(rng.pick(HAIR_COLORS))
	c["hair_style"] = String(rng.pick(HAIR_STYLES))
	c["hair_length"] = rng.range_f(0.85, 1.5)
	c["eyes"] = String(rng.pick(EYE_COLORS))
	c["eye_size"] = rng.range_f(0.85, 1.18)
	c["eye_spacing"] = rng.range_f(0.9, 1.12)
	c["face_width"] = rng.range_f(0.93, 1.08)
	c["outfit"] = String(rng.pick(OUTFIT_STYLES))
	c["cloth"] = String(rng.pick(CLOTH_COLORS))
	c["cloth_accent"] = String(rng.pick(CLOTH_COLORS))
	c["accessory"] = String(rng.pick(ACCESSORIES))
	c["backdrop"] = String(rng.pick(BACKDROPS))
	c["blush_amount"] = rng.range_f(0.35, 0.85)
	return c


func _init(config: Dictionary = {}, low_quality: bool = false) -> void:
	_low_quality = low_quality
	cfg = default_config() if config.is_empty() else config
	generate(cfg)


func set_low_quality(v: bool) -> void:
	if _low_quality == v:
		return
	_low_quality = v
	generate(cfg)


func _mat(color: String, rough: float = 0.85, unshaded: bool = false,
		emissive: float = 0.0, flat: bool = false) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s|%s" % [color, str(rough), str(unshaded), str(emissive), str(flat)]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	if flat:
		# Godot 4.7 has no material-level flat_shading; per-vertex lighting on
		# these 5-8 segment primitives gives the same faceted low-poly read.
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	m.albedo_color = UI.hex(color)
	m.roughness = rough
	m.metallic = 0.0
	m.vertex_color_use_as_albedo = false
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = UI.hex(color)
		m.emission_energy_multiplier = emissive
	_mats[key] = m
	return m


func _mesh(kind: String, a: float, b: float = 0.0, c: float = 0.0) -> Mesh:
	match kind:
		"box":
			var m := BoxMesh.new()
			m.size = Vector3(a, b, c)
			return m
		"sphere":
			var s := SphereMesh.new()
			s.radius = maxf(0.01, a)
			s.height = maxf(0.02, b if b > 0.0 else a * 2.0)
			s.radial_segments = 6 if _low_quality else 8
			s.rings = 4 if _low_quality else 6
			return s
		"cylinder":
			var cy := CylinderMesh.new()
			cy.top_radius = maxf(0.01, a)
			cy.bottom_radius = maxf(0.01, c if c > 0.0 else a)
			cy.height = maxf(0.02, b)
			cy.radial_segments = 6 if _low_quality else 8
			return cy
		"cone":
			# Godot 4.7 dropped ConeMesh: a cylinder with a zero top radius is
			# the same shape and keeps the same low-poly segment count.
			var cn := CylinderMesh.new()
			cn.top_radius = 0.0
			cn.bottom_radius = maxf(0.01, a)
			cn.height = maxf(0.02, b)
			cn.radial_segments = 5 if _low_quality else 6
			return cn
		"quad":
			var q := QuadMesh.new()
			q.size = Vector2(maxf(0.01, a), maxf(0.01, b))
			return q
	return BoxMesh.new()


func _part(parent: Node3D, kind: String, a: float, b: float, c: float,
		color: String, pos: Vector3, rot: Vector3 = Vector3.ZERO,
		rough: float = 0.85, unshaded: bool = false, emissive: float = 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(kind, a, b, c)
	mi.material_override = _mat(color, rough, unshaded, emissive, kind != "quad")
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	_parts.append(mi)
	return mi


func generate(config: Dictionary) -> void:
	cfg = config.duplicate(true)
	for c in get_children():
		c.queue_free()
	_parts.clear()
	_eyes.clear()
	_pupils.clear()
	_brows.clear()
	_blush.clear()
	_tears.clear()
	_mats.clear()

	var skin := String(cfg.get("skin", "#f6d7c4"))
	var hair := String(cfg.get("hair", "#b8a6ff"))
	var eye_col := String(cfg.get("eyes", "#7a5cff"))
	var cloth := String(cfg.get("cloth", "#6c5ce7"))
	var accent := String(cfg.get("cloth_accent", "#ffeaa7"))
	var outfit := String(cfg.get("outfit", "hoodie"))
	var style := String(cfg.get("hair_style", "twintails"))
	var length := float(cfg.get("hair_length", 1.15))
	var face_w := float(cfg.get("face_width", 1.0))
	var eye_size := float(cfg.get("eye_size", 1.0))
	var spacing := float(cfg.get("eye_spacing", 1.0))

	# ---- body -------------------------------------------------------------
	_torso = _part(self, "box", 0.86 * face_w, 0.72, 0.5, cloth, Vector3(0, 0.52, 0))
	_part(self, "box", 0.9 * face_w, 0.1, 0.52, accent, Vector3(0, 0.82, 0.005))
	_part(self, "box", 0.26, 0.5, 0.34, cloth, Vector3(-0.55 * face_w, 0.56, 0))
	_part(self, "box", 0.26, 0.5, 0.34, cloth, Vector3(0.55 * face_w, 0.56, 0))
	_part(self, "box", 0.3, 0.16, 0.22, skin, Vector3(-0.55 * face_w, 0.24, 0.06))
	_part(self, "box", 0.3, 0.16, 0.22, skin, Vector3(0.55 * face_w, 0.24, 0.06))
	_part(self, "box", 0.2, 0.18, 0.18, skin, Vector3(0, 0.92, 0.02))

	match outfit:
		"hoodie":
			_part(self, "box", 0.62, 0.3, 0.16, accent, Vector3(0, 0.62, 0.28))
			_part(self, "box", 0.34, 0.34, 0.14, hair, Vector3(0, 1.0, -0.26))
		"sailor":
			_part(self, "box", 0.66, 0.2, 0.1, accent, Vector3(0, 0.86, 0.24), Vector3(0.35, 0, 0))
			_part(self, "box", 0.16, 0.34, 0.06, accent, Vector3(0, 0.62, 0.29))
		"sweater":
			_part(self, "box", 0.9, 0.12, 0.52, accent, Vector3(0, 0.28, 0))
			_part(self, "sphere", 0.09, 0.0, 0.0, accent, Vector3(0, 0.66, 0.27))

	# ---- head -------------------------------------------------------------
	_head = Node3D.new()
	_head.position = Vector3(0, FACE_BASE_Y, 0)
	add_child(_head)
	_parts.append(_head)
	_part(_head, "sphere", 0.5, 1.0, 0.0, skin, Vector3(0, 0, 0), Vector3.ZERO, 0.9, false, 0.0)
	_head.scale = Vector3(face_w, 1.04, 0.94)
	# ears
	_part(_head, "sphere", 0.1, 0.16, 0.0, skin, Vector3(-0.48 * face_w, -0.02, 0))
	_part(_head, "sphere", 0.1, 0.16, 0.0, skin, Vector3(0.48 * face_w, -0.02, 0))
	# nose + chin shading hints
	_part(_head, "sphere", 0.045, 0.04, 0.0, UI.hex(skin).darkened(0.06).to_html(false), Vector3(0, -0.06, 0.47))

	# ---- eyes -------------------------------------------------------------
	var ex := 0.2 * spacing
	var eye_w := 0.13 * eye_size
	for side in [-1.0, 1.0]:
		var e := _part(_head, "sphere", eye_w, eye_w * 2.2, 0.0, "#fdfdff", Vector3(side * ex, 0.03, 0.42 * face_w), Vector3.ZERO, 0.4, true)
		e.scale = Vector3(1.0, 1.25, 0.5)
		_eyes.append(e)
		var p := _part(_head, "sphere", eye_w * 0.62, eye_w * 1.4, 0.0, eye_col, Vector3(side * ex, 0.03, 0.46 * face_w), Vector3.ZERO, 0.3, true, 0.55)
		p.scale = Vector3(1.0, 1.3, 0.4)
		_pupils.append(p)
		var g := _part(_head, "sphere", eye_w * 0.24, 0.0, 0.0, "#ffffff", Vector3(side * ex + 0.035, 0.11, 0.5 * face_w), Vector3.ZERO, 0.2, true, 1.2)
		_pupils.append(g)
	# brows
	for side in [-1.0, 1.0]:
		var b := _part(_head, "box", 0.17 * eye_size, 0.035, 0.03, UI.hex(hair).darkened(0.25).to_html(false), Vector3(side * ex, 0.22, 0.45 * face_w), Vector3(0, 0, side * -0.12))
		_brows.append(b)
	# mouth
	_mouth = _part(_head, "box", 0.16, 0.05, 0.03, "#c76a7a", Vector3(0, -0.2, 0.46 * face_w))
	# blush
	for side in [-1.0, 1.0]:
		var bl := _part(_head, "sphere", 0.1, 0.06, 0.0, "#ff9fb8", Vector3(side * 0.31 * face_w, -0.1, 0.4 * face_w), Vector3.ZERO, 0.6, true)
		bl.visible = false
		_blush.append(bl)
	# tears
	for side in [-1.0, 1.0]:
		var tr := _part(_head, "box", 0.05, 0.12, 0.02, "#9fd8ff", Vector3(side * 0.22 * face_w, -0.12, 0.47 * face_w), Vector3.ZERO, 0.3, true, 0.5)
		tr.visible = false
		_tears.append(tr)

	_build_hair(style, hair, length, face_w)
	_build_accessory(String(cfg.get("accessory", "headset")), hair, accent, face_w)
	_build_backdrop(String(cfg.get("backdrop", "shelf")))

	_heart = _part(self, "quad", 0.16, 0.16, 0.0, "#ff8fb1", Vector3(0.55, 1.9, 0.3), Vector3.ZERO, 0.4, true, 1.6)
	_heart.visible = false

	set_expression("neutral")


func _build_hair(style: String, hair: String, length: float, face_w: float) -> void:
	# fringe + cap are shared by every style; only the silhouette differs.
	_part(_head, "sphere", 0.54, 1.02, 0.0, hair, Vector3(0, 0.06, -0.02))
	_head_children_to_top()
	_part(_head, "box", 0.72 * face_w, 0.16, 0.2, hair, Vector3(0, 0.34, 0.36 * face_w), Vector3(0.18, 0, 0))
	match style:
		"bob":
			_part(_head, "box", 0.2, 0.42, 0.26, hair, Vector3(-0.44 * face_w, -0.14, 0.1))
			_part(_head, "box", 0.2, 0.42, 0.26, hair, Vector3(0.44 * face_w, -0.14, 0.1))
		"twintails":
			for side in [-1.0, 1.0]:
				_part(_head, "sphere", 0.16, 0.2, 0.0, hair, Vector3(side * 0.56 * face_w, 0.24, -0.02))
				_part(_head, "cylinder", 0.13, 0.62 * length, 0.05, hair, Vector3(side * 0.62 * face_w, -0.16 * length, -0.06), Vector3(0, 0, side * 0.16))
				_part(_head, "sphere", 0.07, 0.0, 0.0, String(cfg.get("cloth_accent", "#ffeaa7")), Vector3(side * 0.57 * face_w, 0.12, 0.0))
		"long":
			_part(_head, "box", 0.86 * face_w, 1.0 * length, 0.2, hair, Vector3(0, -0.42 * length, -0.26))
			_part(_head, "box", 0.22, 0.66 * length, 0.24, hair, Vector3(-0.44 * face_w, -0.3 * length, 0.08))
			_part(_head, "box", 0.22, 0.66 * length, 0.24, hair, Vector3(0.44 * face_w, -0.3 * length, 0.08))
		"short":
			_part(_head, "box", 0.24, 0.22, 0.22, hair, Vector3(-0.42 * face_w, 0.06, 0.16))
			_part(_head, "box", 0.24, 0.22, 0.22, hair, Vector3(0.42 * face_w, 0.06, 0.16))
			_part(_head, "box", 0.16, 0.16, 0.16, hair, Vector3(0.1, 0.5, 0.1), Vector3(0.4, 0.3, 0.2))
		"bun":
			_part(_head, "sphere", 0.22, 0.0, 0.0, hair, Vector3(0, 0.6, -0.1))
			_part(_head, "cylinder", 0.06, 0.2, 0.06, String(cfg.get("cloth_accent", "#ffeaa7")), Vector3(0, 0.46, -0.06))
		_:
			pass


func _head_children_to_top() -> void:
	# Keeps the hair cap parented to the head; exists so the call reads clearly.
	pass


func _build_accessory(kind: String, hair: String, accent: String, face_w: float) -> void:
	match kind:
		"headset":
			_part(_head, "cylinder", 0.44, 0.05, 0.44, "#3a3350", Vector3(0, 0.5, 0), Vector3(PI, 0, 0))
			for side in [-1.0, 1.0]:
				_part(_head, "cylinder", 0.13, 0.1, 0.13, accent, Vector3(side * 0.5 * face_w, 0.02, 0.02), Vector3(0, 0, PI / 2.0))
			_part(_head, "box", 0.05, 0.05, 0.26, "#3a3350", Vector3(0.34, -0.08, 0.34))
			_part(_head, "sphere", 0.05, 0.0, 0.0, MINT_HTML, Vector3(0.34, -0.08, 0.47), Vector3.ZERO, 0.4, true, 1.8)
		"glasses":
			for side in [-1.0, 1.0]:
				_part(_head, "cylinder", 0.15, 0.02, 0.15, "#e9e4ff", Vector3(side * 0.2, 0.03, 0.46 * face_w), Vector3(PI / 2.0, 0, 0), 0.4, true, 0.6)
			_part(_head, "box", 0.1, 0.02, 0.02, "#e9e4ff", Vector3(0, 0.03, 0.47 * face_w))
		"hairclip":
			_part(_head, "box", 0.16, 0.05, 0.05, String(cfg.get("cloth_accent", "#ffeaa7")), Vector3(-0.3 * face_w, 0.34, 0.4), Vector3(0, 0, 0.3))
		"cat ears":
			for side in [-1.0, 1.0]:
				_part(_head, "cone", 0.14, 0.3, 0.0, hair, Vector3(side * 0.28 * face_w, 0.56, -0.02), Vector3(0, 0, side * -0.18))
				_part(_head, "cone", 0.07, 0.16, 0.0, "#ffb3c8", Vector3(side * 0.28 * face_w, 0.54, 0.04), Vector3(0, 0, side * -0.18))
		_:
			pass


const MINT_HTML := "#7ee3b8"


func _build_backdrop(kind: String) -> void:
	match kind:
		"shelf":
			_part(self, "box", 2.6, 1.9, 0.12, "#2a2340", Vector3(0, 1.0, -1.1))
			_part(self, "box", 2.0, 0.08, 0.24, "#3a3157", Vector3(0, 1.5, -0.98))
			_part(self, "box", 2.0, 0.08, 0.24, "#3a3157", Vector3(0, 0.95, -0.98))
			var cols := ["#ff8fb1", "#8fd8ff", "#ffd479", "#a8e6cf"]
			for i in 5:
				_part(self, "box", 0.12, 0.3, 0.16, cols[i % cols.size()], Vector3(-0.7 + i * 0.3, 1.7, -0.95))
			_part(self, "sphere", 0.12, 0.0, 0.0, "#ffd479", Vector3(0.75, 1.12, -0.9), Vector3.ZERO, 0.5, true, 1.4)
		"neon":
			_part(self, "box", 2.6, 1.9, 0.12, "#221c36", Vector3(0, 1.0, -1.1))
			_part(self, "box", 1.7, 0.06, 0.06, "#ff8fb1", Vector3(0, 1.72, -1.0), Vector3(0, 0, 0.06), 0.4, true, 2.4)
			_part(self, "box", 1.7, 0.06, 0.06, "#8fd8ff", Vector3(0, 0.42, -1.0), Vector3(0, 0, -0.06), 0.4, true, 2.4)
			_part(self, "quad", 0.5, 0.5, 0.0, "#b8a6ff", Vector3(-0.7, 1.2, -1.02), Vector3.ZERO, 0.4, true, 1.0)
		"window":
			_part(self, "box", 2.6, 1.9, 0.12, "#251f3a", Vector3(0, 1.0, -1.1))
			_part(self, "quad", 1.1, 0.9, 0.0, "#2b3a67", Vector3(0.55, 1.25, -1.02), Vector3.ZERO, 0.4, true, 0.5)
			_part(self, "box", 1.2, 0.06, 0.06, "#3a3157", Vector3(0.55, 1.7, -1.0))
			_part(self, "sphere", 0.09, 0.0, 0.0, "#ffe5d9", Vector3(0.3, 1.45, -1.0), Vector3.ZERO, 0.4, true, 1.6)
		_:
			pass


# ---------------------------------------------------------------- expression

func set_expression(name: String) -> void:
	expression = name
	_expr_default = name
	_expr_timer = 0.0
	_apply_expression()


func react(name: String, seconds: float = 2.2) -> void:
	expression = name
	_expr_timer = seconds
	_apply_expression()


func say_for(seconds: float) -> void:
	_talking = seconds


func set_mood_from_happiness(h: float) -> void:
	## Baseline mood: she settles into whatever the night deserves.
	var base := "neutral"
	if h >= 92.0:
		base = "excited"
	elif h >= 72.0:
		base = "happy"
	elif h >= 42.0:
		base = "neutral"
	elif h >= 30.0:
		base = "worried"
	elif h >= 15.0:
		base = "upset"
	else:
		base = "crying"
	# Keep the baseline current even while a temporary reaction is playing.
	_expr_default = base
	if _expr_timer <= 0.0 and expression != base:
		expression = base
		_apply_expression()


func _apply_expression() -> void:
	_target = REST_POSE.duplicate(true)
	var tears_off := 0.0
	match expression:
		"happy":
			_target.merge({"mouth_x": 1.5, "mouth_y": 0.55, "brow_x": -0.15,
					"eye_open": 0.72, "bounce": 0.35, "blush": 0.5})
		"excited":
			_target.merge({"mouth_x": 1.7, "mouth_y": 1.5, "brow_x": -0.35,
					"eye_open": 1.15, "bounce": 0.8, "blush": 0.7, "heart": 1.0})
		"laughing":
			_target.merge({"mouth_x": 1.8, "mouth_y": 1.7, "brow_x": -0.4,
					"eye_open": 0.12, "bounce": 1.0, "blush": 0.9, "heart": 0.6})
		"blushing", "embarrassed":
			_target.merge({"mouth_x": 0.8, "mouth_y": 0.3, "brow_x": 0.1,
					"eye_open": 0.6, "blush": 1.0, "head_z": 0.12})
		"confused":
			_target.merge({"mouth_x": 0.7, "mouth_y": 0.4, "brow_x": 0.45,
					"eye_open": 1.0, "head_z": -0.16})
		"relieved":
			_target.merge({"mouth_x": 1.3, "mouth_y": 0.5, "brow_x": -0.12,
					"eye_open": 0.5, "head_x": -0.06, "bounce": 0.18, "blush": 0.3})
		"worried":
			_target.merge({"mouth_x": 0.7, "mouth_y": 0.35, "brow_x": 0.32,
					"eye_open": 0.85, "head_x": 0.08, "head_z": -0.08})
		"upset":
			_target.merge({"mouth_x": 0.7, "mouth_y": 0.3, "brow_x": 0.5,
					"eye_open": 0.62, "head_x": 0.12, "bounce": 0.0})
		"crying":
			_target.merge({"mouth_x": 0.9, "mouth_y": 0.9, "brow_x": 0.7,
					"eye_open": 0.25, "head_x": 0.26, "tear": 1.0, "blush": 0.6})
		"shocked":
			_target.merge({"mouth_x": 0.6, "mouth_y": 1.6, "brow_x": -0.5,
					"eye_open": 1.35, "head_x": -0.14})
		_:
			_target.merge({"mouth_x": 1.15, "mouth_y": 0.35, "brow_x": -0.05,
					"eye_open": 1.0, "bounce": 0.12, "blush": 0.25})
	if expression not in ["crying"]:
		_target["tear"] = tears_off
	if expression not in ["excited", "laughing"]:
		_target["heart"] = 0.0
	_target["blush"] = float(_target.get("blush", 0.2)) * float(cfg.get("blush_amount", 0.6))


func _process(delta: float) -> void:
	_t += delta
	if _expr_timer > 0.0:
		_expr_timer -= delta
		if _expr_timer <= 0.0:
			expression = _expr_default
			_apply_expression()
	if _talking > 0.0:
		_talking -= delta

	# blink
	_blink_at -= delta
	if _blink_at <= 0.0:
		_blinking = 0.13
		_blink_at = 2.2 + float((_t * 7919.0) - floor(_t * 7919.0)) * 3.4
	_blinking = maxf(0.0, _blinking - delta)

	var speed := 9.0
	for k in _pose.keys():
		_pose[k] = lerpf(float(_pose[k]), float(_target.get(k, 0.0)), clampf(delta * speed, 0.0, 1.0))

	if _head == null:
		return
	var idle_bob := sin(_t * 1.6) * 0.018
	var idle_tilt := sin(_t * 0.63) * 0.045
	var bounce := absf(sin(_t * 6.0)) * float(_pose["bounce"]) * 0.09
	_head.position = Vector3(0, FACE_BASE_Y + idle_bob + bounce, 0)
	_head.rotation = Vector3(
			float(_pose["head_x"]) + sin(_t * 0.9) * 0.02,
			sin(_t * 0.44) * 0.1,
			float(_pose["head_z"]) + idle_tilt)
	if _torso != null:
		_torso.position.y = 0.52 + sin(_t * 1.6) * 0.012 - bounce * 0.4

	var open_amount := clampf(float(_pose["eye_open"]) * (0.08 if _blinking > 0.0 else 1.0),
			0.06, 1.45)
	for e in _eyes:
		e.scale.y = 1.25 * open_amount
		e.visible = open_amount > 0.1
	for i in _pupils.size():
		if i < _pupils.size():
			_pupils[i].visible = open_amount > 0.18
			_pupils[i].scale.y = (1.3 if i % 2 == 0 else 1.0) * open_amount
	for i in _brows.size():
		var b := _brows[i]
		# Rotate in the face plane so the emotion reads from the camera.
		b.rotation.z = (-1.0 if i == 0 else 1.0) * float(_pose["brow_x"])
		b.position.y = 0.22 - float(_pose["brow_x"]) * 0.045
	if _mouth != null:
		var talking_y := 0.0
		if _talking > 0.0:
			talking_y = (0.5 + 0.5 * sin(_t * 17.0)) * 0.9
		_mouth.scale = Vector3(float(_pose["mouth_x"]),
				maxf(0.25, float(_pose["mouth_y"]) + talking_y), 1.0)
		_mouth.rotation.x = -float(_pose["brow_x"]) * 0.2
	for bl in _blush:
		bl.visible = float(_pose["blush"]) > 0.18
		var s := 0.6 + float(_pose["blush"]) * 0.7
		bl.scale = Vector3(s, s * 0.5, s * 0.4)
	for i in range(_tears.size()):
		var show := float(_pose["tear"]) > 0.2
		_tears[i].visible = show
		if show:
			var phase := fmod(_t * 0.9 + float(i) * 0.5, 1.0)
			_tears[i].position.y = -0.1 - phase * 0.22
			var tm: Material = _tears[i].material_override
			if tm is StandardMaterial3D:
				(tm as StandardMaterial3D).albedo_color.a = 1.0 - phase * 0.7
	if _heart != null:
		_heart.visible = float(_pose["heart"]) > 0.2
		if _heart.visible:
			_heart.position.y = 1.9 + sin(_t * 2.4) * 0.06
			_heart.rotation.z = sin(_t * 1.7) * 0.2


func part_count() -> int:
	return _parts.size()
