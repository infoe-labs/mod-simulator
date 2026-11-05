class_name ScrollPage
extends ScrollContainer

## A bounded, touch-scrollable page shared by menus and long-form screens.
## The viewport stays fixed while its content grows vertically.
const MAX_WIDTH := 960.0
var content: VBoxContainer
var _margin: MarginContainer
var _padding: int


func _init(padding: int = 24) -> void:
	_padding = padding
	name = "PageScroll"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll_deadzone = 12
	follow_focus = true
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_margin = MarginContainer.new()
	_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_margin)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	_margin.add_child(content)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_fit)
	_fit()


func _fit() -> void:
	var router := get_node_or_null("/root/Main")
	var safe: Dictionary = router.get("safe") if router != null else {"left": 0, "right": 0, "top": 0, "bottom": 0}
	var extra := maxf(0.0, (size.x - MAX_WIDTH) * 0.5)
	_margin.add_theme_constant_override("margin_left", _padding + int(safe["left"] + extra))
	_margin.add_theme_constant_override("margin_right", _padding + int(safe["right"] + extra))
	_margin.add_theme_constant_override("margin_top", _padding + int(safe["top"]))
	_margin.add_theme_constant_override("margin_bottom", _padding + int(safe["bottom"]))
