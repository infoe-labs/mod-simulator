class_name UI
extends RefCounted

## One theme for the whole game, plus widget factories. Everything that draws
## text goes through here so the "cozy PS1 streaming app" look stays coherent
## and font sizes stay thumb-readable on a phone.

static var BG := Color("16121f")
static var BG_SOFT := Color("1c1729")
static var PANEL := Color("241d33")
static var PANEL_LIGHT := Color("2e2543")
static var PANEL_LINE := Color("3d3159")
static var TEXT := Color("f4ecff")
static var TEXT_DIM := Color("a99cc7")
static var TEXT_FAINT := Color("6f6390")

static var MINT := Color("7ee3b8")
static var MINT_DARK := Color("2f7a5e")
static var AMBER := Color("ffcf7a")
static var AMBER_DARK := Color("8a6a2f")
static var CORAL := Color("ff7d90")
static var CORAL_DARK := Color("8c3a4a")
static var PINK := Color("ffa6d5")
static var VIOLET := Color("b8a6ff")
static var LIVE := Color("ff4d6d")
static var GOLD := Color("ffd97a")
static var SKY := Color("9bd7ff")

## Inks used for labels drawn on top of a filled button.
static var INK_DARK := Color("17122b")
static var INK_LIGHT := Color("f7f3ff")

## Font sizes are in reference-canvas pixels (720 wide). On a 390pt iPhone the
## canvas scales by ~0.54, so 30px ~= 16 CSS px: readable chat, never tiny.
static var FS_TINY := 25
static var FS_SMALL := 30
static var FS_BODY := 36
static var FS_CHAT := 32
static var FS_CHAT_META := 25
static var FS_NAME := 30
static var FS_SECTION := 42
static var FS_BANNER := 34
static var FS_TITLE := 56
static var FS_BIG := 56
static var FS_HUGE := 84

## 44 CSS px at 0.54 scale = 81 reference px.
static var MIN_TAP := 84
static var BUTTON_GAP := 12

## Theme data lives in one JSON file so the palette gate (tools/check_palette.py)
## can audit the look without running the engine. Screens never hard-code colors.
const THEME_PATH := "res://themes/warm_cozy.json"
static var _theme_loaded := false


## Load the palette once, before any widget is built.
static func ensure_theme() -> void:
	if _theme_loaded:
		return
	_theme_loaded = true
	if not FileAccess.file_exists(THEME_PATH):
		push_warning("UI: missing theme file %s, using built-in defaults" % THEME_PATH)
		return
	var f := FileAccess.open(THEME_PATH, FileAccess.READ)
	if f == null:
		push_warning("UI: cannot read %s" % THEME_PATH)
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		push_warning("UI: %s is not a JSON object" % THEME_PATH)
		return
	var doc := data as Dictionary
	var colors: Dictionary = doc.get("colors", {})
	var map := {
		"BG": "bg", "PANEL": "panel", "PANEL_LIGHT": "panel_alt",
		"PANEL_LINE": "panel_line", "TEXT": "text", "TEXT_DIM": "text_dim",
		"TEXT_FAINT": "text_faint", "MINT": "mint", "MINT_DARK": "mint_dark",
		"CORAL": "coral", "CORAL_DARK": "coral_dark", "AMBER": "amber",
		"AMBER_DARK": "amber_dark", "VIOLET": "violet", "SKY": "blue",
		"GOLD": "gold",
	}
	for key in map:
		if colors.has(map[key]):
			var c := hex(String(colors[map[key]]))
			match key:
				"BG":
					BG = c
				"PANEL":
					PANEL = c
				"PANEL_LIGHT":
					PANEL_LIGHT = c
				"PANEL_LINE":
					PANEL_LINE = c
				"TEXT":
					TEXT = c
				"TEXT_DIM":
					TEXT_DIM = c
				"TEXT_FAINT":
					TEXT_FAINT = c
				"MINT":
					MINT = c
				"MINT_DARK":
					MINT_DARK = c
				"CORAL":
					CORAL = c
				"CORAL_DARK":
					CORAL_DARK = c
				"AMBER":
					AMBER = c
				"AMBER_DARK":
					AMBER_DARK = c
				"VIOLET":
					VIOLET = c
				"SKY":
					SKY = c
				"GOLD":
					GOLD = c
	var sizes: Dictionary = doc.get("font_sizes", {})
	if sizes.has("title"):
		FS_TITLE = int(sizes["title"])
		FS_BIG = int(sizes["title"])
	if sizes.has("section"):
		FS_SECTION = int(sizes["section"])
	if sizes.has("body"):
		FS_BODY = int(sizes["body"])
	if sizes.has("small"):
		FS_SMALL = int(sizes["small"])
	if sizes.has("tiny"):
		FS_TINY = int(sizes["tiny"])
	if sizes.has("chat"):
		FS_CHAT = int(sizes["chat"])
	if sizes.has("chat_meta"):
		FS_CHAT_META = int(sizes["chat_meta"])
	if sizes.has("banner"):
		FS_BANNER = int(sizes["banner"])
	if sizes.has("name"):
		FS_NAME = int(sizes["name"])
	if sizes.has("huge"):
		FS_HUGE = int(sizes["huge"])
	var metrics: Dictionary = doc.get("metrics", {})
	if metrics.has("min_tap"):
		MIN_TAP = int(metrics["min_tap"])
	if metrics.has("button_gap"):
		BUTTON_GAP = int(metrics["button_gap"])


## WCAG relative luminance, used to pick label ink that stays readable on the
## background a widget actually draws.
static func _chan(v: float) -> float:
	return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)


static func _luminance(c: Color) -> float:
	return 0.2126 * _chan(c.r) + 0.7152 * _chan(c.g) + 0.0722 * _chan(c.b)


static func contrast(a: Color, b: Color) -> float:
	var la := _luminance(a)
	var lb := _luminance(b)
	var hi := maxf(la, lb)
	var lo := minf(la, lb)
	return (hi + 0.05) / (lo + 0.05)


static func readable_fg(bg: Color) -> Color:
	return INK_DARK if contrast(bg, INK_DARK) >= contrast(bg, INK_LIGHT) else INK_LIGHT


static func build_theme() -> Theme:
	ensure_theme()
	var t := Theme.new()
	t.default_font_size = FS_BODY
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "RichTextLabel", TEXT)

	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.set_corner_radius_all(18)
	panel.set_content_margin_all(14)
	panel.border_width_left = 1
	panel.border_width_right = 1
	panel.border_width_top = 1
	panel.border_width_bottom = 1
	panel.border_color = PANEL_LINE
	t.set_stylebox("panel", "PanelContainer", panel)

	for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		match state_name:
			"hover":
				sb.bg_color = PANEL_LIGHT
			"pressed":
				sb.bg_color = Color("1a1428")
			"disabled":
				sb.bg_color = Color("1e1930")
			"focus":
				sb.bg_color = PANEL_LIGHT
			_:
				sb.bg_color = PANEL
		sb.set_corner_radius_all(14)
		sb.set_content_margin_all(12)
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_width_top = 2
		sb.border_width_bottom = 2
		sb.border_color = VIOLET if state_name == "focus" else PANEL_LINE
		t.set_stylebox(state_name, "Button", sb)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", TEXT)
	t.set_color("font_pressed_color", "Button", TEXT)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_font_size("font_size", "Button", FS_BODY + 4)
	t.set_constant("h_separation", "BoxContainer", 8)

	var scroll := StyleBoxFlat.new()
	scroll.bg_color = Color(0, 0, 0, 0)
	scroll.set_corner_radius_all(14)
	scroll.set_content_margin_all(6)
	t.set_stylebox("panel", "ScrollContainer", scroll)

	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(PANEL_LINE, 0.9)
	grab.set_corner_radius_all(4)
	grab.set_content_margin_all(2)
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab)
	t.set_stylebox("grabber_focus", "VScrollBar", grab)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())

	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = Color("120e1b")
	sb_bg.set_corner_radius_all(10)
	sb_bg.set_content_margin_all(0)
	t.set_stylebox("background", "ProgressBar", sb_bg)
	var sb_fill := StyleBoxFlat.new()
	sb_fill.bg_color = MINT
	sb_fill.set_corner_radius_all(10)
	sb_fill.set_content_margin_all(0)
	t.set_stylebox("fill", "ProgressBar", sb_fill)
	t.set_color("font_color", "ProgressBar", TEXT)
	t.set_font_size("font_size", "ProgressBar", FS_SMALL)
	return t


static func label(text: String, size: int = FS_BODY, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


static func wrap_label(text: String, size: int = FS_BODY, color: Color = TEXT) -> Label:
	var l := label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func button(text: String, size: int = FS_BODY + 2) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size.y = MIN_TAP
	b.focus_mode = Control.FOCUS_ALL
	b.flat = false
	return b


static func icon_button(text: String, glyph: String = "") -> Button:
	var b := button(glyph if glyph != "" else text, FS_BODY)
	b.text = glyph if glyph != "" else text
	b.custom_minimum_size = Vector2(MIN_TAP, MIN_TAP)
	return b


static func panel(bg: Color = PANEL, radius: int = 18, margin: int = 14,
		border: Color = PANEL_LINE) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = border
	p.add_theme_stylebox_override("panel", sb)
	return p


static func box(vertical: bool = false) -> BoxContainer:
	return VBoxContainer.new() if vertical else HBoxContainer.new()


static func spacer(min: float = 8.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(min, min)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func vspacer(min: float = 8.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, min)
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func tinted_button(text: String, base: Color, dark: Color,
		font_size: int = FS_BODY + 8) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.custom_minimum_size = Vector2(0, MIN_TAP)
	b.focus_mode = Control.FOCUS_ALL
	# The label ink is chosen from the *drawn* background, and the background is
	# the theme colour itself: darkening it here used to make ALLOW/DELETE/BAN
	# muddy and pushed the label contrast under the accessible floor.
	var ink := readable_fg(base)
	for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		match state_name:
			"hover":
				sb.bg_color = base.lightened(0.06)
			"pressed":
				sb.bg_color = base.darkened(0.14)
			"disabled":
				sb.bg_color = Color(base, 0.35)
			"focus":
				sb.bg_color = base.lightened(0.02)
			_:
				sb.bg_color = base
		sb.set_corner_radius_all(16)
		sb.set_content_margin_all(10)
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_width_top = 2
		sb.border_width_bottom = 2
		sb.border_color = base.lerp(TEXT, 0.35) if state_name != "focus" else Color.WHITE
		b.add_theme_stylebox_override(state_name, sb)
	for state_name in ["font_color", "font_hover_color", "font_pressed_color",
				"font_focus_color", "font_disabled_color"]:
		b.add_theme_color_override(state_name, ink if state_name != "font_disabled_color"
				else Color(ink, 0.6))
	return b


static func hex(color: String) -> Color:
	return Color.from_string(color, Color("cfd8e3"))


static func clamp_text(s: String, max_chars: int) -> String:
	if s.length() <= max_chars:
		return s
	return s.substr(0, maxi(0, max_chars - 1)) + "…"
