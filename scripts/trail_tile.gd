class_name TrailTile
extends HexTile

# Hex Trail tile. Same look as HexTile (rounded hex, depth, gloss, bold number),
# but values count up 1, 2, 3... instead of doubling, so the palette is indexed by value.
# HexTile itself is not modified: this only overrides how the color and number size are chosen.

# Same colors as HexTile's palette, in the same order (value 1 = purple like the original's 2)
const TRAIL_COLORS: Array[Color] = [
	Color("#7c69ef"),  # 1  Purple
	Color("#38a3d1"),  # 2  Cyan/Blue
	Color("#36b37e"),  # 3  Green
	Color("#f5a623"),  # 4  Orange
	Color("#e056fd"),  # 5  Magenta
	Color("#eb4d4b"),  # 6  Red
	Color("#f9ca24"),  # 7  Yellow
	Color("#6ab04c"),  # 8  Lime
	Color("#22a6b3"),  # 9  Teal
	Color("#be2edd"),  # 10 Deep Violet
	Color("#ff7979"),  # 11 Coral
]


func _init(p_value: int = 1, p_radius: float = 36.0) -> void:
	super(p_value, p_radius)


# Same drawing as HexTile.update_visuals, but with the counting palette and number sizes
func update_visuals() -> void:
	if label == null or polygon == null:
		return # not built yet; _ready() will call us again

	var base := trail_color_for_value(value)

	# Face: lighter at the top, darker at the bottom
	var top := base.lightened(FACE_LIGHTEN)
	var bottom := base.darkened(FACE_DARKEN)
	var r := radius - 2.0
	var cols := PackedColorArray()
	for p in _face_points:
		cols.append(top.lerp(bottom, clampf((p.y + r) / (2.0 * r), 0.0, 1.0)))
	polygon.color = base
	polygon.vertex_colors = cols
	depth.color = base.darkened(0.4)

	# Number
	label.text = str(value)
	label.add_theme_color_override("font_outline_color", base.darkened(0.55))
	var font_size: int = 26
	if value >= 100:
		font_size = 20
	elif value >= 10:
		font_size = 24
	label.add_theme_font_size_override("font_size", font_size)


# Palette color for 1..11, otherwise a stable generated color so higher tiles stay distinct
static func trail_color_for_value(v: int) -> Color:
	if v >= 1 and v <= TRAIL_COLORS.size():
		return TRAIL_COLORS[v - 1]
	return Color.from_hsv(fmod(float(v) * 0.137, 1.0), 0.55, 0.85)
