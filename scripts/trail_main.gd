extends Node2D

# =============================================================================
# HEX TRAIL - draw-to-place variation of Hex Merge
#
# A tray under the board holds 1-4 numbered tiles. Touch an empty cell and drag
# through adjacent empty cells: each cell crossed receives the next tray tile.
# Release a finished trail to place it. Every placed tile then looks for a group
# of 3+ matching tiles, which merges into the next higher number (3 ones -> a 2).
#
# Separate game, same app, launched from the home screen (GameHub). It reuses HexTile
# (through TrailTile), SoundFX and SaveManager: gems, sound, haptics and the daily reward
# are shared app-wide, while its run save and best score are stored under GAME_ID.
#
# Layout of this file:
#   1. Config / state
#   2. Lifecycle & persistence helpers
#   3. Layout & scene setup (world layer + UI CanvasLayer)
#   4. Board math & trail search
#   5. Tray (spawn / reverse)
#   6. Input & trail drawing
#   7. Placement & merge resolution
#   8. Level / gems / power-ups
#   9. Game over, save / restore / new game
#  10. UI builders, modals, juice
# =============================================================================

# --- CONFIGURATION ---
const GRID_RADIUS: int = 3                  # 3 rings around center = 37 hexes
const HEX_RADIUS: float = 36.0
const SQRT3: float = 1.7320508075688772
const NEIGHBOR_DIST: float = HEX_RADIUS * SQRT3   # center-to-center distance of adjacent hexes
const BG_COLOR: Color = Color("#242426")

const GEMS_PER_LEVEL_UP: int = 25
const HAMMER_COST: int = 100
const REROLL_COST: int = 175

# Level progress is driven by merges (chains give more XP via the combo multiplier)
const XP_PER_MERGE: int = 12
const START_XP_TO_LEVEL: int = 100
const XP_GROWTH: float = 1.2

# --- TRAIL / TRAY RULES (tuning knobs) ---
const MAX_TRAY_SIZE: int = 4
const TRAY_DUP_CHANCE: float = 0.4          # chance a tray tile copies the one before it (sets up triples)
const AUTO_SHRINK_TRAY: bool = true         # true: a tray too long for the free space is shortened; false: game over
const MERGE_MIN_CLUSTER: int = 3            # matching group needed after a placement
const CHAIN_MIN_CLUSTER: int = 2            # a merged tile touching an equal tile merges with just 2 (as in the original)
const BIG_GROUP_SIZE: int = 5               # a group this big jumps two values instead of one
const START_HIGHEST_TILE: int = 4           # spawn window starts at 1..4
const SPAWN_LAG: int = 5                    # spawn window floor = highest tile reached - this (min 1)
const TRAIL_LIFT: Vector2 = Vector2.ZERO    # set to e.g. (0, -40) to read the cell above the fingertip

# --- TRAY LAYOUT ---
const TRAY_TILE_SCALE: float = 0.78
const TRAY_SPACING: float = NEIGHBOR_DIST * 0.82
const TRAY_TILE_Y: float = -5.0
const TRAY_HALF_WIDTH: float = 128.0
const TRAY_HALF_HEIGHT: float = 44.0

# --- TIMING ---
const PLACE_TIME: float = 0.12
const PLACE_STAGGER: float = 0.06
const UI_MARGIN: float = 16.0

# --- COLORS ---
const SLOT_COLOR: Color = Color("#333336")
const SLOT_TRAIL_COLOR: Color = Color("#505056")
const SLOT_NEXT_COLOR: Color = Color("#3d3d42")
const SLOT_HAMMER_COLOR: Color = Color("#6e3535")
const GHOST_MODULATE: Color = Color(1, 1, 1, 0.82)
const GHOST_MERGE_MODULATE: Color = Color(1.3, 1.3, 1.3, 0.95)

# --- SAVE SLOT (see SaveManager / GameHub.GAMES) ---
const GAME_ID: String = "hextrail"

# Axial directions for pointy-topped hexes, in clockwise order starting East
const AXIAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),   # East
	Vector2i(0, 1),   # Southeast
	Vector2i(-1, 1),  # Southwest
	Vector2i(-1, 0),  # West
	Vector2i(0, -1),  # Northwest
	Vector2i(1, -1)   # Northeast
]

# --- LAYOUT (computed at runtime for any aspect ratio + notch) ---
var screen_size: Vector2 = Vector2(540, 960)
var safe_top_y: float = 40.0
var safe_bottom_y: float = 940.0
var board_center: Vector2 = Vector2(270, 440)
var dock_center: Vector2 = Vector2(270, 790)

# --- SCENE LAYERS / JUICE ---
var ui_layer: CanvasLayer
var camera: Camera2D
var shake_tween: Tween

# --- BOARD STATE ---
var board_tiles: Dictionary = {}    # Vector2i -> TrailTile (null if empty)
var slot_visuals: Dictionary = {}   # Vector2i -> Polygon2D (background hexes)
var previewed_tiles: Array[TrailTile] = []
var placed_order: Dictionary = {}   # Vector2i -> index within the current trail (decides where merges land)

# --- RUN STATE ---
var score: int = 0
var best_score: int = 0
var best_dirty: bool = false
var highest_tile_reached: int = START_HIGHEST_TILE
var is_game_over: bool = false
var busy: bool = false              # true while placing / merging / rerolling: blocks all input

# --- TRAY ---
var tray_holder: Node2D
var tray_tiles: Array[TrailTile] = []

# --- TRAIL (the drag in progress) ---
var is_tracing: bool = false
var trail_cells: Array[Vector2i] = []
var trail_ghosts: Array[TrailTile] = []
var trail_holder: Node2D
var trail_line: Line2D
var last_trail_pointer: Vector2 = Vector2.ZERO

# --- LEVEL / GEMS / POWER-UPS ---
var current_level: int = 1
var level_xp: int = 0
var xp_to_next_level: int = START_XP_TO_LEVEL
var gems: int = 0
var is_hammer_mode: bool = false
var bar_tween: Tween
var gem_tween: Tween

# --- UI REFERENCES ---
var progress_bar: ProgressBar
var curr_lvl_label: Label
var next_lvl_label: Label
var gems_label: Label
var score_label: Label
var best_score_label: Label
var hammer_button: Button
var reroll_button: Button
var hammer_hint_label: Label
var game_over_panel: Panel
var game_over_sub_label: Label
var settings_overlay: ColorRect
var daily_overlay: ColorRect
var sound_toggle_btn: Button
var haptics_toggle_btn: Button
var claim_daily_btn: Button
var daily_status_label: Label
var calendar_badge: Panel


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	RenderingServer.set_default_clear_color(BG_COLOR)
	_compute_responsive_layout()
	_load_persistent_state()
	_create_layers()
	_setup_header_ui()
	_setup_gem_ui()
	_setup_level_bar()
	_setup_game_over_ui()
	_setup_tray()
	_setup_powerup_ui()
	_build_board()
	_setup_trail_layer()
	_setup_camera()
	_setup_modals()
	_begin_session()


func _notification(what: int) -> void:
	# Mobile OSes can kill the app right after it is backgrounded, so save here
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_game()
		_flush_best_score()


# =============================================================================
# PERSISTENT META (gems, settings, best score)
# =============================================================================

func _load_persistent_state() -> void:
	var meta: Dictionary = SaveManager.read_meta()
	gems = int(meta.get("gems", 0))
	SoundFX.is_muted = not bool(meta.get("sound_enabled", true))
	SoundFX.haptics_enabled = bool(meta.get("haptics_enabled", true))
	best_score = SaveManager.get_best_score(GAME_ID)


func _write_meta_value(key: String, value: Variant) -> void:
	var meta: Dictionary = SaveManager.read_meta()
	meta[key] = value
	SaveManager.write_meta(meta)


func _persist_gems() -> void:
	_write_meta_value("gems", gems)


# Best score is tracked in memory and only written to disk when it matters
func _flush_best_score() -> void:
	if best_dirty:
		best_score = SaveManager.update_best_score(best_score, GAME_ID)
		best_dirty = false


# =============================================================================
# LAYOUT & SCENE SETUP
# =============================================================================

func _compute_responsive_layout() -> void:
	screen_size = get_viewport_rect().size

	# Convert hardware safe area (OS screen pixels) into Godot canvas coordinates
	var window_size := Vector2(DisplayServer.window_get_size())
	var safe_rect := Rect2(DisplayServer.get_display_safe_area())

	var top_inset: float = 16.0
	var bottom_inset: float = 20.0

	if window_size.x > 0.0 and window_size.y > 0.0:
		var scale_y := screen_size.y / window_size.y
		top_inset = maxf(safe_rect.position.y * scale_y, 16.0)
		var raw_bottom := (window_size.y - (safe_rect.position.y + safe_rect.size.y)) * scale_y
		bottom_inset = maxf(raw_bottom, 20.0)

	safe_top_y = top_inset + 12.0
	safe_bottom_y = screen_size.y - bottom_inset

	var center_x := screen_size.x * 0.5
	dock_center = Vector2(center_x, safe_bottom_y - 135.0)

	# Center the board midway between the level bar and the tray
	var header_bottom := safe_top_y + 115.0
	var dock_top := dock_center.y - 110.0
	board_center = Vector2(center_x, (header_bottom + dock_top) * 0.5)


func _create_layers() -> void:
	# Background lives on its own layer so camera shake never reveals its edges
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.size = screen_size
	bg_layer.add_child(bg)

	# All HUD / modal controls live here so they don't shake with the board
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 1
	add_child(ui_layer)


func _setup_camera() -> void:
	camera = Camera2D.new()
	camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	camera.position = Vector2.ZERO
	camera.offset = Vector2.ZERO
	add_child(camera)


func _setup_tray() -> void:
	# Pill behind the tiles (world space, so the tiles draw on top of it)
	var pill := Polygon2D.new()
	pill.polygon = _rounded_rect_points(Vector2(TRAY_HALF_WIDTH * 2.0, TRAY_HALF_HEIGHT * 2.0), 30.0)
	pill.color = Color("#18181a")
	pill.position = dock_center
	add_child(pill)

	# Direction guide along the bottom of the pill: tray order runs left to right
	var guide_y := TRAY_HALF_HEIGHT - 9.0
	var guide := Line2D.new()
	guide.position = dock_center
	guide.points = PackedVector2Array([
		Vector2(-TRAY_HALF_WIDTH + 34.0, guide_y), Vector2(TRAY_HALF_WIDTH - 40.0, guide_y)
	])
	guide.width = 3.0
	guide.default_color = Color("#3a3a3d")
	add_child(guide)

	var guide_head := Polygon2D.new()
	guide_head.polygon = PackedVector2Array([Vector2(-6, -5), Vector2(6, 0), Vector2(-6, 5)])
	guide_head.color = Color("#3a3a3d")
	guide_head.position = dock_center + Vector2(TRAY_HALF_WIDTH - 34.0, guide_y)
	add_child(guide_head)

	tray_holder = Node2D.new()
	tray_holder.position = dock_center
	add_child(tray_holder)

	ui_layer.add_child(_make_label("TAP TRAY TO REVERSE ORDER",
			Vector2(dock_center.x - 130.0, dock_center.y + TRAY_HALF_HEIGHT + 6.0), Vector2(260, 18),
			12, Color("#7a7a82")))


func _setup_trail_layer() -> void:
	# Ghost tiles and the path line live above the board slots and placed tiles
	trail_holder = Node2D.new()
	trail_holder.z_index = 5
	add_child(trail_holder)

	trail_line = Line2D.new()
	trail_line.width = 8.0
	trail_line.default_color = Color(1, 1, 1, 0.28)
	trail_line.joint_mode = Line2D.LINE_JOINT_ROUND
	trail_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	trail_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	trail_holder.add_child(trail_line)


func _build_board() -> void:
	for q in range(-GRID_RADIUS, GRID_RADIUS + 1):
		var r1: int = maxi(-GRID_RADIUS, -q - GRID_RADIUS)
		var r2: int = mini(GRID_RADIUS, -q + GRID_RADIUS)
		for r in range(r1, r2 + 1):
			var coord := Vector2i(q, r)
			board_tiles[coord] = null

			var slot := Polygon2D.new()
			slot.polygon = HexTile.create_rounded_hex_points(HEX_RADIUS - 2.0)
			slot.color = SLOT_COLOR
			slot.position = axial_to_pixel(coord)
			add_child(slot)
			slot_visuals[coord] = slot


# Rounded rectangle centered on the origin (used for the tray pill)
func _rounded_rect_points(rect_size: Vector2, corner: float, steps: int = 8) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var hx := rect_size.x * 0.5
	var hy := rect_size.y * 0.5
	var centers: Array[Vector2] = [
		Vector2(hx - corner, hy - corner),     # bottom-right
		Vector2(-hx + corner, hy - corner),    # bottom-left
		Vector2(-hx + corner, -hy + corner),   # top-left
		Vector2(hx - corner, -hy + corner)     # top-right
	]
	for k in range(4):
		for s in range(steps + 1):
			var a := deg_to_rad(90.0 * float(k) + 90.0 * float(s) / float(steps))
			pts.append(centers[k] + Vector2(cos(a), sin(a)) * corner)
	return pts


# =============================================================================
# BOARD MATH & TRAIL SEARCH
# =============================================================================

func axial_to_pixel(hex: Vector2i) -> Vector2:
	var x := NEIGHBOR_DIST * (hex.x + hex.y / 2.0)
	var y := HEX_RADIUS * 1.5 * hex.y
	return board_center + Vector2(x, y)


func pixel_to_axial(pos: Vector2) -> Vector2i:
	var pt := pos - board_center
	var q := (SQRT3 / 3.0 * pt.x - 1.0 / 3.0 * pt.y) / HEX_RADIUS
	var r := (2.0 / 3.0 * pt.y) / HEX_RADIUS
	return axial_round(Vector2(q, r))


func axial_round(frac: Vector2) -> Vector2i:
	var s := -frac.x - frac.y
	var rq := roundf(frac.x)
	var rr := roundf(frac.y)
	var rs := roundf(s)

	var q_diff := absf(rq - frac.x)
	var r_diff := absf(rr - frac.y)
	var s_diff := absf(rs - s)

	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))


func _board_has_tiles() -> bool:
	for tile in board_tiles.values():
		if tile != null:
			return true
	return false


func _is_free_cell(coord: Vector2i) -> bool:
	return board_tiles.has(coord) and board_tiles[coord] == null


func _fill_ratio() -> float:
	var filled: int = 0
	for tile in board_tiles.values():
		if tile != null:
			filled += 1
	return float(filled) / float(maxi(board_tiles.size(), 1))


# Value at a cell, optionally overlaid with not-yet-placed tiles (-1 = empty / off board)
func _value_at(coord: Vector2i, overlay: Dictionary) -> int:
	if overlay.has(coord):
		return int(overlay[coord])
	var tile: TrailTile = board_tiles.get(coord)
	return tile.value if tile != null else -1


# Flood-fill to find all connected tiles of the same value (start is always first).
# The overlay lets the merge preview ask "what if these tiles were placed?" without touching the board.
func _find_connected_cluster(start: Vector2i, target_val: int, overlay: Dictionary = {}) -> Array[Vector2i]:
	var cluster: Array[Vector2i] = [start]
	var visited: Dictionary = {start: true}
	var i: int = 0
	while i < cluster.size():
		var curr: Vector2i = cluster[i]
		i += 1
		for dir in AXIAL_DIRECTIONS:
			var neighbor: Vector2i = curr + dir
			if visited.has(neighbor) or not board_tiles.has(neighbor):
				continue
			if _value_at(neighbor, overlay) == target_val:
				visited[neighbor] = true
				cluster.append(neighbor)
	return cluster


# True if some chain of `length` touching empty cells exists (a trail that long can be drawn)
func _has_empty_path(length: int) -> bool:
	if length <= 0:
		return true
	for key in board_tiles.keys():
		var coord: Vector2i = key
		if board_tiles[coord] == null and _path_extends(coord, length - 1, {coord: true}):
			return true
	return false


func _path_extends(from: Vector2i, remaining: int, visited: Dictionary) -> bool:
	if remaining == 0:
		return true
	for dir in AXIAL_DIRECTIONS:
		var next_cell: Vector2i = from + dir
		if visited.has(next_cell) or not _is_free_cell(next_cell):
			continue
		visited[next_cell] = true
		if _path_extends(next_cell, remaining - 1, visited):
			return true
		visited.erase(next_cell)
	return false


# Longest drawable trail up to `cap` cells (0 means the board is full)
func _longest_empty_path(cap: int) -> int:
	for length in range(cap, 0, -1):
		if _has_empty_path(length):
			return length
	return 0


# =============================================================================
# TRAY
# =============================================================================

# Smallest value in the active 4-value spawn window, based on the best tile reached
func _spawn_base_value() -> int:
	return maxi(1, highest_tile_reached - SPAWN_LAG)


func _pick_random_value() -> int:
	var lo := _spawn_base_value()
	# Weighted distribution favoring the lower values of the window
	var pool: Array[int] = [lo, lo, lo, lo + 1, lo + 1, lo + 2, lo + 3]
	return pool[randi() % pool.size()]


# Long trays early, short trays as the board fills (the difficulty dial)
func _pick_tray_length() -> int:
	var fill := _fill_ratio()
	var pool: Array[int]
	if fill < 0.35:
		pool = [2, 3, 3, 4, 4]
	elif fill < 0.6:
		pool = [2, 2, 3, 3, 4]
	elif fill < 0.8:
		pool = [1, 2, 2, 3]
	else:
		pool = [1, 1, 2, 2]
	return pool[randi() % pool.size()]


func _make_tray_values() -> Array[int]:
	var length := mini(_pick_tray_length(), MAX_TRAY_SIZE)
	if AUTO_SHRINK_TRAY:
		# Never deal a tray that cannot be drawn; a full board still gets 1 tile (and ends the game)
		length = maxi(_longest_empty_path(length), 1)
	var values: Array[int] = []
	for i in range(length):
		if i > 0 and randf() < TRAY_DUP_CHANCE:
			values.append(values[i - 1])
		else:
			values.append(_pick_random_value())
	return values


func _spawn_tray() -> void:
	_build_tray(_make_tray_values(), true)
	_finish_tray_setup(true)


func _tray_slot_pos(index: int, count: int) -> Vector2:
	return Vector2((float(index) - float(count - 1) * 0.5) * TRAY_SPACING, TRAY_TILE_Y)


# Builds the tray tiles. Used for both fresh spawns and restoring a save.
func _build_tray(values: Array[int], animate: bool) -> void:
	for old_tile in tray_tiles:
		if is_instance_valid(old_tile):
			old_tile.queue_free()
	tray_tiles.clear()
	tray_holder.scale = Vector2.ONE

	for i in range(values.size()):
		var tile := TrailTile.new(values[i], HEX_RADIUS)
		tray_holder.add_child(tile)
		tile.position = _tray_slot_pos(i, values.size())
		tile.scale = Vector2.ONE * TRAY_TILE_SCALE
		tray_tiles.append(tile)

		if animate:
			tile.scale = Vector2.ZERO
			var pop := tile.create_tween()
			pop.tween_interval(0.05 * float(i))
			pop.tween_property(tile, "scale", Vector2.ONE * TRAY_TILE_SCALE, 0.16) \
					.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _finish_tray_setup(save_after: bool) -> void:
	if _can_place_tray():
		_set_game_over(false)
		if save_after:
			_save_game()
	else:
		_set_game_over(true)
	_update_powerup_buttons()


func _can_place_tray() -> bool:
	return _has_empty_path(tray_tiles.size())


# Tapping the tray flips the order the tiles will be placed in (the Trail's version of rotating)
func _reverse_tray() -> void:
	var count := tray_tiles.size()
	if count < 2:
		return
	tray_tiles.reverse()
	for i in range(count):
		var tile := tray_tiles[i]
		var tween := tile.create_tween()
		tween.tween_property(tile, "position", _tray_slot_pos(i, count), 0.14) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	SoundFX.play_rotate()
	_save_game()


func _pointer_in_tray(pos: Vector2) -> bool:
	return absf(pos.x - dock_center.x) <= TRAY_HALF_WIDTH and absf(pos.y - dock_center.y) <= TRAY_HALF_HEIGHT


# =============================================================================
# INPUT (drag on board = draw trail, tap tray = reverse, hammer mode = tap a tile)
# =============================================================================

func _any_overlay_open() -> bool:
	return settings_overlay.visible or daily_overlay.visible


func _input(event: InputEvent) -> void:
	# Ignore the board entirely while tiles animate or a menu is open
	if busy or _any_overlay_open():
		return
	# At game over only the hammer can interact with the board
	if is_game_over and not is_hammer_mode:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var pointer_pos := get_global_mouse_position()
		if event.pressed:
			if is_hammer_mode:
				var hammer_coord := pixel_to_axial(pointer_pos)
				if board_tiles.get(hammer_coord) != null:
					_use_hammer_on_coord(hammer_coord)
				return
			if _pointer_in_tray(pointer_pos):
				_reverse_tray()
				return
			_begin_trail(pointer_pos + TRAIL_LIFT)
		elif is_tracing:
			_end_trail()

	elif event is InputEventMouseMotion and is_tracing:
		_extend_trail_to(get_global_mouse_position() + TRAIL_LIFT)


func _begin_trail(pos: Vector2) -> void:
	if tray_tiles.is_empty():
		return
	var coord := pixel_to_axial(pos)
	if not _is_free_cell(coord):
		return
	is_tracing = true
	trail_cells.clear()
	trail_cells.append(coord)
	last_trail_pointer = pos
	SoundFX.trigger_haptic(10)
	_refresh_trail_visuals()


# Walks the pointer's path in small steps so a fast swipe cannot skip over cells
func _extend_trail_to(pos: Vector2) -> void:
	var from := last_trail_pointer
	var steps: int = maxi(1, int(ceil(from.distance_to(pos) / (HEX_RADIUS * 0.5))))
	var changed: bool = false
	for s in range(1, steps + 1):
		var sample := from.lerp(pos, float(s) / float(steps))
		if _step_trail(pixel_to_axial(sample)):
			changed = true
	last_trail_pointer = pos
	if changed:
		_refresh_trail_visuals()


# Tries to move the trail head onto `coord`. Returns true if the trail changed.
func _step_trail(coord: Vector2i) -> bool:
	var head: Vector2i = trail_cells[trail_cells.size() - 1]
	if coord == head:
		return false

	# Dragging back onto the previous cell undoes the last step
	if trail_cells.size() >= 2 and coord == trail_cells[trail_cells.size() - 2]:
		trail_cells.pop_back()
		SoundFX.play_rotate()
		return true

	if trail_cells.size() >= tray_tiles.size():
		return false
	if not AXIAL_DIRECTIONS.has(coord - head):
		return false
	if not _is_free_cell(coord) or trail_cells.has(coord):
		return false

	trail_cells.append(coord)
	SoundFX.play_rotate()
	SoundFX.trigger_haptic(8)
	return true


func _end_trail() -> void:
	is_tracing = false
	if trail_cells.size() == tray_tiles.size():
		_commit_trail()
		return

	# Not enough cells: nothing is placed, the tiles stay in the tray
	if trail_cells.size() >= 1:
		_spawn_floating_text(dock_center + Vector2(0, -70), "DRAW %d TILES" % tray_tiles.size(),
				Color("#9a9aa2"), 16)
	_clear_trail()


func _clear_trail() -> void:
	_clear_preview()
	for ghost in trail_ghosts:
		if is_instance_valid(ghost):
			ghost.queue_free()
	trail_ghosts.clear()
	trail_cells.clear()
	if trail_line:
		trail_line.points = PackedVector2Array()
	for tray_tile in tray_tiles:
		if is_instance_valid(tray_tile):
			tray_tile.modulate = Color.WHITE
	_refresh_slot_colors()


# Redraws everything that depends on the trail: ghost tiles, path line, dimmed tray tiles, slots
func _refresh_trail_visuals() -> void:
	var count := trail_cells.size()

	# One ghost per trail cell, showing the tray tile that will land there
	while trail_ghosts.size() > count:
		var old_ghost: TrailTile = trail_ghosts.pop_back()
		old_ghost.queue_free()
	while trail_ghosts.size() < count:
		var idx := trail_ghosts.size()
		var ghost := TrailTile.new(tray_tiles[idx].value, HEX_RADIUS)
		ghost.modulate = GHOST_MODULATE
		trail_holder.add_child(ghost)
		ghost.position = axial_to_pixel(trail_cells[idx])
		ghost.scale = Vector2(0.6, 0.6)
		var pop := ghost.create_tween()
		pop.tween_property(ghost, "scale", Vector2.ONE, 0.1) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		trail_ghosts.append(ghost)

	var pts := PackedVector2Array()
	if count >= 2:
		for cell in trail_cells:
			pts.append(axial_to_pixel(cell))
	trail_line.points = pts

	# Tray tiles already used by the trail fade, so the remaining ones read as "still to place"
	for i in range(tray_tiles.size()):
		tray_tiles[i].modulate = Color(1, 1, 1, 0.3) if i < count else Color.WHITE

	_refresh_slot_colors()
	_update_merge_preview()


# Slot colors: normal, trail cells, the cells the trail can grow into, or red while the hammer is armed
func _refresh_slot_colors() -> void:
	var next_cells: Array[Vector2i] = []
	if is_tracing and not trail_cells.is_empty() and trail_cells.size() < tray_tiles.size():
		var head: Vector2i = trail_cells[trail_cells.size() - 1]
		for dir in AXIAL_DIRECTIONS:
			var candidate: Vector2i = head + dir
			if _is_free_cell(candidate) and not trail_cells.has(candidate):
				next_cells.append(candidate)

	for key in slot_visuals.keys():
		var coord: Vector2i = key
		var col: Color = SLOT_COLOR
		if is_hammer_mode and board_tiles[coord] != null:
			col = SLOT_HAMMER_COLOR
		elif is_tracing and trail_cells.has(coord):
			col = SLOT_TRAIL_COLOR
		elif next_cells.has(coord):
			col = SLOT_NEXT_COLOR
		slot_visuals[coord].color = col


# Once the trail is complete, light up the tiles that releasing now would merge
func _update_merge_preview() -> void:
	_clear_preview()
	if trail_cells.is_empty() or trail_cells.size() != tray_tiles.size():
		return

	var overlay: Dictionary = {}
	for i in range(trail_cells.size()):
		overlay[trail_cells[i]] = tray_tiles[i].value

	for i in range(trail_cells.size()):
		var cell: Vector2i = trail_cells[i]
		var cluster := _find_connected_cluster(cell, tray_tiles[i].value, overlay)
		if cluster.size() < MERGE_MIN_CLUSTER:
			continue
		for member in cluster:
			if overlay.has(member):
				var ghost_idx := trail_cells.find(member)
				if ghost_idx >= 0 and ghost_idx < trail_ghosts.size():
					trail_ghosts[ghost_idx].modulate = GHOST_MERGE_MODULATE
				continue
			var tile: TrailTile = board_tiles.get(member)
			if tile != null and not previewed_tiles.has(tile):
				previewed_tiles.append(tile)
				tile.modulate = Color(1.35, 1.35, 1.35)
				tile.scale = Vector2(1.08, 1.08)


func _clear_preview() -> void:
	for tile in previewed_tiles:
		if is_instance_valid(tile):
			tile.modulate = Color.WHITE
			tile.scale = Vector2.ONE
	previewed_tiles.clear()
	for ghost in trail_ghosts:
		if is_instance_valid(ghost):
			ghost.modulate = GHOST_MODULATE


# =============================================================================
# PLACEMENT & CHAIN MERGE RESOLUTION
# =============================================================================

func _set_busy(value: bool) -> void:
	busy = value
	if busy and is_tracing:
		is_tracing = false
		_clear_trail()
	_update_powerup_buttons()


# Moves the tray tiles onto the trail cells (in order), then resolves merges
func _commit_trail() -> void:
	_set_busy(true)
	var cells: Array[Vector2i] = []
	for trail_cell in trail_cells:
		cells.append(trail_cell)
	_clear_trail()

	placed_order.clear()
	var placed_coords: Array[Vector2i] = []
	var count := cells.size()

	for i in range(count):
		var tile := tray_tiles[i]
		var coord := cells[i]

		# Transfer the tile from the tray onto the board, keeping its on-screen position
		var prev_global := tile.global_position
		tray_holder.remove_child(tile)
		add_child(tile)
		tile.global_position = prev_global
		tile.modulate = Color.WHITE

		tile.axial_coord = coord
		board_tiles[coord] = tile
		placed_order[coord] = i
		placed_coords.append(coord)

		# Fly in one after another, in trail order
		var delay := PLACE_STAGGER * float(i)
		var tween := tile.create_tween().set_parallel(true)
		tween.tween_property(tile, "position", axial_to_pixel(coord), PLACE_TIME) \
				.set_delay(delay).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(tile, "scale", Vector2.ONE, PLACE_TIME).set_delay(delay)
		tween.tween_callback(SoundFX.play_place).set_delay(delay)

	tray_tiles.clear()

	await get_tree().create_timer(PLACE_TIME + PLACE_STAGGER * float(count - 1) + 0.04).timeout
	await _resolve_merges(placed_coords)

	_set_busy(false)
	_spawn_tray()


# Where a merged group lands: the most recently placed tile of the group, so the player
# steers the result with the trail direction. Chain merges stay on the merged tile.
func _pick_landing_coord(cluster: Array[Vector2i], current: Vector2i, is_chain: bool) -> Vector2i:
	if is_chain:
		return current
	var best: Vector2i = current
	var best_idx: int = int(placed_order.get(current, -1))
	for member in cluster:
		var idx: int = int(placed_order.get(member, -1))
		if idx > best_idx:
			best = member
			best_idx = idx
	return best


func _resolve_merges(coords_to_check: Array[Vector2i]) -> void:
	var queue: Array[Dictionary] = []
	for c in coords_to_check:
		queue.append({"coord": c, "is_chain": false, "combo": 1})

	while queue.size() > 0:
		var item: Dictionary = queue.pop_front()
		var current_coord: Vector2i = item["coord"]
		var is_chain: bool = item["is_chain"]
		var combo: int = item["combo"]

		var check_tile: TrailTile = board_tiles.get(current_coord)
		if check_tile == null:
			continue

		var cluster := _find_connected_cluster(current_coord, check_tile.value)
		# First merge needs 3; chain merges (a merged tile touching an equal tile) need only 2
		var min_cluster_size: int = CHAIN_MIN_CLUSTER if is_chain else MERGE_MIN_CLUSTER
		if cluster.size() < min_cluster_size:
			continue

		await get_tree().create_timer(0.18).timeout

		var land_coord := _pick_landing_coord(cluster, current_coord, is_chain)
		var land_tile: TrailTile = board_tiles[land_coord]
		var target_pos := axial_to_pixel(land_coord)
		var merged_count := cluster.size()
		var new_value := land_tile.value + (2 if merged_count >= BIG_GROUP_SIZE else 1)

		# Slide every absorbed tile into the landing cell at the same time
		var absorbed: Array[TrailTile] = []
		var tween := create_tween().set_parallel(true)
		for c in cluster:
			if c == land_coord:
				continue
			var absorbed_tile: TrailTile = board_tiles[c]
			board_tiles[c] = null
			absorbed.append(absorbed_tile)
			tween.tween_property(absorbed_tile, "position", target_pos, 0.15)
			tween.tween_property(absorbed_tile, "scale", Vector2(0.2, 0.2), 0.15)
		await tween.finished
		for t in absorbed:
			t.queue_free()

		land_tile.set_value(new_value)
		highest_tile_reached = maxi(highest_tile_reached, new_value)

		# Score uses the combo multiplier; level XP is per merge (also boosted by combo)
		var points_earned := new_value * merged_count * combo
		score += points_earned
		_update_score_display()
		_add_level_xp(XP_PER_MERGE * combo)

		# Feedback
		SoundFX.play_merge(combo)
		SoundFX.trigger_haptic(25)
		_spawn_merge_particles(target_pos, land_tile.polygon.color, mini(10 + combo * 4, 40))
		_spawn_score_popup(target_pos, points_earned, land_tile.polygon.color, combo)
		if new_value >= 7 or combo > 1:
			_shake_screen(2.5 + float(combo) * 1.5, 0.16)

		# Re-check the landing cell for a chain with an incremented combo counter
		queue.push_front({"coord": land_coord, "is_chain": true, "combo": combo + 1})


# =============================================================================
# SCORE / LEVEL / GEMS
# =============================================================================

func _update_score_display() -> void:
	score_label.text = str(score)
	if score > best_score:
		best_score = score
		best_dirty = true
	best_score_label.text = str(best_score)


func _refresh_level_ui(reset_bar: bool) -> void:
	curr_lvl_label.text = str(current_level)
	next_lvl_label.text = str(current_level + 1)
	if reset_bar:
		if bar_tween and bar_tween.is_valid():
			bar_tween.kill()
		progress_bar.max_value = xp_to_next_level
		progress_bar.value = float(level_xp)


func _add_level_xp(amount: int) -> void:
	var old_max := xp_to_next_level
	level_xp += amount

	var levels_gained: int = 0
	while level_xp >= xp_to_next_level:
		level_xp -= xp_to_next_level
		current_level += 1
		xp_to_next_level = int(ceil(float(xp_to_next_level) * XP_GROWTH))
		levels_gained += 1

	curr_lvl_label.text = str(current_level)
	next_lvl_label.text = str(current_level + 1)

	if bar_tween and bar_tween.is_valid():
		bar_tween.kill()
	bar_tween = create_tween()
	if levels_gained > 0:
		# Fill the bar, wrap to the next level, then fill to the leftover XP
		bar_tween.tween_property(progress_bar, "value", float(old_max), 0.15)
		bar_tween.tween_callback(func() -> void:
			progress_bar.max_value = xp_to_next_level
			progress_bar.value = 0.0
		)
	else:
		progress_bar.max_value = xp_to_next_level
	bar_tween.tween_property(progress_bar, "value", float(level_xp), 0.25)

	if levels_gained > 0:
		var gem_reward := levels_gained * GEMS_PER_LEVEL_UP
		_add_gems(gem_reward)
		_spawn_floating_text(board_center + Vector2(0, -140), "LEVEL UP!", Color("#f9ca24"), 30)
		_spawn_floating_text(board_center + Vector2(0, -108), "+" + str(gem_reward) + " GEMS", Color("#ff8ef8"), 20)
		SoundFX.play_level_up()


func _add_gems(amount: int) -> void:
	gems = maxi(gems + amount, 0)
	gems_label.text = str(gems)
	_persist_gems()
	_update_powerup_buttons()
	_refresh_game_over_panel()

	# Quick pulse on the counter
	gems_label.pivot_offset = gems_label.size * 0.5
	if gem_tween and gem_tween.is_valid():
		gem_tween.kill()
	gems_label.scale = Vector2.ONE
	gem_tween = create_tween()
	gem_tween.tween_property(gems_label, "scale", Vector2(1.3, 1.3), 0.1)
	gem_tween.tween_property(gems_label, "scale", Vector2.ONE, 0.1)


# =============================================================================
# POWER-UPS
# =============================================================================

func _update_powerup_buttons() -> void:
	if not hammer_button or not reroll_button:
		return

	var can_hammer := gems >= HAMMER_COST and _board_has_tiles() and not busy
	var hammer_usable := can_hammer or is_hammer_mode  # while armed, the button must stay usable to cancel
	hammer_button.disabled = not hammer_usable
	hammer_button.modulate = Color.WHITE if hammer_usable else Color(1, 1, 1, 0.4)

	var can_reroll := gems >= REROLL_COST and not is_hammer_mode and not busy and not is_game_over
	reroll_button.disabled = not can_reroll
	reroll_button.modulate = Color.WHITE if can_reroll else Color(1, 1, 1, 0.4)


func _on_hammer_pressed() -> void:
	if busy:
		return
	if not is_hammer_mode and gems < HAMMER_COST:
		return

	# Toggle targeting mode on/off
	is_hammer_mode = not is_hammer_mode
	hammer_hint_label.visible = is_hammer_mode
	_refresh_slot_colors()
	_refresh_game_over_panel()  # panel hides while targeting so the board is visible
	_update_powerup_buttons()


func _use_hammer_on_coord(coord: Vector2i) -> void:
	if busy or gems < HAMMER_COST:
		return
	var target_tile: TrailTile = board_tiles.get(coord)
	if target_tile == null:
		return

	board_tiles[coord] = null

	# Exit hammer mode and pay for it
	is_hammer_mode = false
	hammer_hint_label.visible = false
	_refresh_slot_colors()
	_add_gems(-HAMMER_COST)

	# Smash feedback
	_spawn_floating_text(target_tile.global_position, "SMASH!", Color("#ff7979"), 20)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(target_tile, "scale", Vector2(1.4, 1.4), 0.08)
	tween.tween_property(target_tile, "modulate:a", 0.0, 0.15)
	tween.chain().tween_callback(target_tile.queue_free)
	SoundFX.trigger_haptic(25)
	SoundFX.play_smash()
	_spawn_merge_particles(target_tile.global_position, target_tile.polygon.color, 16)
	_shake_screen(6.0, 0.2)

	# A freed cell may rescue a game-over state
	if is_game_over and _can_place_tray():
		_set_game_over(false)
	_refresh_game_over_panel()
	_update_powerup_buttons()
	_save_game()


func _on_reroll_pressed() -> void:
	if busy or is_game_over or is_hammer_mode or gems < REROLL_COST:
		return

	_set_busy(true)
	_add_gems(-REROLL_COST)
	_spawn_floating_text(dock_center + Vector2(0, -70), "REROLL!", Color("#38a3d1"), 18)

	# Shrink the current tray away, then deal a fresh one
	var tween := create_tween()
	tween.tween_property(tray_holder, "scale", Vector2.ZERO, 0.12)
	await tween.finished

	_set_busy(false)
	_spawn_tray()


# =============================================================================
# GAME OVER
# =============================================================================

func _set_game_over(is_over: bool) -> void:
	var newly_over := is_over and not is_game_over
	is_game_over = is_over

	if newly_over:
		_delete_run_save()
		_flush_best_score()

	_refresh_game_over_panel()

	if newly_over and game_over_panel.visible:
		game_over_panel.pivot_offset = game_over_panel.size * 0.5
		game_over_panel.scale = Vector2(0.8, 0.8)
		var tween := create_tween()
		tween.tween_property(game_over_panel, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	_update_powerup_buttons()


func _refresh_game_over_panel() -> void:
	if not game_over_panel:
		return
	game_over_panel.visible = is_game_over and not is_hammer_mode
	if gems >= HAMMER_COST and _board_has_tiles():
		game_over_sub_label.text = "Smash a tile with the Hammer,\nor start a new game"
	else:
		game_over_sub_label.text = "Start a new game to keep playing"


# =============================================================================
# SAVE / RESTORE / NEW GAME
# =============================================================================

func _read_run_save() -> Dictionary:
	return SaveManager.read_save(GAME_ID)


func _delete_run_save() -> void:
	SaveManager.delete_save(GAME_ID)


func _clear_board() -> void:
	_clear_trail()
	for key in board_tiles.keys():
		var coord: Vector2i = key
		var tile: TrailTile = board_tiles[coord]
		if tile != null:
			tile.queue_free()
			board_tiles[coord] = null


func _reset_input_state() -> void:
	is_tracing = false
	is_hammer_mode = false
	hammer_hint_label.visible = false
	_set_busy(false)


func _start_new_game() -> void:
	_flush_best_score()
	_reset_input_state()
	_clear_board()

	score = 0
	_update_score_display()

	current_level = 1
	level_xp = 0
	xp_to_next_level = START_XP_TO_LEVEL
	highest_tile_reached = START_HIGHEST_TILE
	_refresh_level_ui(true)

	_set_game_over(false)
	_spawn_tray()


func _save_game() -> void:
	# Never save mid-merge (board is half-resolved) or a finished game
	if busy or is_game_over or tray_tiles.is_empty():
		return

	var saved_board: Dictionary = {}
	for key in board_tiles.keys():
		var coord: Vector2i = key
		var board_tile: TrailTile = board_tiles[coord]
		if board_tile != null:
			saved_board["%d,%d" % [coord.x, coord.y]] = board_tile.value

	var tray_values: Array[int] = []
	for tray_tile in tray_tiles:
		tray_values.append(tray_tile.value)

	# Gems live in the shared meta, the run lives in this game's own save slot
	SaveManager.write_save({
		"score": score,
		"current_level": current_level,
		"level_xp": level_xp,
		"xp_to_next_level": xp_to_next_level,
		"highest_tile_reached": highest_tile_reached,
		"board": saved_board,
		"tray": tray_values
	}, GAME_ID)


func _restore_game(data: Dictionary) -> void:
	_reset_input_state()
	_clear_board()
	gems_label.text = str(gems)

	score = int(data.get("score", 0))
	_update_score_display()

	current_level = int(data.get("current_level", 1))
	level_xp = int(data.get("level_xp", 0))
	xp_to_next_level = int(data.get("xp_to_next_level", START_XP_TO_LEVEL))
	highest_tile_reached = int(data.get("highest_tile_reached", START_HIGHEST_TILE))
	_refresh_level_ui(true)

	# Board
	var saved_board: Dictionary = data.get("board", {})
	for key in saved_board.keys():
		var parts: PackedStringArray = str(key).split(",")
		if parts.size() != 2:
			continue
		var coord := Vector2i(int(parts[0]), int(parts[1]))
		if not board_tiles.has(coord):
			continue
		var tile := TrailTile.new(int(saved_board[key]), HEX_RADIUS)
		tile.axial_coord = coord
		tile.position = axial_to_pixel(coord)
		add_child(tile)
		board_tiles[coord] = tile

	# Tray (fall back to a fresh one if the saved tray is missing/empty)
	var tray_values: Array[int] = []
	for v in data.get("tray", []):
		if tray_values.size() < MAX_TRAY_SIZE:
			tray_values.append(int(v))

	if tray_values.is_empty():
		_set_game_over(false)
		_spawn_tray()
		return

	_build_tray(tray_values, false)
	_finish_tray_setup(false)


# =============================================================================
# UI BUILDERS
# =============================================================================

func _make_panel(pos: Vector2, panel_size: Vector2, color: Color, radius: int) -> Panel:
	var panel := Panel.new()
	panel.position = pos
	panel.size = panel_size
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_label(text_str: String, pos: Vector2, label_size: Vector2, font_size: int,
		color: Color = Color.WHITE,
		h_align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER,
		v_align: VerticalAlignment = VERTICAL_ALIGNMENT_TOP) -> Label:
	var lbl := Label.new()
	lbl.text = text_str
	lbl.position = pos
	lbl.size = label_size
	lbl.horizontal_alignment = h_align
	lbl.vertical_alignment = v_align
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl


func _create_menu_button(pos: Vector2, btn_size: Vector2, text_str: String, bg_color: Color, callback: Callable) -> Button:
	var btn := Button.new()
	btn.position = pos
	btn.size = btn_size
	btn.text = text_str
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_color_override("font_color", Color.WHITE)

	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(16)
	style.border_width_bottom = 5
	style.border_color = bg_color.darkened(0.35)
	btn.add_theme_stylebox_override("normal", style)

	var hover: StyleBoxFlat = style.duplicate()
	hover.bg_color = bg_color.lightened(0.1)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)

	btn.pressed.connect(callback)
	return btn


func _create_icon_square_button(bg_color: Color, icon_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.size = Vector2(48, 48)
	btn.text = icon_text
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_color_override("font_color", Color.WHITE)

	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(12)
	style.border_width_bottom = 3
	style.border_color = bg_color.darkened(0.3)
	btn.add_theme_stylebox_override("normal", style)

	var hover: StyleBoxFlat = style.duplicate()
	hover.bg_color = bg_color.lightened(0.1)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)

	btn.pressed.connect(callback)
	return btn


func _setup_header_ui() -> void:
	var center_x := screen_size.x * 0.5

	# Center split pill: BEST | SCORE
	var score_pill := _make_panel(Vector2(center_x - 112.0, safe_top_y), Vector2(224, 54), Color("#18181a"), 14)
	ui_layer.add_child(score_pill)

	var divider := ColorRect.new()
	divider.color = Color("#333338")
	divider.position = Vector2(111, 8)
	divider.size = Vector2(2, 38)
	score_pill.add_child(divider)

	score_pill.add_child(_make_label("BEST", Vector2(0, 5), Vector2(110, 18), 12, Color("#9a9aa2")))
	best_score_label = _make_label(str(best_score), Vector2(0, 22), Vector2(110, 28), 20)
	score_pill.add_child(best_score_label)

	score_pill.add_child(_make_label("SCORE", Vector2(114, 5), Vector2(110, 18), 12, Color("#9a9aa2")))
	score_label = _make_label("0", Vector2(114, 22), Vector2(110, 28), 20)
	score_pill.add_child(score_label)

	# Top-right buttons, anchored to the screen edge
	var gear_btn := _create_icon_square_button(Color("#7c69ef"), "⚙", _on_settings_pressed)
	gear_btn.position = Vector2(screen_size.x - UI_MARGIN - 48.0, safe_top_y + 2.0)
	ui_layer.add_child(gear_btn)

	var cal_btn := _create_icon_square_button(Color("#7c69ef"), "📅", _on_calendar_pressed)
	cal_btn.position = Vector2(gear_btn.position.x - 10.0 - 48.0, safe_top_y + 2.0)
	ui_layer.add_child(cal_btn)

	# Red notification badge on the calendar button
	calendar_badge = _make_panel(Vector2(36, -6), Vector2(20, 20), Color("#eb4d4b"), 10)
	cal_btn.add_child(calendar_badge)
	calendar_badge.add_child(_make_label("1", Vector2.ZERO, Vector2(20, 20), 12, Color.WHITE,
			HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER))
	calendar_badge.visible = SaveManager.can_claim_daily_reward()


func _setup_gem_ui() -> void:
	var pill := _make_panel(Vector2(UI_MARGIN, safe_top_y + 8.0), Vector2(120, 38), Color("#18181a"), 19)
	ui_layer.add_child(pill)

	# Procedural diamond icon
	var gem_poly := Polygon2D.new()
	gem_poly.polygon = PackedVector2Array([
		Vector2(-8, -11), Vector2(8, -11), Vector2(14, -3), Vector2(0, 12), Vector2(-14, -3)
	])
	gem_poly.color = Color("#e056fd")
	gem_poly.position = Vector2(22, 19)
	pill.add_child(gem_poly)

	var inner_facet := Polygon2D.new()
	inner_facet.polygon = PackedVector2Array([
		Vector2(-5, -11), Vector2(5, -11), Vector2(7, -3), Vector2(0, 9), Vector2(-7, -3)
	])
	inner_facet.color = Color("#ff8ef8")
	gem_poly.add_child(inner_facet)

	gems_label = _make_label(str(gems), Vector2(44, 0), Vector2(68, 38), 18, Color.WHITE,
			HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER)
	pill.add_child(gems_label)


func _setup_level_bar() -> void:
	var center_x := screen_size.x * 0.5
	var bar_width: float = 220.0
	var bar_pos := Vector2(center_x - bar_width * 0.5, safe_top_y + 76.0)

	progress_bar = ProgressBar.new()
	progress_bar.position = bar_pos
	progress_bar.size = Vector2(bar_width, 16.0)
	progress_bar.show_percentage = false
	progress_bar.max_value = xp_to_next_level
	progress_bar.value = 0

	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color("#18181a")
	bg_style.set_corner_radius_all(8)
	progress_bar.add_theme_stylebox_override("background", bg_style)

	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = Color("#5b7cfa")
	fill_style.set_corner_radius_all(8)
	progress_bar.add_theme_stylebox_override("fill", fill_style)
	ui_layer.add_child(progress_bar)

	curr_lvl_label = _create_level_badge(bar_pos + Vector2(-18, -10), Color("#f9ca24"), str(current_level))
	next_lvl_label = _create_level_badge(bar_pos + Vector2(bar_width - 18, -10), Color("#36b37e"), str(current_level + 1))


func _create_level_badge(pos: Vector2, bg_color: Color, text_val: String) -> Label:
	var badge := _make_panel(pos, Vector2(36, 36), bg_color, 18)
	var style: StyleBoxFlat = badge.get_theme_stylebox("panel")
	style.set_border_width_all(2)
	style.border_color = Color.WHITE
	ui_layer.add_child(badge)

	var lbl := _make_label(text_val, Vector2.ZERO, Vector2(36, 36), 16, Color("#1e1e24"),
			HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	badge.add_child(lbl)
	return lbl


func _setup_powerup_ui() -> void:
	var btn_y := dock_center.y - 45.0
	hammer_button = _create_powerup_button(Vector2(28.0, btn_y), HAMMER_COST, _on_hammer_pressed)
	_draw_hammer_icon(hammer_button)

	reroll_button = _create_powerup_button(Vector2(screen_size.x - 28.0 - 90.0, btn_y), REROLL_COST, _on_reroll_pressed)
	_draw_reroll_icon(reroll_button)

	# Targeting banner for hammer mode (hidden by default)
	hammer_hint_label = _make_label("TAP A TILE TO SMASH (TAP BUTTON TO CANCEL)",
			Vector2(0, dock_center.y - 105.0), Vector2(screen_size.x, 30), 15, Color("#ff7979"))
	hammer_hint_label.visible = false
	ui_layer.add_child(hammer_hint_label)

	_update_powerup_buttons()


func _create_powerup_button(pos: Vector2, cost: int, callback: Callable) -> Button:
	var btn := Button.new()
	btn.position = pos
	btn.size = Vector2(90, 90)
	btn.focus_mode = Control.FOCUS_NONE

	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color("#333338")
	normal_style.set_corner_radius_all(18)
	normal_style.border_width_bottom = 4
	normal_style.border_color = Color("#1e1e22")
	btn.add_theme_stylebox_override("normal", normal_style)

	var hover_style: StyleBoxFlat = normal_style.duplicate()
	hover_style.bg_color = Color("#424248")
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)

	btn.pressed.connect(callback)
	ui_layer.add_child(btn)

	ui_layer.add_child(_make_label("♦ " + str(cost), pos + Vector2(0, 94), Vector2(90, 24), 16, Color("#ff8ef8")))
	return btn


func _draw_hammer_icon(parent: Control) -> void:
	var handle := Polygon2D.new()
	handle.polygon = PackedVector2Array([
		Vector2(-4, -10), Vector2(4, -10), Vector2(5, 24), Vector2(-5, 24)
	])
	handle.color = Color("#d4a373")
	handle.position = Vector2(45, 45)
	handle.rotation_degrees = -35.0
	parent.add_child(handle)

	var head := Polygon2D.new()
	head.polygon = PackedVector2Array([
		Vector2(-18, -10), Vector2(18, -10), Vector2(18, 6), Vector2(-18, 6)
	])
	head.color = Color("#f9ca24")
	head.position = Vector2(0, -12)
	handle.add_child(head)


func _draw_reroll_icon(parent: Control) -> void:
	var arc := Line2D.new()
	var pts := PackedVector2Array()
	for i in range(25):
		var a := deg_to_rad(-45.0 + (270.0 / 24.0) * i)
		pts.append(Vector2(45, 45) + Vector2(cos(a), sin(a)) * 20.0)
	arc.points = pts
	arc.width = 5.0
	arc.default_color = Color("#38a3d1")
	parent.add_child(arc)

	var arrow := Polygon2D.new()
	arrow.polygon = PackedVector2Array([Vector2(0, -8), Vector2(12, 0), Vector2(0, 8)])
	arrow.color = Color("#f9ca24")
	arrow.position = Vector2(45, 25)
	parent.add_child(arrow)


func _setup_game_over_ui() -> void:
	var panel_size := Vector2(340, 162)
	game_over_panel = _make_panel(board_center - panel_size * 0.5, panel_size, Color("#18181a", 0.94), 18)
	game_over_panel.z_index = 30
	game_over_panel.visible = false

	var style: StyleBoxFlat = game_over_panel.get_theme_stylebox("panel")
	style.set_border_width_all(3)
	style.border_color = Color("#ff7979")
	style.shadow_color = Color(0, 0, 0, 0.6)
	style.shadow_size = 12
	ui_layer.add_child(game_over_panel)

	game_over_panel.add_child(_make_label("NO MOVES LEFT!", Vector2(0, 12), Vector2(panel_size.x, 38), 28, Color("#ff7979")))

	game_over_sub_label = _make_label("", Vector2(0, 54), Vector2(panel_size.x, 44), 16, Color("#d0d0d8"))
	game_over_sub_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	game_over_panel.add_child(game_over_sub_label)

	game_over_panel.add_child(_create_menu_button(
		Vector2((panel_size.x - 170.0) * 0.5, 106.0), Vector2(170, 44),
		"NEW GAME", Color("#36b37e"), _start_new_game))


func _setup_modals() -> void:
	# --- SETTINGS MODAL ---
	settings_overlay = _create_modal_backdrop()
	var s_panel := _create_modal_card(settings_overlay, Vector2(360, 360), "SETTINGS")

	sound_toggle_btn = _create_menu_button(
		Vector2(55, 85), Vector2(250, 52),
		"SOUND: ON" if not SoundFX.is_muted else "SOUND: OFF",
		Color("#38a3d1") if not SoundFX.is_muted else Color("#58585e"),
		_on_toggle_sound)
	s_panel.add_child(sound_toggle_btn)

	haptics_toggle_btn = _create_menu_button(
		Vector2(55, 152), Vector2(250, 52),
		"HAPTICS: ON" if SoundFX.haptics_enabled else "HAPTICS: OFF",
		Color("#38a3d1") if SoundFX.haptics_enabled else Color("#58585e"),
		_on_toggle_haptics)
	s_panel.add_child(haptics_toggle_btn)

	s_panel.add_child(_create_menu_button(
		Vector2(55, 220), Vector2(250, 52), "HOME SCREEN", Color("#f5a623"), _on_return_home_pressed))

	s_panel.add_child(_create_menu_button(
		Vector2(105, 288), Vector2(150, 44), "RESUME", Color("#36b37e"),
		func() -> void: settings_overlay.visible = false))

	# --- DAILY REWARD MODAL ---
	daily_overlay = _create_modal_backdrop()
	var d_panel := _create_modal_card(daily_overlay, Vector2(360, 310), "DAILY REWARD")

	daily_status_label = _make_label("", Vector2(20, 85), Vector2(320, 70), 18)
	daily_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d_panel.add_child(daily_status_label)

	claim_daily_btn = _create_menu_button(
		Vector2(65, 170), Vector2(230, 54), "CLAIM GEMS", Color("#e056fd"), _on_claim_daily_pressed)
	d_panel.add_child(claim_daily_btn)

	d_panel.add_child(_create_menu_button(
		Vector2(105, 240), Vector2(150, 44), "CLOSE", Color("#58585e"),
		func() -> void: daily_overlay.visible = false))


func _create_modal_backdrop() -> ColorRect:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.72)
	backdrop.size = screen_size
	backdrop.z_index = 40
	backdrop.visible = false
	ui_layer.add_child(backdrop)
	return backdrop


func _create_modal_card(parent: Control, card_size: Vector2, title_text: String) -> Panel:
	var card := _make_panel((screen_size - card_size) * 0.5, card_size, Color("#28282c"), 20)
	var style: StyleBoxFlat = card.get_theme_stylebox("panel")
	style.set_border_width_all(3)
	style.border_color = Color("#42424a")
	parent.add_child(card)

	card.add_child(_make_label(title_text, Vector2(0, 22), Vector2(card_size.x, 36), 24))
	return card


# =============================================================================
# MENU / MODAL CALLBACKS
# =============================================================================

# Called once the scene is ready: resume this game's saved run, or start a new one.
# (The home screen's NEW button deletes the save before launching, so this just follows what exists.)
func _begin_session() -> void:
	var saved_data: Dictionary = _read_run_save()
	if not saved_data.is_empty():
		_restore_game(saved_data)
	else:
		_start_new_game()


func _on_settings_pressed() -> void:
	if busy:
		return # opening the menu mid-merge could desync the board from the save
	if is_hammer_mode:
		_on_hammer_pressed() # cancel targeting cleanly
	settings_overlay.visible = true


func _on_toggle_sound() -> void:
	SoundFX.is_muted = not SoundFX.is_muted
	var on := not SoundFX.is_muted
	sound_toggle_btn.text = "SOUND: ON" if on else "SOUND: OFF"
	_write_meta_value("sound_enabled", on)


func _on_toggle_haptics() -> void:
	SoundFX.haptics_enabled = not SoundFX.haptics_enabled
	haptics_toggle_btn.text = "HAPTICS: ON" if SoundFX.haptics_enabled else "HAPTICS: OFF"
	if SoundFX.haptics_enabled:
		SoundFX.trigger_haptic(30)
	_write_meta_value("haptics_enabled", SoundFX.haptics_enabled)


func _on_return_home_pressed() -> void:
	# Leaving frees this scene, so save first
	_save_game()
	_flush_best_score()
	GameHub.go_home()


func _on_calendar_pressed() -> void:
	var can_claim := SaveManager.can_claim_daily_reward()
	var streak := int(SaveManager.read_meta().get("streak_day", 0))
	if can_claim:
		var next_reward: int = SaveManager.DAILY_REWARD_GEMS + mini(streak, 6) * 15
		daily_status_label.text = "Day %d Login Bonus Ready!\nClaim +%d Gems" % [streak + 1, next_reward]
		claim_daily_btn.disabled = false
	else:
		daily_status_label.text = "Day %d Claimed!\nCome back tomorrow for more Gems." % streak
		claim_daily_btn.disabled = true
	daily_overlay.visible = true


func _on_claim_daily_pressed() -> void:
	var result: Dictionary = SaveManager.claim_daily_reward()
	if result.get("claimed", false):
		var reward := int(result["gems"])
		_add_gems(reward)  # persists to meta immediately
		SoundFX.play_level_up()
		SoundFX.trigger_haptic(40)
		calendar_badge.visible = false
		daily_status_label.text = "Claimed +%d Gems!\nCurrent Streak: Day %d" % [reward, int(result["streak"])]
		claim_daily_btn.disabled = true


# =============================================================================
# JUICE
# =============================================================================

func _shake_screen(intensity: float = 4.0, duration: float = 0.16) -> void:
	if not camera:
		return
	if shake_tween and shake_tween.is_valid():
		shake_tween.kill()
	shake_tween = create_tween()
	var steps: int = 4
	for i in range(steps):
		var rand_offset := Vector2(randf_range(-intensity, intensity), randf_range(-intensity, intensity))
		shake_tween.tween_property(camera, "offset", rand_offset, duration / float(steps))
	shake_tween.tween_property(camera, "offset", Vector2.ZERO, 0.04)


func _spawn_merge_particles(world_pos: Vector2, tile_color: Color, count: int = 12) -> void:
	for i in range(count):
		var p := Polygon2D.new()
		p.polygon = HexTile.create_hex_points(6.0)
		p.color = tile_color.lightened(0.2)
		p.position = world_pos
		p.z_index = 15
		add_child(p)

		var angle := (TAU / float(count)) * i + randf_range(-0.2, 0.2)
		var dist := randf_range(35.0, 75.0)
		var target := world_pos + Vector2(cos(angle), sin(angle)) * dist

		var tween := create_tween().set_parallel(true)
		tween.tween_property(p, "position", target, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tween.tween_property(p, "scale", Vector2.ZERO, 0.35)
		tween.tween_property(p, "modulate:a", 0.0, 0.35)
		tween.chain().tween_callback(p.queue_free)


func _spawn_floating_text(pos: Vector2, text_str: String, color: Color = Color.WHITE, font_size: int = 22,
		outline_color: Color = Color(0, 0, 0, 0.85), peak_scale: float = 1.35, rise: float = 55.0,
		tilt_deg: float = 0.0) -> void:
	var lbl := _make_label(text_str, pos - Vector2(160, 40), Vector2(320, 80), font_size, color,
			HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	lbl.add_theme_font_override("font", HexTile.get_bold_font())
	lbl.add_theme_color_override("font_outline_color", outline_color)
	lbl.add_theme_constant_override("outline_size", clampi(int(font_size * 0.25), 4, 10))
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.35))
	lbl.add_theme_constant_override("shadow_offset_y", 3)
	lbl.z_index = 10
	lbl.pivot_offset = Vector2(160, 40)
	lbl.scale = Vector2(0.3, 0.3)
	lbl.rotation_degrees = tilt_deg
	ui_layer.add_child(lbl)

	# Overshoot pop, then settle to normal size
	var pop := create_tween()
	pop.tween_property(lbl, "scale", Vector2.ONE * peak_scale, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pop.tween_property(lbl, "scale", Vector2.ONE, 0.10).set_trans(Tween.TRANS_SINE)

	# Float upward, then fade out near the end
	var drift := create_tween().set_parallel(true)
	drift.tween_property(lbl, "position:y", lbl.position.y - rise, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	drift.tween_property(lbl, "modulate:a", 0.0, 0.3).set_delay(0.65)
	drift.chain().tween_callback(lbl.queue_free)


# Score popup after a merge. Bigger scores get bigger text; chains add a COMBO callout.
func _spawn_score_popup(pos: Vector2, points: int, tile_color: Color, combo: int) -> void:
	# Log scale so late-game numbers don't become enormous: ~26px for small merges up to ~47px for 10k+
	var magnitude := clampf(log(float(maxi(points, 1))) / log(10.0) - 1.0, 0.0, 3.0)
	var font_size := int(26.0 + magnitude * 7.0)

	# White normally, warming to gold as the chain grows; outline tinted by the merged tile's color
	var fill := Color.WHITE.lerp(Color("#f9ca24"), clampf(float(combo - 1) / 3.0, 0.0, 1.0))
	var outline := tile_color.darkened(0.55)

	_spawn_floating_text(pos + Vector2(randf_range(-6.0, 6.0), -34.0), "+" + str(points), fill, font_size,
			outline, 1.4 + 0.05 * float(mini(combo, 5)), 70.0, randf_range(-5.0, 5.0))

	if combo > 1:
		var combo_font := mini(24 + combo * 4, 44)
		var combo_color := Color("#f9ca24").lerp(Color("#ff6b4a"), clampf(float(combo - 2) / 3.0, 0.0, 1.0))
		_spawn_floating_text(pos + Vector2(0, -84.0 - float(font_size) * 0.4), "COMBO x" + str(combo), combo_color,
				combo_font, Color("#4a2a00"), 1.55, 60.0, randf_range(-7.0, 7.0))
