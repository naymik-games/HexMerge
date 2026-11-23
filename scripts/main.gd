extends Node2D

# =============================================================================
# HEX MERGE - main game script
#
# Layout of this file:
#   1. Config / state
#   2. Lifecycle & persistence helpers
#   3. Layout & scene setup (world layer + UI CanvasLayer)
#   4. Board math
#   5. Candidate piece (spawn / rotate / drag)
#   6. Input
#   7. Placement & merge resolution
#   8. Level / gems / power-ups
#   9. Save / restore / new game
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

const PAIR_CHANCE: float = 0.65
const DEFAULT_PAIR_DIR: int = 1             # index into AXIAL_DIRECTIONS
const DOCK_RING_RADIUS: float = 75.0
const DOCK_HIT_RADIUS: float = 110.0
const DRAG_THRESHOLD: float = 12.0
const DRAG_LIFT: Vector2 = Vector2(0, -45)  # keeps the finger from covering the piece
const UI_MARGIN: float = 16.0

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
var board_tiles: Dictionary = {}    # Vector2i -> HexTile (null if empty)
var slot_visuals: Dictionary = {}   # Vector2i -> Polygon2D (background hexes)
var previewed_tiles: Array[HexTile] = []
var last_hover_targets: Array[Vector2i] = []

# --- RUN STATE ---
var score: int = 0
var best_score: int = 0
var best_dirty: bool = false
var highest_tile_reached: int = 16
var is_game_over: bool = false
var busy: bool = false              # true while merges / reroll are animating: blocks all input

# --- CANDIDATE PIECE ---
var candidate_holder: Node2D
var candidate_tiles: Array[HexTile] = []
var is_pair: bool = false
var pair_dir_index: int = DEFAULT_PAIR_DIR
var pair_target_angle: float = 0.0  # continuous (never wraps) so rotation tweens always go clockwise
var pair_visual_angle: float = 0.0
var rotate_tween: Tween
var dock_tween: Tween
var arrows_target_deg: float = 0.0
var arrows_tween: Tween
var dock_arrows_holder: Node2D

# --- INPUT ---
var is_dragging: bool = false
var has_dragged_far: bool = false
var drag_start_pos: Vector2 = Vector2.ZERO

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
	_setup_dock()
	_setup_powerup_ui()
	_build_board()
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
	best_score = SaveManager.update_best_score(0)  # used as a getter


func _write_meta_value(key: String, value: Variant) -> void:
	var meta: Dictionary = SaveManager.read_meta()
	meta[key] = value
	SaveManager.write_meta(meta)


func _persist_gems() -> void:
	_write_meta_value("gems", gems)


# Best score is tracked in memory and only written to disk when it matters
func _flush_best_score() -> void:
	if best_dirty:
		best_score = SaveManager.update_best_score(best_score)
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

	# Center the board midway between the level bar and the dock
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


func _setup_dock() -> void:
	# Ring
	var dock_ring := Line2D.new()
	dock_ring.position = dock_center
	var pts := PackedVector2Array()
	for i in range(65):
		var a := (TAU / 64.0) * i
		pts.append(Vector2(cos(a), sin(a)) * DOCK_RING_RADIUS)
	dock_ring.points = pts
	dock_ring.width = 4.0
	dock_ring.default_color = Color("#3a3a3d")
	add_child(dock_ring)

	# Rotating curved arrows around the ring (hint that tapping rotates pairs)
	dock_arrows_holder = Node2D.new()
	dock_arrows_holder.position = dock_center
	add_child(dock_arrows_holder)

	for side in [0, 1]:
		var base_angle: float = PI * side
		var arc := Line2D.new()
		var arc_pts := PackedVector2Array()
		for i in range(17):
			var a := base_angle + deg_to_rad(-35.0 + (70.0 / 16.0) * i)
			arc_pts.append(Vector2(cos(a), sin(a)) * DOCK_RING_RADIUS)
		arc.points = arc_pts
		arc.width = 5.0
		arc.default_color = Color("#58585e")
		dock_arrows_holder.add_child(arc)

		var end_angle := base_angle + deg_to_rad(35.0)
		var arrow := Polygon2D.new()
		arrow.polygon = PackedVector2Array([Vector2(-6, -5), Vector2(6, 0), Vector2(-6, 5)])
		arrow.color = Color("#58585e")
		arrow.position = Vector2(cos(end_angle), sin(end_angle)) * DOCK_RING_RADIUS
		arrow.rotation = end_angle + PI * 0.5
		dock_arrows_holder.add_child(arrow)


func _build_board() -> void:
	for q in range(-GRID_RADIUS, GRID_RADIUS + 1):
		var r1: int = maxi(-GRID_RADIUS, -q - GRID_RADIUS)
		var r2: int = mini(GRID_RADIUS, -q + GRID_RADIUS)
		for r in range(r1, r2 + 1):
			var coord := Vector2i(q, r)
			board_tiles[coord] = null

			var slot := Polygon2D.new()
			slot.polygon = HexTile.create_rounded_hex_points(HEX_RADIUS - 2.0)
			slot.color = Color("#333336")
			slot.position = axial_to_pixel(coord)
			add_child(slot)
			slot_visuals[coord] = slot


# =============================================================================
# BOARD MATH
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


# Flood-fill to find all connected tiles of the same value (start is always first)
func _find_connected_cluster(start: Vector2i, target_val: int) -> Array[Vector2i]:
	var cluster: Array[Vector2i] = [start]
	var visited: Dictionary = {start: true}
	var i: int = 0
	while i < cluster.size():
		var curr: Vector2i = cluster[i]
		i += 1
		for dir in AXIAL_DIRECTIONS:
			var neighbor: Vector2i = curr + dir
			if visited.has(neighbor):
				continue
			var n_tile: HexTile = board_tiles.get(neighbor)
			if n_tile != null and n_tile.value == target_val:
				visited[neighbor] = true
				cluster.append(neighbor)
	return cluster


func _can_place_any_pair() -> bool:
	for coord in board_tiles.keys():
		if board_tiles[coord] == null:
			for dir in AXIAL_DIRECTIONS:
				var neighbor: Vector2i = coord + dir
				if board_tiles.has(neighbor) and board_tiles[neighbor] == null:
					return true
	return false


func _can_place_candidate() -> bool:
	if is_pair:
		return _can_place_any_pair()
	for coord in board_tiles.keys():
		if board_tiles[coord] == null:
			return true
	return false


# =============================================================================
# CANDIDATE PIECE
# =============================================================================

# Smallest value in the active 4-tier spawn window, based on the best tile reached
func _spawn_base_tier() -> int:
	if highest_tile_reached >= 2048:
		return 16   # Pool: [16, 32, 64, 128]
	if highest_tile_reached >= 512:
		return 8    # Pool: [8, 16, 32, 64]
	if highest_tile_reached >= 64:
		return 4    # Pool: [4, 8, 16, 32]
	return 2        # Pool: [2, 4, 8, 16]


func _pick_random_value() -> int:
	var base_tier := _spawn_base_tier()
	# Weighted distribution favoring the lower tiers of the window
	var pool: Array[int] = [
		base_tier, base_tier, base_tier,
		base_tier * 2, base_tier * 2,
		base_tier * 4,
		base_tier * 8
	]
	return pool[randi() % pool.size()]


func _spawn_candidate() -> void:
	var make_pair := randf() < PAIR_CHANCE and _can_place_any_pair()
	var values: Array[int] = [_pick_random_value()]
	if make_pair:
		values.append(_pick_random_value())
	_build_candidate(values, make_pair, DEFAULT_PAIR_DIR)
	_finish_candidate_setup(true)


# Builds the piece in the dock. Used for both fresh spawns and restoring a save.
func _build_candidate(values: Array[int], pair: bool, dir_index: int) -> void:
	if is_instance_valid(candidate_holder):
		candidate_holder.queue_free()
	candidate_tiles.clear()

	candidate_holder = Node2D.new()
	candidate_holder.position = dock_center
	add_child(candidate_holder)

	is_pair = pair and values.size() >= 2
	pair_dir_index = posmod(dir_index, 6)
	pair_target_angle = pair_dir_index * (PI / 3.0)
	pair_visual_angle = pair_target_angle

	var tile_a := HexTile.new(values[0], HEX_RADIUS)
	candidate_holder.add_child(tile_a)
	candidate_tiles.append(tile_a)

	if is_pair:
		var tile_b := HexTile.new(values[1], HEX_RADIUS)
		candidate_holder.add_child(tile_b)
		candidate_tiles.append(tile_b)
		_apply_pair_angle(pair_visual_angle)


func _finish_candidate_setup(save_after: bool) -> void:
	if _can_place_candidate():
		_set_game_over(false)
		if save_after:
			_save_game()
	else:
		_set_game_over(true)
	_update_powerup_buttons()


# Positions the two tiles of a pair on opposite sides of the dock pivot.
# Direction i sits at exactly i * 60 degrees, so a continuous angle gives a smooth arc.
func _apply_pair_angle(angle: float) -> void:
	pair_visual_angle = angle
	if candidate_tiles.size() < 2:
		return
	var offset := Vector2.RIGHT.rotated(angle) * NEIGHBOR_DIST
	candidate_tiles[0].position = -offset * 0.5
	candidate_tiles[1].position = offset * 0.5


func _snap_pair_to_target() -> void:
	if rotate_tween and rotate_tween.is_valid():
		rotate_tween.kill()
	if is_pair:
		_apply_pair_angle(pair_target_angle)


func _rotate_candidate() -> void:
	if not is_pair or candidate_tiles.size() < 2:
		return
	pair_dir_index = (pair_dir_index + 1) % 6
	pair_target_angle += PI / 3.0

	if rotate_tween and rotate_tween.is_valid():
		rotate_tween.kill()
	rotate_tween = create_tween()
	rotate_tween.tween_method(_apply_pair_angle, pair_visual_angle, pair_target_angle, 0.12)

	if arrows_tween and arrows_tween.is_valid():
		arrows_tween.kill()
	arrows_target_deg += 60.0
	arrows_tween = create_tween()
	arrows_tween.tween_property(dock_arrows_holder, "rotation_degrees", arrows_target_deg, 0.14)

	SoundFX.play_rotate()
	_save_game()


func _return_candidate_to_dock() -> void:
	if not is_instance_valid(candidate_holder):
		return
	if dock_tween and dock_tween.is_valid():
		dock_tween.kill()
	dock_tween = create_tween()
	dock_tween.tween_property(candidate_holder, "position", dock_center, 0.15)


# Board coordinates the candidate would occupy if dropped now
func _get_target_coords() -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	if candidate_tiles.is_empty():
		return targets
	var coord_a := pixel_to_axial(candidate_tiles[0].global_position)
	targets.append(coord_a)
	if is_pair:
		targets.append(coord_a + AXIAL_DIRECTIONS[pair_dir_index])
	return targets


func _are_coords_valid_and_empty(coords: Array[Vector2i]) -> bool:
	if coords.is_empty():
		return false
	for c in coords:
		if not board_tiles.has(c) or board_tiles[c] != null:
			return false
	return true


# =============================================================================
# INPUT (tap dock = rotate, drag from dock = place, hammer mode = tap a tile)
# =============================================================================

func _any_overlay_open() -> bool:
	return settings_overlay.visible or daily_overlay.visible


func _input(event: InputEvent) -> void:
	# Ignore the board entirely while merges animate or a menu is open
	if busy or _any_overlay_open():
		return
	# At game over only the hammer can interact with the board
	if is_game_over and not is_hammer_mode:
		return

	var pointer_pos := get_global_mouse_position()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if is_hammer_mode:
				var coord := pixel_to_axial(pointer_pos)
				if board_tiles.get(coord) != null:
					_use_hammer_on_coord(coord)
				return

			if pointer_pos.distance_to(dock_center) < DOCK_HIT_RADIUS and is_instance_valid(candidate_holder):
				is_dragging = true
				has_dragged_far = false
				drag_start_pos = pointer_pos
				if dock_tween and dock_tween.is_valid():
					dock_tween.kill()
				_snap_pair_to_target()
		elif is_dragging:
			is_dragging = false
			if has_dragged_far:
				_try_place_candidate()
			else:
				# Short tap -> rotate
				_return_candidate_to_dock()
				_rotate_candidate()
			_clear_slot_highlights()

	elif event is InputEventMouseMotion and is_dragging:
		if pointer_pos.distance_to(drag_start_pos) > DRAG_THRESHOLD:
			has_dragged_far = true
		if has_dragged_far:
			candidate_holder.position = pointer_pos + DRAG_LIFT
			_highlight_hover_slots()


func _highlight_hover_slots() -> void:
	var targets := _get_target_coords()
	if targets == last_hover_targets:
		return # same cells as last frame, nothing to redraw

	_clear_slot_highlights()
	last_hover_targets = targets
	if not _are_coords_valid_and_empty(targets):
		return

	for c in targets:
		slot_visuals[c].color = Color("#505056")

	# Temporarily simulate placement to preview which existing tiles would merge
	for i in range(targets.size()):
		board_tiles[targets[i]] = candidate_tiles[i]

	for i in range(targets.size()):
		var cluster := _find_connected_cluster(targets[i], candidate_tiles[i].value)
		if cluster.size() >= 3:
			for c in cluster:
				if targets.has(c):
					continue
				var tile: HexTile = board_tiles[c]
				if tile and not previewed_tiles.has(tile):
					previewed_tiles.append(tile)
					tile.modulate = Color(1.35, 1.35, 1.35)
					tile.scale = Vector2(1.08, 1.08)

	for c in targets:
		board_tiles[c] = null


func _clear_slot_highlights() -> void:
	for tile in previewed_tiles:
		if is_instance_valid(tile):
			tile.modulate = Color.WHITE
			tile.scale = Vector2.ONE
	previewed_tiles.clear()
	last_hover_targets = []
	_refresh_slot_colors()


# Slot colors: normal, or red on occupied slots while the hammer is armed
func _refresh_slot_colors() -> void:
	for coord in slot_visuals.keys():
		if is_hammer_mode and board_tiles[coord] != null:
			slot_visuals[coord].color = Color("#6e3535")
		else:
			slot_visuals[coord].color = Color("#333336")


# =============================================================================
# PLACEMENT & CHAIN MERGE RESOLUTION
# =============================================================================

func _set_busy(value: bool) -> void:
	busy = value
	if busy:
		is_dragging = false
	_update_powerup_buttons()


func _try_place_candidate() -> void:
	var targets := _get_target_coords()
	if not _are_coords_valid_and_empty(targets):
		_return_candidate_to_dock()
		return

	_set_busy(true)
	_clear_slot_highlights()

	# Transfer tiles from the candidate holder onto the board
	var placed_coords: Array[Vector2i] = []
	for i in range(candidate_tiles.size()):
		var tile := candidate_tiles[i]
		var coord := targets[i]

		var prev_global := tile.global_position
		candidate_holder.remove_child(tile)
		add_child(tile)
		tile.global_position = prev_global

		tile.axial_coord = coord
		board_tiles[coord] = tile
		placed_coords.append(coord)

		var tween := create_tween()
		tween.tween_property(tile, "position", axial_to_pixel(coord), 0.1)
		SoundFX.play_place()

	candidate_tiles.clear()

	await _resolve_merges(placed_coords)

	_set_busy(false)
	_spawn_candidate()


func _resolve_merges(coords_to_check: Array[Vector2i]) -> void:
	var queue: Array[Dictionary] = []
	for c in coords_to_check:
		queue.append({"coord": c, "is_chain": false, "combo": 1})

	while queue.size() > 0:
		var item: Dictionary = queue.pop_front()
		var current_coord: Vector2i = item["coord"]
		var is_chain: bool = item["is_chain"]
		var combo: int = item["combo"]

		var center_tile: HexTile = board_tiles.get(current_coord)
		if center_tile == null:
			continue

		var cluster := _find_connected_cluster(current_coord, center_tile.value)
		# First merge needs 3; chain merges (a merged tile touching an equal tile) need only 2
		var min_cluster_size: int = 2 if is_chain else 3
		if cluster.size() < min_cluster_size:
			continue

		await get_tree().create_timer(0.18).timeout

		var target_pos := axial_to_pixel(current_coord)
		var merged_count := cluster.size()
		var new_value := center_tile.value * 2

		# Slide every absorbed tile into the center at the same time
		var absorbed: Array[HexTile] = []
		var tween := create_tween().set_parallel(true)
		for c in cluster:
			if c == current_coord:
				continue
			var absorbed_tile: HexTile = board_tiles[c]
			board_tiles[c] = null
			absorbed.append(absorbed_tile)
			tween.tween_property(absorbed_tile, "position", target_pos, 0.15)
			tween.tween_property(absorbed_tile, "scale", Vector2(0.2, 0.2), 0.15)
		await tween.finished
		for t in absorbed:
			t.queue_free()

		center_tile.set_value(new_value)
		highest_tile_reached = maxi(highest_tile_reached, new_value)

		# Score uses the combo multiplier; level XP is per merge (also boosted by combo)
		var points_earned := new_value * merged_count * combo
		score += points_earned
		_update_score_display()
		_add_level_xp(XP_PER_MERGE * combo)

		# Feedback
		SoundFX.play_merge(combo)
		SoundFX.trigger_haptic(25)
		_spawn_merge_particles(target_pos, center_tile.polygon.color, mini(10 + combo * 4, 40))
		_spawn_score_popup(target_pos, points_earned, center_tile.polygon.color, combo)
		if new_value >= 64 or combo > 1:
			_shake_screen(2.5 + float(combo) * 1.5, 0.16)

		# Re-check the same cell for a chain with an incremented combo counter
		queue.push_front({"coord": current_coord, "is_chain": true, "combo": combo + 1})


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
	var target_tile: HexTile = board_tiles.get(coord)
	if target_tile == null:
		return

	board_tiles[coord] = null

	# Exit hammer mode and pay for it
	is_hammer_mode = false
	hammer_hint_label.visible = false
	_clear_slot_highlights()
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
	if is_game_over and _can_place_candidate():
		_set_game_over(false)
	_refresh_game_over_panel()
	_update_powerup_buttons()
	_save_game()


func _on_reroll_pressed() -> void:
	if busy or is_game_over or is_hammer_mode or gems < REROLL_COST:
		return

	_set_busy(true)
	_add_gems(-REROLL_COST)
	_spawn_floating_text(dock_center + Vector2(0, -60), "REROLL!", Color("#38a3d1"), 18)

	# Shrink the current piece away, then spawn a fresh one
	var tween := create_tween()
	tween.tween_property(candidate_holder, "scale", Vector2.ZERO, 0.12)
	await tween.finished

	_set_busy(false)
	_spawn_candidate()


# =============================================================================
# GAME OVER
# =============================================================================

func _set_game_over(is_over: bool) -> void:
	var newly_over := is_over and not is_game_over
	is_game_over = is_over

	if newly_over:
		SaveManager.delete_save()
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

func _clear_board() -> void:
	_clear_slot_highlights()
	for coord in board_tiles.keys():
		var tile: HexTile = board_tiles[coord]
		if tile != null:
			tile.queue_free()
			board_tiles[coord] = null


func _start_new_game() -> void:
	_flush_best_score()
	is_dragging = false
	is_hammer_mode = false
	hammer_hint_label.visible = false
	_set_busy(false)
	_clear_board()

	score = 0
	_update_score_display()

	current_level = 1
	level_xp = 0
	xp_to_next_level = START_XP_TO_LEVEL
	highest_tile_reached = 16
	_refresh_level_ui(true)

	_set_game_over(false)
	_spawn_candidate()


func _save_game() -> void:
	# Never save mid-merge (board is half-resolved) or a finished game
	if busy or is_game_over or candidate_tiles.is_empty():
		return

	var saved_board: Dictionary = {}
	for coord in board_tiles.keys():
		var tile: HexTile = board_tiles[coord]
		if tile != null:
			saved_board[str(coord.x) + "," + str(coord.y)] = tile.value

	var cand_values: Array[int] = []
	for tile in candidate_tiles:
		cand_values.append(tile.value)

	# Gems are saved in the persistent meta file, not in the run save
	SaveManager.write_save({
		"score": score,
		"best_score": best_score,
		"current_level": current_level,
		"level_xp": level_xp,
		"xp_to_next_level": xp_to_next_level,
		"highest_tile_reached": highest_tile_reached,
		"board": saved_board,
		"candidate": {
			"is_pair": is_pair,
			"pair_dir_index": pair_dir_index,
			"values": cand_values
		}
	})


func _restore_game(data: Dictionary) -> void:
	is_dragging = false
	is_hammer_mode = false
	hammer_hint_label.visible = false
	_set_busy(false)
	_clear_board()

	# One-time migration: older saves kept gems inside the run save
	if not SaveManager.read_meta().has("gems"):
		gems = int(data.get("gems", 0))
		_persist_gems()
	gems_label.text = str(gems)

	score = int(data.get("score", 0))
	best_score = maxi(best_score, int(data.get("best_score", 0)))
	best_dirty = true
	_update_score_display()

	current_level = int(data.get("current_level", 1))
	level_xp = int(data.get("level_xp", 0))
	xp_to_next_level = int(data.get("xp_to_next_level", START_XP_TO_LEVEL))
	highest_tile_reached = int(data.get("highest_tile_reached", 16))
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
		var tile := HexTile.new(int(saved_board[key]), HEX_RADIUS)
		tile.axial_coord = coord
		tile.position = axial_to_pixel(coord)
		add_child(tile)
		board_tiles[coord] = tile

	# Candidate (fall back to a fresh piece if the saved one is missing/empty)
	var cand_data: Dictionary = data.get("candidate", {})
	var cand_values: Array[int] = []
	for v in cand_data.get("values", []):
		cand_values.append(int(v))

	if cand_values.is_empty():
		_set_game_over(false)
		_spawn_candidate()
		return

	var pair_saved := bool(cand_data.get("is_pair", false)) and cand_values.size() >= 2
	_build_candidate(cand_values, pair_saved, int(cand_data.get("pair_dir_index", DEFAULT_PAIR_DIR)))
	_finish_candidate_setup(false)


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

# Called once the scene is ready: resume the saved run, or start a new one.
# (The home screen's NEW button deletes the save before launching, so this just follows what exists.)
func _begin_session() -> void:
	var saved_data: Dictionary = SaveManager.read_save()
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
