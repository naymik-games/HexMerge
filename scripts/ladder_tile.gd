class_name LadderTile
extends HexTile

# Tile for Hex Ladder. Same look as HexTile (raised hex, gloss, bold number), but colored
# by where its value sits between the floor and the best tile reached, so a run reads as a
# smooth blue -> teal -> green -> yellow -> orange -> red -> magenta staircase at a glance.
# Tiles under the floor become dead gray blocks: no number, never part of a run.

# Shared ramp window, kept up to date by ladder_main.gd (see _refresh_ramp)
static var ramp_low: int = 1
static var ramp_high: int = 5

const DEAD_COLOR: Color = Color("#4a4a50")
const RAMP_SATURATION: float = 0.62
const RAMP_VALUE: float = 0.90
const RAMP_HUE_START: float = 0.62      # blue
const RAMP_HUE_SPAN: float = 0.72       # sweeps down through teal, green, yellow, orange, red to magenta

var is_dead: bool = false


func _init(p_value: int = 1, p_radius: float = 36.0) -> void:
	super(p_value, p_radius)


func set_dead(dead: bool) -> void:
	if is_dead == dead:
		return
	is_dead = dead
	update_visuals()


# Overrides HexTile.update_visuals (HexTile calls it from _ready and set_value)
func update_visuals() -> void:
	if label == null or polygon == null:
		return # not built yet; _ready() will call us again

	var base := DEAD_COLOR if is_dead else ladder_color(value)

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
	gloss.visible = not is_dead

	# Number (dead blocks stay blank)
	label.text = "" if is_dead else str(value)
	label.add_theme_color_override("font_outline_color", base.darkened(0.55))
	label.add_theme_font_size_override("font_size", 23 if value >= 100 else 26)


static func ladder_color(v: int) -> Color:
	var span: float = float(maxi(ramp_high - ramp_low, 1))
	var t: float = clampf(float(v - ramp_low) / span, 0.0, 1.0)
	return Color.from_hsv(fposmod(RAMP_HUE_START - t * RAMP_HUE_SPAN, 1.0), RAMP_SATURATION, RAMP_VALUE)
