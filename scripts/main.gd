extends Node2D

# --- CONFIGURATION ---
const GRID_RADIUS: int = 3          # 3 rings around center = 37 hexes (matches screenshot)
const HEX_RADIUS: float = 36.0
#const board_center: Vector2 = Vector2(270, 420)
#const dock_center: Vector2 = Vector2(270, 770)
const GEMS_PER_LEVEL_UP: int = 25
const HAMMER_COST: int = 100
const REROLL_COST: int = 175
# Axial directions for pointy-topped hexes
const AXIAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),   # East
	Vector2i(0, 1),   # Southeast
	Vector2i(-1, 1),  # Southwest
	Vector2i(-1, 0),  # West
	Vector2i(0, -1),  # Northwest
	Vector2i(1, -1)   # Northeast
]

# Dynamic Layout Anchors (computed at runtime for any aspect ratio + notch)
var screen_size: Vector2 = Vector2(540, 960)
var safe_top_y: float = 40.0
var safe_bottom_y: float = 940.0
var board_center: Vector2 = Vector2(270, 440)
var dock_center: Vector2 = Vector2(270, 790)


# --- STATE ---
var board_tiles: Dictionary = {}    # Vector2i -> HexTile (null if empty)
var slot_visuals: Dictionary = {}   # Vector2i -> Polygon2D (background hexes)

var score: int = 0
var score_label: Label
var game_over_panel: Panel

# Spawner / Candidate piece state
var candidate_holder: Node2D
var candidate_tiles: Array[HexTile] = []
var is_pair: bool = false
var pair_dir_index: int = 1         # Index in AXIAL_DIRECTIONS (0 to 5)
var highest_tile_reached: int = 16

# Input tracking
var is_dragging: bool = false
var drag_start_pos: Vector2 = Vector2.ZERO
var has_dragged_far: bool = false
const DRAG_THRESHOLD: float = 12.0

# Level & Progress Bar state
var current_level: int = 1
var level_xp: int = 0
var xp_to_next_level: int = 250

var progress_bar: ProgressBar
var curr_lvl_label: Label
var next_lvl_label: Label

# Gem Economy state
var gems: int = 0
var gems_label: Label

# Power-Up Costs & State
var is_hammer_mode: bool = false
var hammer_button: Button
var reroll_button: Button
var hammer_hint_label: Label

var best_score: int = 0
var home_overlay: ColorRect
var play_button: Button
var reset_save_button: Button

var dock_arrows_holder: Node2D
var previewed_tiles: Array[HexTile] = []
var camera: Camera2D
var shake_tween: Tween

var best_score_label: Label
var calendar_badge: Panel
var settings_overlay: ColorRect
var daily_overlay: ColorRect
var sound_toggle_btn: Button
var haptics_toggle_btn: Button
var claim_daily_btn: Button
var daily_status_label: Label

func _ready() -> void:
	_compute_responsive_layout()
	_setup_background_and_ui()
	_setup_gem_ui()
	_setup_level_bar()
	_setup_powerup_ui()
	_build_board()
	_setup_home_screen()
	_setup_juice_nodes()

# --- SETUP & MATH ---

func _compute_responsive_layout() -> void:
	screen_size = get_viewport_rect().size
	
	# Convert hardware safe area (in OS screen pixels) into Godot canvas coordinates
	var window_size := Vector2(DisplayServer.window_get_size())
	var safe_rect := Rect2(DisplayServer.get_display_safe_area())
	
	var top_inset: float = 16.0
	var bottom_inset: float = 20.0
	
	if window_size.x > 0.0 and window_size.y > 0.0:
		var scale_y := screen_size.y / window_size.y
		# Distance from top of physical screen to safe area top (clears notch / Dynamic Island)
		top_inset = maxf(safe_rect.position.y * scale_y, 16.0)
		# Distance from safe area bottom to physical screen bottom (clears home indicator bar)
		var raw_bottom := (window_size.y - (safe_rect.position.y + safe_rect.size.y)) * scale_y
		bottom_inset = maxf(raw_bottom, 20.0)
		
	safe_top_y = top_inset + 12.0
	safe_bottom_y = screen_size.y - bottom_inset
	
	var center_x := screen_size.x * 0.5
	
	# Anchor the dock comfortably above the bottom safe edge
	dock_center = Vector2(center_x, safe_bottom_y - 135.0)
	
	# Center the hex board midway between the level progress bar and the dock
	var header_bottom := safe_top_y + 115.0
	var dock_top := dock_center.y - 110.0
	board_center = Vector2(center_x, (header_bottom + dock_top) * 0.5)


func _setup_background_and_ui() -> void:
	# Dark charcoal background
	var bg = ColorRect.new()
	bg.color = Color("#242426")
	bg.size = screen_size
	add_child(bg)
	
	# Score Display
	_setup_top_header_ui()
	
	# Spawner Dock Ring Visual
	var dock_ring = Line2D.new()
	var pts = PackedVector2Array()
	for i in range(65):
		var a = (TAU / 64.0) * i
		pts.append(dock_center + Vector2(cos(a), sin(a)) * 75.0)
	dock_ring.points = pts
	dock_ring.width = 4.0
	dock_ring.default_color = Color("#3a3a3d")
	add_child(dock_ring)
	
	# Game Over Banner (Hidden initially)
	_setup_game_over_ui()
	
	_setup_level_bar()
	_setup_gem_ui()
	_setup_powerup_ui()

func _setup_game_over_ui() -> void:
	var panel_size := Vector2(340, 124)
	game_over_panel = Panel.new()
	game_over_panel.size = panel_size
	game_over_panel.position = board_center - (panel_size * 0.5)
	game_over_panel.z_index = 30
	game_over_panel.visible = false
	
	# Dark rounded card with a crisp coral/red border
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#18181a", 0.94)
	style.set_corner_radius_all(18)
	style.border_width_top = 3
	style.border_width_bottom = 3
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_color = Color("#ff7979")
	style.shadow_color = Color(0, 0, 0, 0.6)
	style.shadow_size = 12
	game_over_panel.add_theme_stylebox_override("panel", style)
	add_child(game_over_panel)
	
	# Primary Headline
	var title_lbl := Label.new()
	title_lbl.text = "NO MOVES LEFT!"
	title_lbl.position = Vector2(0, 20)
	title_lbl.size = Vector2(panel_size.x, 38)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 28)
	title_lbl.add_theme_color_override("font_color", Color("#ff7979"))
	game_over_panel.add_child(title_lbl)
	
	# Subtext Prompt
	var sub_lbl := Label.new()
	sub_lbl.text = "Tap anywhere to start a new game"
	sub_lbl.position = Vector2(0, 68)
	sub_lbl.size = Vector2(panel_size.x, 28)
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_lbl.add_theme_font_size_override("font_size", 16)
	sub_lbl.add_theme_color_override("font_color", Color("#d0d0d8"))
	game_over_panel.add_child(sub_lbl)


func _set_game_over(is_over: bool) -> void:
	game_over_panel.visible = is_over
	if is_over:
		SaveManager.delete_save()
		game_over_panel.pivot_offset = game_over_panel.size * 0.5
		game_over_panel.scale = Vector2(0.8, 0.8)
		var tween := create_tween()
		tween.tween_property(game_over_panel, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _build_board() -> void:
	for q in range(-GRID_RADIUS, GRID_RADIUS + 1):
		var r1 = max(-GRID_RADIUS, -q - GRID_RADIUS)
		var r2 = min(GRID_RADIUS, -q + GRID_RADIUS)
		for r in range(r1, r2 + 1):
			var coord = Vector2i(q, r)
			board_tiles[coord] = null
			
			# Create empty dark slot polygon
			var slot = Polygon2D.new()
			slot.polygon = HexTile._create_hex_points(HEX_RADIUS - 2.0)
			slot.color = Color("#333336")
			slot.position = axial_to_pixel(coord)
			add_child(slot)
			slot_visuals[coord] = slot

func axial_to_pixel(hex: Vector2i) -> Vector2:
	var x = HEX_RADIUS * sqrt(3.0) * (hex.x + hex.y / 2.0)
	var y = HEX_RADIUS * (3.0 / 2.0) * hex.y
	return board_center + Vector2(x, y)

func pixel_to_axial(pos: Vector2) -> Vector2i:
	var pt = pos - board_center
	var q = (sqrt(3.0) / 3.0 * pt.x - 1.0 / 3.0 * pt.y) / HEX_RADIUS
	var r = (2.0 / 3.0 * pt.y) / HEX_RADIUS
	return axial_round(Vector2(q, r))

func axial_round(frac: Vector2) -> Vector2i:
	var s = -frac.x - frac.y
	var rq = round(frac.x)
	var rr = round(frac.y)
	var rs = round(s)
	
	var q_diff = abs(rq - frac.x)
	var r_diff = abs(rr - frac.y)
	var s_diff = abs(rs - s)
	
	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))

# --- CANDIDATE SPAWNING & ROTATION ---

func _spawn_candidate() -> void:
	if candidate_holder:
		candidate_holder.queue_free()
	candidate_tiles.clear()
	
	candidate_holder = Node2D.new()
	candidate_holder.position = dock_center
	add_child(candidate_holder)
	
	# 65% chance to spawn a pair if there is room on the board for pairs
	is_pair = randf() < 0.65 and _can_place_any_pair()
	pair_dir_index = 1 # Default diagonal offset like screenshot
	
	var tile_a = HexTile.new(_pick_random_value(), HEX_RADIUS)
	candidate_holder.add_child(tile_a)
	candidate_tiles.append(tile_a)
	
	if is_pair:
		var tile_b = HexTile.new(_pick_random_value(), HEX_RADIUS)
		candidate_holder.add_child(tile_b)
		candidate_tiles.append(tile_b)
		_update_candidate_pair_positions(false)
		
	if not _can_place_candidate():
		_set_game_over(true)
	
	_update_powerup_buttons()
	if not _can_place_candidate():
		_set_game_over(true)
	else:
		_set_game_over(false)
		_save_game()

func _get_highest_board_value() -> int:
	var max_val = 2
	for tile in board_tiles.values():
		if tile != null and tile.value > max_val:
			max_val = tile.value
	return max_val

func _pick_random_value() -> int:
	# Update the highest milestone reached in this session
	highest_tile_reached = max(highest_tile_reached, _get_highest_board_value())
	
	# Scale the active 4-tier spawn window based on the highest tile reached
	var base_tier: int = 2
	if highest_tile_reached >= 2048:
		base_tier = 16  # Pool: [16, 32, 64, 128]
	elif highest_tile_reached >= 512:
		base_tier = 8   # Pool: [8, 16, 32, 64]
	elif highest_tile_reached >= 64:
		base_tier = 4   # Pool: [4, 8, 16, 32]
	else:
		base_tier = 2   # Pool: [2, 4, 8, 16]
		
	# Weighted distribution favoring the lower two tiers of the active window
	var pool: Array[int] = [
		base_tier, base_tier, base_tier,
		base_tier * 2, base_tier * 2,
		base_tier * 4,
		base_tier * 8
	]
	return pool[randi() % pool.size()]

func _rotate_candidate() -> void:
	if not is_pair:
		return
	pair_dir_index = (pair_dir_index + 1) % 6
	_update_candidate_pair_positions(true)
	SoundFX.play_rotate()
	
	if dock_arrows_holder:
		var tween := create_tween()
		tween.tween_property(dock_arrows_holder, "rotation_degrees", dock_arrows_holder.rotation_degrees + 60.0, 0.14)
	_save_game()

func _update_candidate_pair_positions(animate: bool) -> void:
	var dir = AXIAL_DIRECTIONS[pair_dir_index]
	var offset = axial_to_pixel(dir) - board_center
	
	# Center the pair around the dock pivot
	var pos_a = -offset * 0.5
	var pos_b = offset * 0.5
	
	if animate:
		var tween = create_tween().set_parallel(true)
		tween.tween_property(candidate_tiles[0], "position", pos_a, 0.12)
		tween.tween_property(candidate_tiles[1], "position", pos_b, 0.12)
	else:
		candidate_tiles[0].position = pos_a
		candidate_tiles[1].position = pos_b

# --- INPUT HANDLING (TAP TO ROTATE / DRAG TO PLACE) ---

func _input(event: InputEvent) -> void:
	if game_over_panel.visible:
		if event is InputEventMouseButton and event.pressed:
			_start_new_game()
		return
	var pointer_pos := get_global_mouse_position()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Check if click is near the dock
			if pointer_pos.distance_to(dock_center) < 110.0:
				is_dragging = true
				has_dragged_far = false
				drag_start_pos = event.position
		else:
			if is_dragging:
				is_dragging = false
				if not has_dragged_far:
					# Short tap -> Rotate!
					_return_candidate_to_dock()
					_rotate_candidate()
				else:
					# Drag release -> Attempt drop
					_try_place_candidate()
				_clear_slot_highlights()

	elif event is InputEventMouseMotion and is_dragging:
		if pointer_pos.distance_to(drag_start_pos) > DRAG_THRESHOLD:
			has_dragged_far = true
			
		if has_dragged_far:
			# Offset slightly upward so finger doesn't cover the tiles on mobile
			candidate_holder.position = pointer_pos + Vector2(0, -45)
			_highlight_hover_slots()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# If Hammer targeting is active, check if the player tapped an occupied board tile
			if is_hammer_mode:
				var clicked_coord = pixel_to_axial(pointer_pos)
				if board_tiles.has(clicked_coord) and board_tiles[clicked_coord] != null:
					_use_hammer_on_coord(clicked_coord)
				return
				
			# Normal dock drag/tap check
			if pointer_pos.distance_to(dock_center) < 110.0:
				is_dragging = true
				has_dragged_far = false
				drag_start_pos = event.position
	if game_over_panel.visible:
		if event is InputEventMouseButton and event.pressed:
			_start_new_game()
		return
	
				
func _get_target_coords() -> Array[Vector2i]:
	var world_pos_a = candidate_tiles[0].global_position
	var coord_a = pixel_to_axial(world_pos_a)
	
	if not is_pair:
		return [coord_a]
	else:
		var coord_b = coord_a + AXIAL_DIRECTIONS[pair_dir_index]
		return [coord_a, coord_b]

func _are_coords_valid_and_empty(coords: Array[Vector2i]) -> bool:
	for c in coords:
		if not board_tiles.has(c) or board_tiles[c] != null:
			return false
	return true

func _highlight_hover_slots() -> void:
	_clear_slot_highlights()
	var targets := _get_target_coords()
	if not _are_coords_valid_and_empty(targets):
		return
		
	for c in targets:
		slot_visuals[c].color = Color("#505056")
		
	# Temporarily simulate placement to preview potential merges
	for i in range(candidate_tiles.size()):
		board_tiles[targets[i]] = candidate_tiles[i]
		
	for i in range(targets.size()):
		var coord := targets[i]
		var val := candidate_tiles[i].value
		var cluster := _find_connected_cluster(coord, val)
		if cluster.size() >= 3:
			for c in cluster:
				if not targets.has(c):
					var tile: HexTile = board_tiles[c]
					if tile and not previewed_tiles.has(tile):
						previewed_tiles.append(tile)
						tile.modulate = Color(1.35, 1.35, 1.35)
						tile.scale = Vector2(1.08, 1.08)
						
	# Clean up temporary simulation
	for c in targets:
		board_tiles[c] = null

func _clear_slot_highlights() -> void:
	for slot in slot_visuals.values():
		slot.color = Color("#333336")
	for tile in previewed_tiles:
		if is_instance_valid(tile):
			tile.modulate = Color.WHITE
			tile.scale = Vector2.ONE
	previewed_tiles.clear()

func _return_candidate_to_dock() -> void:
	var tween = create_tween()
	tween.tween_property(candidate_holder, "position", dock_center, 0.15)

# --- PLACEMENT & CHAIN MERGE RESOLUTION ---

func _try_place_candidate() -> void:
	var targets = _get_target_coords()
	if not _are_coords_valid_and_empty(targets):
		_return_candidate_to_dock()
		return
		
	# Transfer tiles from candidate holder to the main board
	var placed_coords: Array[Vector2i] = []
	for i in range(candidate_tiles.size()):
		var tile = candidate_tiles[i]
		var coord = targets[i]
		
		var prev_global = tile.global_position
		candidate_holder.remove_child(tile)
		add_child(tile)
		tile.global_position = prev_global
		
		tile.axial_coord = coord
		board_tiles[coord] = tile
		placed_coords.append(coord)
		
		# Snap smoothly into grid slot
		var tween = create_tween()
		tween.tween_property(tile, "position", axial_to_pixel(coord), 0.1)
		SoundFX.play_place()
		
	candidate_tiles.clear()
	
	# Resolve merges sequentially for placed tiles, then spawn next piece
	await _resolve_merges(placed_coords)
	_spawn_candidate()

func _resolve_merges(coords_to_check: Array[Vector2i]) -> void:
	var queue: Array[Dictionary] = []
	for c in coords_to_check:
		queue.append({"coord": c, "is_chain": false, "combo": 1})
	
	while queue.size() > 0:
		var item = queue.pop_front()
		var current_coord: Vector2i = item["coord"]
		var is_chain: bool = item["is_chain"]
		var combo: int = item["combo"]
		
		var center_tile: HexTile = board_tiles.get(current_coord)
		if center_tile == null:
			continue
			
		var cluster = _find_connected_cluster(current_coord, center_tile.value)
		var min_cluster_size = 2 if is_chain else 3
		
		if cluster.size() >= min_cluster_size:
			await get_tree().create_timer(0.18).timeout
			
			var target_pos = axial_to_pixel(current_coord)
			var merged_count = cluster.size()
			var old_value = center_tile.value
			var new_value = old_value * 2
			
			var tween = create_tween().set_parallel(true)
			for c in cluster:
				if c != current_coord:
					var absorbed_tile: HexTile = board_tiles[c]
					board_tiles[c] = null
					tween.tween_property(absorbed_tile, "position", target_pos, 0.15)
					tween.tween_property(absorbed_tile, "scale", Vector2(0.2, 0.2), 0.15)
					tween.chain().tween_callback(absorbed_tile.queue_free)
					
			await tween.finished
			
			# Double value, apply combo multiplier to score, and update UI
			center_tile.set_value(new_value)
			var points_earned = new_value * merged_count * combo
			score += points_earned
			score_label.text = "SCORE: " + str(score)
			_update_score_display()
			_add_level_xp(points_earned)
			
			# Spawn Score Popup (and Combo callout if chain > 1)
			SoundFX.play_merge(combo)
			SoundFX.trigger_haptic(25)
			_spawn_merge_particles(target_pos, center_tile.polygon.color, 10 + combo * 4)
			if new_value >= 64 or combo > 1:
				_shake_screen(2.5 + float(combo) * 1.5, 0.16)
			# Re-queue with incremented combo counter
			queue.push_front({"coord": current_coord, "is_chain": true, "combo": combo + 1})

# Flood-fill (BFS) to find all connected tiles of the same value
func _find_connected_cluster(start: Vector2i, target_val: int) -> Array[Vector2i]:
	var visited: Array[Vector2i] = [start]
	var frontier: Array[Vector2i] = [start]
	
	while frontier.size() > 0:
		var curr = frontier.pop_front()
		for dir in AXIAL_DIRECTIONS:
			var neighbor = curr + dir
			if board_tiles.has(neighbor) and not visited.has(neighbor):
				var n_tile = board_tiles[neighbor]
				if n_tile != null and n_tile.value == target_val:
					visited.append(neighbor)
					frontier.append(neighbor)
	return visited

# --- GAME OVER / VALID MOVE CHECKS ---

func _can_place_any_pair() -> bool:
	for coord in board_tiles.keys():
		if board_tiles[coord] == null:
			for dir in AXIAL_DIRECTIONS:
				var neighbor = coord + dir
				if board_tiles.has(neighbor) and board_tiles[neighbor] == null:
					return true
	return false

func _can_place_candidate() -> bool:
	for coord in board_tiles.keys():
		if board_tiles[coord] == null:
			if not is_pair:
				return true
			else:
				for dir in AXIAL_DIRECTIONS:
					var neighbor = coord + dir
					if board_tiles.has(neighbor) and board_tiles[neighbor] == null:
						return true
	return false


func _setup_level_bar() -> void:
	var center_x := screen_size.x * 0.5
	var bar_width: float = 220.0
	var bar_height: float = 16.0
	var bar_pos := Vector2(center_x - bar_width * 0.5, safe_top_y + 76.0)
	
	# 1. Background & Fill Styling for ProgressBar
	progress_bar = ProgressBar.new()
	progress_bar.position = bar_pos
	progress_bar.size = Vector2(bar_width, bar_height)
	progress_bar.show_percentage = false
	progress_bar.max_value = xp_to_next_level
	progress_bar.value = 0
	
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color("#18181a")
	bg_style.set_corner_radius_all(8)
	progress_bar.add_theme_stylebox_override("background", bg_style)
	
	var fill_style = StyleBoxFlat.new()
	fill_style.bg_color = Color("#5b7cfa") # Blue fill matching screenshot
	fill_style.set_corner_radius_all(8)
	progress_bar.add_theme_stylebox_override("fill", fill_style)
	add_child(progress_bar)
	
	# 2. Left Badge (Current Level - Yellow Circle)
	curr_lvl_label = _create_level_badge(
		bar_pos + Vector2(-18, -10),
		Color("#f9ca24"),
		str(current_level)
	)
	
	# 3. Right Badge (Next Level - Green Circle)
	next_lvl_label = _create_level_badge(
		bar_pos + Vector2(bar_width - 18, -10),
		Color("#36b37e"),
		str(current_level + 1)
	)

func _create_level_badge(pos: Vector2, bg_color: Color, text_val: String) -> Label:
	var badge = Panel.new()
	badge.position = pos
	badge.size = Vector2(36, 36)
	
	var style = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(18)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color.WHITE
	badge.add_theme_stylebox_override("panel", style)
	add_child(badge)
	
	var lbl = Label.new()
	lbl.text = text_val
	lbl.size = Vector2(36, 36)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color("#1e1e24"))
	badge.add_child(lbl)
	return lbl


func _add_level_xp(points: int) -> void:
	level_xp += points
	var total_gems_earned: int = 0
	
	while level_xp >= xp_to_next_level:
		level_xp -= xp_to_next_level
		current_level += 1
		xp_to_next_level = int(xp_to_next_level * 1.25)
		total_gems_earned += GEMS_PER_LEVEL_UP
		
		curr_lvl_label.text = str(current_level)
		next_lvl_label.text = str(current_level + 1)
		progress_bar.max_value = xp_to_next_level
		
	if total_gems_earned > 0:
		_add_gems(total_gems_earned)
		_spawn_floating_text(board_center + Vector2(0, -140), "LEVEL UP!", Color("#f9ca24"), 30)
		_spawn_floating_text(board_center + Vector2(0, -108), "+" + str(total_gems_earned) + " GEMS", Color("#ff8ef8"), 20)
		SoundFX.play_level_up()
		
	var tween = create_tween()
	tween.tween_property(progress_bar, "value", float(level_xp), 0.25)
	

func _spawn_floating_text(world_pos: Vector2, text_str: String, color: Color = Color.WHITE, font_size: int = 22) -> void:
	var lbl = Label.new()
	lbl.text = text_str
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	lbl.add_theme_constant_override("outline_size", 4)
	
	# Center horizontally around world_pos
	lbl.size = Vector2(200, 40)
	lbl.position = world_pos - Vector2(100, 20)
	lbl.z_index = 10
	add_child(lbl)
	
	# Pop scale + float upward + fade out
	lbl.scale = Vector2(0.6, 0.6)
	lbl.pivot_offset = Vector2(100, 20)
	
	var tween = create_tween().set_parallel(true)
	tween.tween_property(lbl, "scale", Vector2(1.1, 1.1), 0.15).set_trans(Tween.TRANS_BACK)
	tween.tween_property(lbl, "position:y", lbl.position.y - 55.0, 0.75).set_ease(Tween.EASE_OUT)
	tween.tween_property(lbl, "modulate:a", 0.0, 0.45).set_delay(0.3)
	tween.chain().tween_callback(lbl.queue_free)


func _setup_gem_ui() -> void:
	var center_x := screen_size.x * 0.5
	# Rounded pill background in top-left (matches reference layout)
	var pill = Panel.new()
	pill.position = Vector2(center_x - 246.0, safe_top_y + 8.0)
	pill.size = Vector2(120, 38)
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color("#18181a")
	style.set_corner_radius_all(19)
	pill.add_theme_stylebox_override("panel", style)
	add_child(pill)
	
	# Procedural Pink/Magenta Diamond Icon
	var gem_poly = Polygon2D.new()
	gem_poly.polygon = PackedVector2Array([
		Vector2(-8, -11),  # Top-left facet
		Vector2(8, -11),   # Top-right facet
		Vector2(14, -3),   # Right corner
		Vector2(0, 12),    # Bottom point
		Vector2(-14, -3)   # Left corner
	])
	gem_poly.color = Color("#e056fd")
	gem_poly.position = Vector2(22, 19)
	pill.add_child(gem_poly)
	
	# Inner highlight facet for depth
	var inner_facet = Polygon2D.new()
	inner_facet.polygon = PackedVector2Array([
		Vector2(-5, -11),
		Vector2(5, -11),
		Vector2(7, -3),
		Vector2(0, 9),
		Vector2(-7, -3)
	])
	inner_facet.color = Color("#ff8ef8")
	gem_poly.add_child(inner_facet)
	
	# Gem Count Label
	gems_label = Label.new()
	gems_label.text = str(gems)
	gems_label.position = Vector2(44, 0)
	gems_label.size = Vector2(68, 38)
	gems_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gems_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	gems_label.add_theme_font_size_override("font_size", 18)
	gems_label.add_theme_color_override("font_color", Color.WHITE)
	pill.add_child(gems_label)


func _add_gems(amount: int) -> void:
	gems += amount
	gems_label.text = str(gems)
	_update_powerup_buttons()
	# Quick scale pulse on the gem counter when rewarded
	gems_label.pivot_offset = gems_label.size * 0.5
	var tween = create_tween()
	tween.tween_property(gems_label, "scale", Vector2(1.3, 1.3), 0.1)
	tween.tween_property(gems_label, "scale", Vector2(1.0, 1.0), 0.1)


func _setup_powerup_ui() -> void:
	# 1. Hammer Button (Bottom-Left)
	hammer_button = _create_powerup_button(
		Vector2(dock_center.x - 225.0, dock_center.y - 45.0),
		HAMMER_COST,
		_on_hammer_pressed
	)
	_draw_hammer_icon(hammer_button)
	
	# 2. Reroll Button (Bottom-Right)
	reroll_button = _create_powerup_button(
		Vector2(dock_center.x + 135.0, dock_center.y - 45.0),
		REROLL_COST,
		_on_reroll_pressed
	)
	_draw_reroll_icon(reroll_button)
	
	# 3. Targeting Banner for Hammer Mode (Hidden by default)
	hammer_hint_label = Label.new()
	hammer_hint_label.text = "TAP A TILE TO SMASH (TAP BUTTON TO CANCEL)"
	hammer_hint_label.position = Vector2(0, dock_center.y - 105.0)
	hammer_hint_label.size = Vector2(screen_size.x, 30)
	hammer_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hammer_hint_label.add_theme_font_size_override("font_size", 15)
	hammer_hint_label.add_theme_color_override("font_color", Color("#ff7979"))
	hammer_hint_label.visible = false
	add_child(hammer_hint_label)
	
	_update_powerup_buttons()

func _create_powerup_button(pos: Vector2, cost: int, callback: Callable) -> Button:
	var btn = Button.new()
	btn.position = pos
	btn.size = Vector2(90, 90)
	btn.focus_mode = Control.FOCUS_NONE
	
	var normal_style = StyleBoxFlat.new()
	normal_style.bg_color = Color("#333338")
	normal_style.set_corner_radius_all(18)
	normal_style.border_width_bottom = 4
	normal_style.border_color = Color("#1e1e22")
	btn.add_theme_stylebox_override("normal", normal_style)
	
	var hover_style = normal_style.duplicate()
	hover_style.bg_color = Color("#424248")
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	
	btn.pressed.connect(callback)
	add_child(btn)
	
	# Mini Gem + Cost Label below the button
	var cost_lbl = Label.new()
	cost_lbl.text = "♦ " + str(cost)
	cost_lbl.position = pos + Vector2(0, 94)
	cost_lbl.size = Vector2(90, 24)
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost_lbl.add_theme_font_size_override("font_size", 16)
	cost_lbl.add_theme_color_override("font_color", Color("#ff8ef8"))
	add_child(cost_lbl)
	
	return btn

func _draw_hammer_icon(parent: Control) -> void:
	# Wooden handle
	var handle = Polygon2D.new()
	handle.polygon = PackedVector2Array([
		Vector2(-4, -10), Vector2(4, -10),
		Vector2(5, 24), Vector2(-5, 24)
	])
	handle.color = Color("#d4a373")
	handle.position = Vector2(45, 45)
	handle.rotation_degrees = -35.0
	parent.add_child(handle)
	
	# Gold/Steel mallet head
	var head = Polygon2D.new()
	head.polygon = PackedVector2Array([
		Vector2(-18, -10), Vector2(18, -10),
		Vector2(18, 6), Vector2(-18, 6)
	])
	head.color = Color("#f9ca24")
	head.position = Vector2(0, -12)
	handle.add_child(head)

func _draw_reroll_icon(parent: Control) -> void:
	# Circular refresh arrow icon using Line2D + arrowhead
	var arc = Line2D.new()
	var pts = PackedVector2Array()
	for i in range(25):
		var a = deg_to_rad(-45.0 + (270.0 / 24.0) * i)
		pts.append(Vector2(45, 45) + Vector2(cos(a), sin(a)) * 20.0)
	arc.points = pts
	arc.width = 5.0
	arc.default_color = Color("#38a3d1")
	parent.add_child(arc)
	
	var arrow = Polygon2D.new()
	arrow.polygon = PackedVector2Array([
		Vector2(0, -8), Vector2(12, 0), Vector2(0, 8)
	])
	arrow.color = Color("#f9ca24")
	arrow.position = Vector2(45, 25)
	parent.add_child(arrow)

func _update_powerup_buttons() -> void:
	if not hammer_button or not reroll_button:
		return
		
	var has_tiles_on_board := false
	for tile in board_tiles.values():
		if tile != null:
			has_tiles_on_board = true
			break
			
	var can_hammer = gems >= HAMMER_COST and has_tiles_on_board
	hammer_button.disabled = not can_hammer
	hammer_button.modulate = Color.WHITE if (can_hammer or is_hammer_mode) else Color(1, 1, 1, 0.4)
	
	var can_reroll = gems >= REROLL_COST and not is_hammer_mode
	reroll_button.disabled = not can_reroll
	reroll_button.modulate = Color.WHITE if can_reroll else Color(1, 1, 1, 0.4)


func _on_hammer_pressed() -> void:
	# Toggle targeting mode on/off
	is_hammer_mode = not is_hammer_mode
	hammer_hint_label.visible = is_hammer_mode
	
	# Highlight occupied slots in red when targeting
	for coord in board_tiles.keys():
		if is_hammer_mode and board_tiles[coord] != null:
			slot_visuals[coord].color = Color("#6e3535")
		else:
			slot_visuals[coord].color = Color("#333336")
			
	_update_powerup_buttons()
	_save_game()

func _use_hammer_on_coord(coord: Vector2i) -> void:
	if not board_tiles.has(coord) or board_tiles[coord] == null:
		return
		
	var target_tile: HexTile = board_tiles[coord]
	board_tiles[coord] = null
	
	# Exit hammer mode and deduct gems
	is_hammer_mode = false
	hammer_hint_label.visible = false
	_clear_slot_highlights()
	_add_gems(-HAMMER_COST)
	
	# Smash animation + floating feedback
	_spawn_floating_text(target_tile.global_position, "SMASH!", Color("#ff7979"), 20)
	var tween = create_tween().set_parallel(true)
	tween.tween_property(target_tile, "scale", Vector2(1.4, 1.4), 0.08)
	tween.tween_property(target_tile, "modulate:a", 0.0, 0.15)
	tween.chain().tween_callback(target_tile.queue_free)
	SoundFX.trigger_haptic(25)
	SoundFX.play_smash()
	_spawn_merge_particles(target_tile.global_position, target_tile.polygon.color, 16)
	_shake_screen(6.0, 0.2)
	
	# Re-check if current candidate can now fit on the board
	if _can_place_candidate():
		_set_game_over(false)

func _on_reroll_pressed() -> void:
	if gems < REROLL_COST or is_hammer_mode:
		return
		
	_add_gems(-REROLL_COST)
	_spawn_floating_text(dock_center + Vector2(0, -60), "REROLL!", Color("#38a3d1"), 18)
	
	# Shrink current candidate out, then spawn a fresh piece
	var tween = create_tween()
	tween.tween_property(candidate_holder, "scale", Vector2.ZERO, 0.12)
	await tween.finished
	_spawn_candidate()

func _setup_home_screen() -> void:
	var center_x := screen_size.x * 0.5
	home_overlay = ColorRect.new()
	home_overlay.color = Color("#1e1e22")
	home_overlay.size = screen_size
	home_overlay.z_index = 50
	add_child(home_overlay)
	
	# Title Logo
	var title = Label.new()
	title.text = "HEX MERGE"
	title.position = Vector2(0, screen_size.y * 0.22)
	title.size = Vector2(screen_size.x, 70)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color.WHITE)
	home_overlay.add_child(title)
	
	# Decorative Hex Icon under title
	var deco_hex = HexTile.new(64, 48.0)
	deco_hex.position = Vector2(center_x, screen_size.y * 0.37)
	home_overlay.add_child(deco_hex)
	
	var save_exists := SaveManager.has_save()
	play_button = _create_menu_button(
		Vector2(145, 480),
		Vector2(250, 68),
		"CONTINUE" if save_exists else "PLAY",
		Color("#36b37e"),
		_on_play_pressed
	)
	play_button.position = Vector2(center_x - 125.0, screen_size.y * 0.50)
	home_overlay.add_child(play_button)
	
	reset_save_button = _create_menu_button(
		Vector2(170, 570),
		Vector2(200, 52),
		"RESET SAVE",
		Color("#eb4d4b"),
		_on_reset_save_pressed
	)
	reset_save_button.position = Vector2(center_x - 100.0, screen_size.y * 0.60)
	reset_save_button.visible = save_exists
	home_overlay.add_child(reset_save_button)

func _create_menu_button(pos: Vector2, btn_size: Vector2, text_str: String, bg_color: Color, callback: Callable) -> Button:
	var btn = Button.new()
	btn.position = pos
	btn.size = btn_size
	btn.text = text_str
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_color_override("font_color", Color.WHITE)
	
	var style = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(16)
	style.border_width_bottom = 5
	style.border_color = bg_color.darkened(0.35)
	btn.add_theme_stylebox_override("normal", style)
	
	var hover = style.duplicate()
	hover.bg_color = bg_color.lightened(0.1)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	
	btn.pressed.connect(callback)
	return btn

func _on_play_pressed() -> void:
	home_overlay.visible = false
	var saved_data := SaveManager.read_save()
	if not saved_data.is_empty():
		_restore_game(saved_data)
	else:
		_start_new_game()

func _on_reset_save_pressed() -> void:
	SaveManager.delete_save()
	play_button.text = "PLAY"
	reset_save_button.visible = false

func _start_new_game() -> void:
	# Clear any existing board tiles
	for coord in board_tiles.keys():
		if board_tiles[coord] != null:
			board_tiles[coord].queue_free()
			board_tiles[coord] = null
			
	score = 0
	score_label.text = "SCORE: 0"
	_update_score_display()
	
	gems = 0
	gems_label.text = "0"
	
	current_level = 1
	level_xp = 0
	xp_to_next_level = 250
	highest_tile_reached = 16
	
	curr_lvl_label.text = "1"
	next_lvl_label.text = "2"
	progress_bar.max_value = xp_to_next_level
	progress_bar.value = 0
	
	_set_game_over(false)
	_spawn_candidate()


func _save_game() -> void:
	var saved_board: Dictionary = {}
	for coord in board_tiles.keys():
		var tile: HexTile = board_tiles[coord]
		if tile != null:
			saved_board[str(coord.x) + "," + str(coord.y)] = tile.value
			
	var cand_values: Array[int] = []
	for tile in candidate_tiles:
		cand_values.append(tile.value)
		
	SaveManager.write_save({
		"gems": gems,
		"score": score,
		"best_score": max(best_score, score),
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
	# 1. Restore Economy, Score & Level Progress
	gems = int(data.get("gems", 0))
	gems_label.text = str(gems)
	
	score = int(data.get("score", 0))
	best_score = int(data.get("best_score", 0))
	score_label.text = "SCORE: " + str(score)
	_update_score_display()
	
	current_level = int(data.get("current_level", 1))
	level_xp = int(data.get("level_xp", 0))
	xp_to_next_level = int(data.get("xp_to_next_level", 250))
	highest_tile_reached = int(data.get("highest_tile_reached", 16))
	
	curr_lvl_label.text = str(current_level)
	next_lvl_label.text = str(current_level + 1)
	progress_bar.max_value = xp_to_next_level
	progress_bar.value = float(level_xp)
	
	# 2. Restore Board Tiles
	for coord in board_tiles.keys():
		if board_tiles[coord] != null:
			board_tiles[coord].queue_free()
			board_tiles[coord] = null
			
	var saved_board: Dictionary = data.get("board", {})
	for key in saved_board.keys():
		var parts = key.split(",")
		if parts.size() == 2:
			var coord = Vector2i(int(parts[0]), int(parts[1]))
			if board_tiles.has(coord):
				var tile = HexTile.new(int(saved_board[key]), HEX_RADIUS)
				tile.axial_coord = coord
				tile.position = axial_to_pixel(coord)
				add_child(tile)
				board_tiles[coord] = tile
				
	# 3. Restore Candidate Piece
	if candidate_holder:
		candidate_holder.queue_free()
	candidate_tiles.clear()
	
	candidate_holder = Node2D.new()
	candidate_holder.position = dock_center
	add_child(candidate_holder)
	
	var cand_data: Dictionary = data.get("candidate", {})
	var cand_values: Array = cand_data.get("values", [2])
	is_pair = bool(cand_data.get("is_pair", false)) and cand_values.size() >= 2
	pair_dir_index = int(cand_data.get("pair_dir_index", 1))
	
	var tile_a = HexTile.new(int(cand_values[0]), HEX_RADIUS)
	candidate_holder.add_child(tile_a)
	candidate_tiles.append(tile_a)
	
	if is_pair:
		var tile_b = HexTile.new(int(cand_values[1]), HEX_RADIUS)
		candidate_holder.add_child(tile_b)
		candidate_tiles.append(tile_b)
		_update_candidate_pair_positions(false)
		
	_update_powerup_buttons()
	if not _can_place_candidate():
		_set_game_over(true)
	else:
		_set_game_over(false)


func _setup_juice_nodes() -> void:
	# Centered Camera2D for screen shake
	camera = Camera2D.new()
	camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	camera.position = Vector2.ZERO
	camera.offset = Vector2.ZERO
	add_child(camera)
	
	# Rotating curved arrows around the dock ring
	dock_arrows_holder = Node2D.new()
	dock_arrows_holder.position = dock_center
	add_child(dock_arrows_holder)
	
	for side in [0, 1]:
		var base_angle :float = PI * side
		var arc := Line2D.new()
		var pts := PackedVector2Array()
		for i in range(17):
			var a := base_angle + deg_to_rad(-35.0 + (70.0 / 16.0) * i)
			pts.append(Vector2(cos(a), sin(a)) * 75.0)
		arc.points = pts
		arc.width = 5.0
		arc.default_color = Color("#58585e")
		dock_arrows_holder.add_child(arc)
		
		# Arrowhead at the end of each arc
		var end_angle := base_angle + deg_to_rad(35.0)
		var tip := Vector2(cos(end_angle), sin(end_angle)) * 75.0
		var arrow := Polygon2D.new()
		arrow.polygon = PackedVector2Array([
			Vector2(-6, -5), Vector2(6, 0), Vector2(-6, 5)
		])
		arrow.color = Color("#58585e")
		arrow.position = tip
		arrow.rotation = end_angle + PI * 0.5
		dock_arrows_holder.add_child(arrow)


func _shake_screen(intensity: float = 4.0, duration: float = 0.16) -> void:
	if not camera:
		return
	if shake_tween and shake_tween.is_valid():
		shake_tween.kill()
	shake_tween = create_tween()
	var steps := 4
	for i in range(steps):
		var rand_offset := Vector2(randf_range(-intensity, intensity), randf_range(-intensity, intensity))
		shake_tween.tween_property(camera, "offset", rand_offset, duration / float(steps))
	shake_tween.tween_property(camera, "offset", Vector2.ZERO, 0.04)

func _spawn_merge_particles(world_pos: Vector2, tile_color: Color, count: int = 12) -> void:
	for i in range(count):
		var p := Polygon2D.new()
		p.polygon = HexTile._create_hex_points(6.0)
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
		
func _setup_top_header_ui() -> void:
	var center_x := screen_size.x * 0.5
	# 1. Center Split Pill: BEST | SCORE (Matches screenshot layout)
	var score_pill = Panel.new()
	score_pill.position = Vector2(center_x - 112.0, safe_top_y)
	score_pill.size = Vector2(224, 54)
	
	var pill_style = StyleBoxFlat.new()
	pill_style.bg_color = Color("#18181a")
	pill_style.set_corner_radius_all(14)
	score_pill.add_theme_stylebox_override("panel", pill_style)
	add_child(score_pill)
	
	# Center vertical divider
	var divider = ColorRect.new()
	divider.color = Color("#333338")
	divider.position = Vector2(111, 8)
	divider.size = Vector2(2, 38)
	score_pill.add_child(divider)
	
	# Left Column: BEST
	var best_title = Label.new()
	best_title.text = "BEST"
	best_title.position = Vector2(0, 5)
	best_title.size = Vector2(110, 18)
	best_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_title.add_theme_font_size_override("font_size", 12)
	best_title.add_theme_color_override("font_color", Color("#9a9aa2"))
	score_pill.add_child(best_title)
	
	best_score = SaveManager.update_best_score(0)
	best_score_label = Label.new()
	best_score_label.text = str(best_score)
	best_score_label.position = Vector2(0, 22)
	best_score_label.size = Vector2(110, 28)
	best_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_score_label.add_theme_font_size_override("font_size", 20)
	best_score_label.add_theme_color_override("font_color", Color.WHITE)
	score_pill.add_child(best_score_label)
	
	# Right Column: SCORE
	var score_title = Label.new()
	score_title.text = "SCORE"
	score_title.position = Vector2(114, 5)
	score_title.size = Vector2(110, 18)
	score_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_title.add_theme_font_size_override("font_size", 12)
	score_title.add_theme_color_override("font_color", Color("#9a9aa2"))
	score_pill.add_child(score_title)
	
	score_label = Label.new()
	score_label.text = "0"
	score_label.position = Vector2(114, 22)
	score_label.size = Vector2(110, 28)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 20)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	score_pill.add_child(score_label)
	
	# 2. Top-Right Daily Calendar Button (Purple rounded square)
	var cal_btn = _create_icon_square_button(Vector2(398, 56), Color("#7c69ef"), "📅", _on_calendar_pressed)
	cal_btn.position = Vector2(center_x + 128.0, safe_top_y + 2.0)
	add_child(cal_btn)
	
	# Red "1" notification badge on top-right corner of Calendar button
	calendar_badge = Panel.new()
	calendar_badge.position = Vector2(36, -6)
	calendar_badge.size = Vector2(20, 20)
	var badge_style = StyleBoxFlat.new()
	badge_style.bg_color = Color("#eb4d4b")
	badge_style.set_corner_radius_all(10)
	calendar_badge.add_theme_stylebox_override("panel", badge_style)
	cal_btn.add_child(calendar_badge)
	
	var badge_lbl = Label.new()
	badge_lbl.text = "1"
	badge_lbl.size = Vector2(20, 20)
	badge_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge_lbl.add_theme_font_size_override("font_size", 12)
	calendar_badge.add_child(badge_lbl)
	calendar_badge.visible = SaveManager.can_claim_daily_reward()
	
	# 3. Top-Right Settings Gear Button (Purple rounded square)
	var gear_btn = _create_icon_square_button(Vector2(458, 56), Color("#7c69ef"), "⚙", _on_settings_pressed)
	gear_btn.position = Vector2(center_x + 188.0, safe_top_y + 2.0)
	add_child(gear_btn)
	
	_setup_modals()

func _create_icon_square_button(pos: Vector2, bg_color: Color, icon_text: String, callback: Callable) -> Button:
	var btn = Button.new()
	btn.position = pos
	btn.size = Vector2(48, 48)
	btn.text = icon_text
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_color_override("font_color", Color.WHITE)
	
	var style = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(12)
	style.border_width_bottom = 3
	style.border_color = bg_color.darkened(0.3)
	btn.add_theme_stylebox_override("normal", style)
	
	var hover = style.duplicate()
	hover.bg_color = bg_color.lightened(0.1)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	
	btn.pressed.connect(callback)
	return btn
	
func _update_score_display() -> void:
	score_label.text = str(score)
	if score > best_score:
		best_score = SaveManager.update_best_score(score)
	best_score_label.text = str(best_score)
	
	
func _setup_modals() -> void:
	var meta := SaveManager.read_meta()
	SoundFX.is_muted = not bool(meta.get("sound_enabled", true))
	SoundFX.haptics_enabled = bool(meta.get("haptics_enabled", true))
	
	# --- SETTINGS MODAL ---
	settings_overlay = _create_modal_backdrop()
	var s_panel = _create_modal_card(settings_overlay, Vector2(360, 360), "SETTINGS")
	
	sound_toggle_btn = _create_menu_button(
		Vector2(55, 85), Vector2(250, 52),
		"SOUND: ON" if not SoundFX.is_muted else "SOUND: OFF",
		Color("#38a3d1") if not SoundFX.is_muted else Color("#58585e"),
		_on_toggle_sound
	)
	s_panel.add_child(sound_toggle_btn)
	
	haptics_toggle_btn = _create_menu_button(
		Vector2(55, 152), Vector2(250, 52),
		"HAPTICS: ON" if SoundFX.haptics_enabled else "HAPTICS: OFF",
		Color("#38a3d1") if SoundFX.haptics_enabled else Color("#58585e"),
		_on_toggle_haptics
	)
	s_panel.add_child(haptics_toggle_btn)
	
	var home_btn = _create_menu_button(
		Vector2(55, 220), Vector2(250, 52),
		"HOME SCREEN",
		Color("#f5a623"),
		_on_return_home_pressed
	)
	s_panel.add_child(home_btn)
	
	var close_s_btn = _create_menu_button(
		Vector2(105, 288), Vector2(150, 44),
		"RESUME",
		Color("#36b37e"),
		func(): settings_overlay.visible = false
	)
	s_panel.add_child(close_s_btn)
	
	# --- DAILY REWARD MODAL ---
	daily_overlay = _create_modal_backdrop()
	var d_panel = _create_modal_card(daily_overlay, Vector2(360, 310), "DAILY REWARD")
	
	daily_status_label = Label.new()
	daily_status_label.position = Vector2(20, 85)
	daily_status_label.size = Vector2(320, 70)
	daily_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	daily_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	daily_status_label.add_theme_font_size_override("font_size", 18)
	d_panel.add_child(daily_status_label)
	
	claim_daily_btn = _create_menu_button(
		Vector2(65, 170), Vector2(230, 54),
		"CLAIM GEMS",
		Color("#e056fd"),
		_on_claim_daily_pressed
	)
	d_panel.add_child(claim_daily_btn)
	
	var close_d_btn = _create_menu_button(
		Vector2(105, 240), Vector2(150, 44),
		"CLOSE",
		Color("#58585e"),
		func(): daily_overlay.visible = false
	)
	d_panel.add_child(close_d_btn)

func _create_modal_backdrop() -> ColorRect:
	var backdrop = ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.72)
	backdrop.size = screen_size
	backdrop.z_index = 40
	backdrop.visible = false
	add_child(backdrop)
	return backdrop

func _create_modal_card(parent: Control, card_size: Vector2, title_text: String) -> Panel:
	var card = Panel.new()
	card.size = card_size
	card.position = (screen_size - card_size) * 0.5
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color("#28282c")
	style.set_corner_radius_all(20)
	style.border_width_top = 3
	style.border_width_bottom = 3
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_color = Color("#42424a")
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)
	
	var lbl = Label.new()
	lbl.text = title_text
	lbl.position = Vector2(0, 22)
	lbl.size = Vector2(card_size.x, 36)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 24)
	card.add_child(lbl)
	return card

# --- MODAL CALLBACKS ---

func _on_settings_pressed() -> void:
	if is_hammer_mode:
		_on_hammer_pressed() # Cancel targeting cleanly
	settings_overlay.visible = true

func _on_toggle_sound() -> void:
	SoundFX.is_muted = not SoundFX.is_muted
	var on := not SoundFX.is_muted
	sound_toggle_btn.text = "SOUND: ON" if on else "SOUND: OFF"
	
	var meta := SaveManager.read_meta()
	meta["sound_enabled"] = on
	SaveManager.write_meta(meta)

func _on_toggle_haptics() -> void:
	SoundFX.haptics_enabled = not SoundFX.haptics_enabled
	haptics_toggle_btn.text = "HAPTICS: ON" if SoundFX.haptics_enabled else "HAPTICS: OFF"
	if SoundFX.haptics_enabled:
		SoundFX.trigger_haptic(30)
		
	var meta := SaveManager.read_meta()
	meta["haptics_enabled"] = SoundFX.haptics_enabled
	SaveManager.write_meta(meta)

func _on_return_home_pressed() -> void:
	_save_game()
	settings_overlay.visible = false
	var save_exists := SaveManager.has_save()
	play_button.text = "CONTINUE" if save_exists else "PLAY"
	reset_save_button.visible = save_exists
	home_overlay.visible = true

func _on_calendar_pressed() -> void:
	var can_claim := SaveManager.can_claim_daily_reward()
	var streak := int(SaveManager.read_meta().get("streak_day", 0))
	if can_claim:
		var next_reward :int= SaveManager.DAILY_REWARD_GEMS + min(streak, 6) * 15
		daily_status_label.text = "Day %d Login Bonus Ready!\nClaim +%d Gems" % [streak + 1, next_reward]
		claim_daily_btn.disabled = false
	else:
		daily_status_label.text = "Day %d Claimed!\nCome back tomorrow for more Gems." % streak
		claim_daily_btn.disabled = true
	daily_overlay.visible = true

func _on_claim_daily_pressed() -> void:
	var result := SaveManager.claim_daily_reward()
	if result.get("claimed", false):
		var reward := int(result["gems"])
		_add_gems(reward)
		_save_game()
		SoundFX.play_level_up()
		SoundFX.trigger_haptic(40)
		calendar_badge.visible = false
		daily_status_label.text = "Claimed +%d Gems!\nCurrent Streak: Day %d" % [reward, int(result["streak"])]
		claim_daily_btn.disabled = true
