class_name HexTile
extends Node2D

var value: int = 2
var radius: float = 36.0
var axial_coord: Vector2i = Vector2i.ZERO

var polygon: Polygon2D   # main face (main.gd reads polygon.color for particles)
var depth: Polygon2D     # darker copy peeking out below the face for a raised look
var gloss: Polygon2D     # soft sheen on the upper half
var label: Label
var _pop_tween: Tween

var _face_points: PackedVector2Array

# --- STYLE KNOBS ---
const CORNER_RATIO: float = 0.24     # corner radius as a fraction of tile radius (0 = sharp)
const DEPTH_PX: float = 4.0          # how far the darker "base" shows below the face
const GLOSS_ALPHA: float = 0.30      # sheen strength at the top of the tile
const FACE_LIGHTEN: float = 0.14     # top of the gradient
const FACE_DARKEN: float = 0.12      # bottom of the gradient

# Color palette inspired by standard merge games
const TILE_COLORS: Dictionary = {
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

static var _bold_font: FontVariation


func _init(p_value: int = 2, p_radius: float = 36.0) -> void:
	value = p_value
	radius = p_radius


func _ready() -> void:
	var r := radius - 2.0 # slight inset for a gap between tiles
	_face_points = create_rounded_hex_points(r)

	# 1. Depth layer (drawn first, sits slightly lower)
	depth = Polygon2D.new()
	depth.polygon = _face_points
	depth.position = Vector2(0, DEPTH_PX)
	add_child(depth)

	# 2. Face with a vertical gradient (vertex colors are set in update_visuals)
	polygon = Polygon2D.new()
	polygon.polygon = _face_points
	add_child(polygon)

	# 3. Gloss: the upper half of a smaller rounded hex, fading to clear at the middle
	var gloss_r := r * 0.82
	var gloss_pts := create_rounded_hex_points(gloss_r)
	var gloss_cols := PackedColorArray()
	for i in range(gloss_pts.size()):
		var p := gloss_pts[i]
		p.y = minf(p.y, 0.0) # flatten the lower half onto the center line
		gloss_pts[i] = p
		gloss_cols.append(Color(1, 1, 1, clampf(-p.y / gloss_r, 0.0, 1.0) * GLOSS_ALPHA))
	gloss = Polygon2D.new()
	gloss.polygon = gloss_pts
	gloss.vertex_colors = gloss_cols
	gloss.position = Vector2(0, -2)
	add_child(gloss)

	# 4. Chunky number: bold font, tinted outline, soft drop shadow
	label = Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", get_bold_font())
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_constant_override("outline_size", 6)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.3))
	label.add_theme_constant_override("shadow_offset_x", 0)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.size = Vector2(radius * 2.0, radius * 2.0)
	label.position = Vector2(-radius, -radius)
	add_child(label)

	update_visuals()


func set_value(new_val: int) -> void:
	value = new_val
	update_visuals()

	# Pop animation on value upgrade (restart cleanly if one is already running)
	if _pop_tween and _pop_tween.is_valid():
		_pop_tween.kill()
	scale = Vector2.ONE
	_pop_tween = create_tween()
	_pop_tween.tween_property(self, "scale", Vector2(1.25, 1.25), 0.1)
	_pop_tween.tween_property(self, "scale", Vector2.ONE, 0.1)


func update_visuals() -> void:
	if label == null or polygon == null:
		return # not built yet; _ready() will call us again

	var base := color_for_value(value)

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
	if value >= 10000:
		font_size = 15
	elif value >= 1000:
		font_size = 19
	elif value >= 100:
		font_size = 23
	label.add_theme_font_size_override("font_size", font_size)


# Palette color if known, otherwise a stable generated color so tiles past 2048 still look distinct
static func color_for_value(v: int) -> Color:
	if TILE_COLORS.has(v):
		return TILE_COLORS[v]
	var power: float = log(float(maxi(v, 1))) / log(2.0)
	return Color.from_hsv(fmod(power * 0.137, 1.0), 0.55, 0.85)


static func get_bold_font() -> FontVariation:
	if _bold_font == null:
		_bold_font = FontVariation.new()
		_bold_font.base_font = ThemeDB.fallback_font
		_bold_font.variation_embolden = 0.8
	return _bold_font


# Vertices for a sharp pointy-topped hexagon
static func create_hex_points(r: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(6):
		var angle_rad := deg_to_rad(60.0 * i - 30.0)
		points.append(Vector2(r * cos(angle_rad), r * sin(angle_rad)))
	return points


# Pointy-topped hexagon with rounded corners. The outer size (edge distance) matches
# create_hex_points(r); only the corners are softened. corner < 0 uses CORNER_RATIO.
static func create_rounded_hex_points(r: float, corner: float = -1.0, steps: int = 5) -> PackedVector2Array:
	if corner < 0.0:
		corner = r * CORNER_RATIO
	var points := PackedVector2Array()
	# Each corner is an arc of radius `corner`; its center sits on the line from the hex center
	# to the vertex, pulled inward so the arc is tangent to both neighboring edges.
	var center_dist := r - corner / sin(deg_to_rad(60.0))
	for i in range(6):
		var a := deg_to_rad(60.0 * i - 30.0)
		var c := Vector2(cos(a), sin(a)) * center_dist
		for s in range(steps + 1):
			var phi := a + deg_to_rad(-30.0 + 60.0 * float(s) / float(steps))
			points.append(c + Vector2(cos(phi), sin(phi)) * corner)
	return points
