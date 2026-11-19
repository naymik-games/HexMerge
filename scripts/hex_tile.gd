class_name HexTile
extends Node2D

var value: int = 2
var radius: float = 36.0
var axial_coord: Vector2i = Vector2i.ZERO

var polygon: Polygon2D
var border: Line2D
var label: Label

# Color palette inspired by the screenshot and standard merge games
const TILE_COLORS = {
	2: Color("#7c69ef"),    # Purple
	4: Color("#38a3d1"),    # Cyan/Blue
	8: Color("#36b37e"),    # Green
	16: Color("#f5a623"),   # Orange
	32: Color("#e056fd"),   # Magenta
	64: Color("#eb4d4b"),   # Red
	128: Color("#f9ca24"),  # Yellow
	256: Color("#6ab04c"),  # Lime
	512: Color("#22a6b3"),  # Teal
	1024: Color("#be2edd"), # Deep Violet
	2048: Color("#ff7979")  # Coral
}

func _init(p_value: int = 2, p_radius: float = 36.0) -> void:
	value = p_value
	radius = p_radius

func _ready() -> void:
	# 1. Create Hexagon Fill
	polygon = Polygon2D.new()
	polygon.polygon = _create_hex_points(radius - 2.0) # Slight inset for gap
	add_child(polygon)
	
	# 2. Create Subtle Outline
	border = Line2D.new()
	var pts = _create_hex_points(radius - 2.0)
	pts.append(pts[0]) # Close loop
	border.points = pts
	border.width = 2.0
	border.default_color = Color(1, 1, 1, 0.25)
	add_child(border)
	
	# 3. Create Number Label
	label = Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.4))
	label.add_theme_constant_override("outline_size", 3)
	
	# Center label over origin
	label.size = Vector2(radius * 2, radius * 2)
	label.position = Vector2(-radius, -radius)
	add_child(label)
	
	update_visuals()

func set_value(new_val: int) -> void:
	value = new_val
	update_visuals()
	
	# Pop animation on value upgrade
	var tween = create_tween()
	tween.tween_property(self, "scale", Vector2(1.25, 1.25), 0.1)
	tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.1)

func update_visuals() -> void:
	if not is_inside_tree():
		return
	label.text = str(value)
	
	# Adjust font size for larger numbers
	if value >= 1000:
		label.add_theme_font_size_override("font_size", 16)
	elif value >= 100:
		label.add_theme_font_size_override("font_size", 19)
	else:
		label.add_theme_font_size_override("font_size", 22)
		
	polygon.color = TILE_COLORS.get(value, Color("#30336b"))

# Generates vertices for a pointy-topped hexagon
static func _create_hex_points(r: float) -> PackedVector2Array:
	var points = PackedVector2Array()
	for i in range(6):
		var angle_deg = 60.0 * i - 30.0
		var angle_rad = deg_to_rad(angle_deg)
		points.append(Vector2(r * cos(angle_rad), r * sin(angle_rad)))
	return points
