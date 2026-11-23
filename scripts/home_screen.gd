extends Control

# =============================================================================
# HOME SCREEN
#
# Shows one card per entry in GameHub.GAMES: icon, title, tagline, best score, and
#   - PLAY                  when the game has no saved run
#   - CONTINUE + NEW        when it does (NEW asks for a second tap, then deletes that
#                           game's save and starts fresh)
# Also carries the app-wide extras: gem balance, daily reward, sound / haptics.
# Games auto-resume their own save when launched, so no per-game title screen is needed.
# =============================================================================

const BG_COLOR: Color = Color("#1e1e22")
const APP_TITLE: String = "HEX GAMES"
const UI_MARGIN: float = 16.0
const CARD_HEIGHT: float = 132.0
const CARD_GAP: int = 14
const NEW_CONFIRM_SECONDS: float = 2.0

var screen_size: Vector2 = Vector2(540, 960)
var safe_top_y: float = 40.0
var safe_bottom_y: float = 940.0

var gems: int = 0
var gems_label: Label
var calendar_badge: Panel
var settings_overlay: ColorRect
var daily_overlay: ColorRect
var sound_toggle_btn: Button
var haptics_toggle_btn: Button
var claim_daily_btn: Button
var daily_status_label: Label


func _ready() -> void:
	RenderingServer.set_default_clear_color(BG_COLOR)
	_compute_responsive_layout()
	_load_meta()
	_build_background()
	_build_header()
	_build_game_list()
	_build_modals()


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


func _load_meta() -> void:
	var meta: Dictionary = SaveManager.read_meta()
	gems = int(meta.get("gems", 0))
	SoundFX.is_muted = not bool(meta.get("sound_enabled", true))
	SoundFX.haptics_enabled = bool(meta.get("haptics_enabled", true))


func _write_meta_value(key: String, value: Variant) -> void:
	var meta: Dictionary = SaveManager.read_meta()
	meta[key] = value
	SaveManager.write_meta(meta)


# =============================================================================
# LAYOUT
# =============================================================================

func _build_background() -> void:
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.size = screen_size
	add_child(bg)


func _build_header() -> void:
	# Gem balance (shared by every game)
	var pill := _make_panel(Vector2(UI_MARGIN, safe_top_y + 8.0), Vector2(120, 38), Color("#18181a"), 19)
	add_child(pill)

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

	# Top-right buttons, anchored to the screen edge
	var gear_btn := _create_icon_square_button(Color("#7c69ef"), "⚙", _on_settings_pressed)
	gear_btn.position = Vector2(screen_size.x - UI_MARGIN - 48.0, safe_top_y + 2.0)
	add_child(gear_btn)

	var cal_btn := _create_icon_square_button(Color("#7c69ef"), "📅", _on_calendar_pressed)
	cal_btn.position = Vector2(gear_btn.position.x - 10.0 - 48.0, safe_top_y + 2.0)
	add_child(cal_btn)

	calendar_badge = _make_panel(Vector2(36, -6), Vector2(20, 20), Color("#eb4d4b"), 10)
	cal_btn.add_child(calendar_badge)
	calendar_badge.add_child(_make_label("1", Vector2.ZERO, Vector2(20, 20), 12, Color.WHITE,
			HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER))
	calendar_badge.visible = SaveManager.can_claim_daily_reward()

	add_child(_make_label(APP_TITLE, Vector2(0, safe_top_y + 72.0), Vector2(screen_size.x, 60), 44))


func _build_game_list() -> void:
	var top := safe_top_y + 150.0
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(UI_MARGIN, top)
	scroll.size = Vector2(screen_size.x - UI_MARGIN * 2.0, safe_bottom_y - top)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var list := VBoxContainer.new()
	list.custom_minimum_size = Vector2(scroll.size.x, 0.0)
	list.add_theme_constant_override("separation", CARD_GAP)
	scroll.add_child(list)

	for game in GameHub.GAMES:
		list.add_child(_build_game_card(game, scroll.size.x))


func _build_game_card(game: Dictionary, width: float) -> Panel:
	var game_id: String = game["id"]
	var accent: Color = game["accent"]

	var card := _make_panel(Vector2.ZERO, Vector2(width, CARD_HEIGHT), Color("#28282c"), 20)
	card.custom_minimum_size = Vector2(width, CARD_HEIGHT)
	var style: StyleBoxFlat = card.get_theme_stylebox("panel")
	style.set_border_width_all(3)
	style.border_color = Color("#42424a")

	_add_hex_icon(card, Vector2(66.0, CARD_HEIGHT * 0.5), 40.0, accent, str(game["icon_text"]))

	var text_width := width - 122.0 - 150.0
	card.add_child(_make_label(str(game["title"]), Vector2(122, 14), Vector2(text_width, 32), 24,
			Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT))

	card.add_child(_make_label(str(game["tagline"]), Vector2(122, 46), Vector2(text_width, 52), 14,
			Color("#9a9aa2"), HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP, true))

	card.add_child(_make_label("BEST  %d" % SaveManager.get_best_score(game_id), Vector2(122, 102),
			Vector2(text_width, 22), 14, Color("#f9ca24"), HORIZONTAL_ALIGNMENT_LEFT))

	var btn_x := width - 146.0
	if SaveManager.has_save(game_id):
		card.add_child(_create_menu_button(Vector2(btn_x, 16), Vector2(130, 52), "CONTINUE",
				Color("#36b37e"), _on_launch_pressed.bind(game_id), 18))
		var new_btn := _create_menu_button(Vector2(btn_x, 76), Vector2(130, 40), "NEW",
				Color("#f5a623"), Callable(), 16)
		new_btn.pressed.connect(_on_new_pressed.bind(new_btn, game_id))
		card.add_child(new_btn)
	else:
		card.add_child(_create_menu_button(Vector2(btn_x, 36), Vector2(130, 60), "PLAY",
				Color("#36b37e"), _on_launch_pressed.bind(game_id), 24))
	return card


# Same look as the in-game tiles: rounded hex with a raised base and a top-to-bottom gradient
func _add_hex_icon(parent: Control, center: Vector2, radius: float, color: Color, text_str: String) -> void:
	var r := radius - 2.0
	var pts := HexTile.create_rounded_hex_points(r)

	var depth := Polygon2D.new()
	depth.polygon = pts
	depth.color = color.darkened(0.4)
	depth.position = center + Vector2(0, 4)
	parent.add_child(depth)

	var face := Polygon2D.new()
	face.polygon = pts
	face.color = color
	var top := color.lightened(0.14)
	var bottom := color.darkened(0.12)
	var cols := PackedColorArray()
	for p in pts:
		cols.append(top.lerp(bottom, clampf((p.y + r) / (2.0 * r), 0.0, 1.0)))
	face.vertex_colors = cols
	face.position = center
	parent.add_child(face)

	var font_size: int = maxi(28 - maxi(text_str.length() - 2, 0) * 4, 12)
	var lbl := _make_label(text_str, center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0),
			font_size, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	lbl.add_theme_font_override("font", HexTile.get_bold_font())
	lbl.add_theme_constant_override("outline_size", 5)
	lbl.add_theme_color_override("font_outline_color", color.darkened(0.55))
	parent.add_child(lbl)


func _build_modals() -> void:
	# --- SETTINGS MODAL ---
	settings_overlay = _create_modal_backdrop()
	var s_panel := _create_modal_card(settings_overlay, Vector2(360, 290), "SETTINGS")

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
		Vector2(105, 222), Vector2(150, 44), "CLOSE", Color("#36b37e"),
		func() -> void: settings_overlay.visible = false))

	# --- DAILY REWARD MODAL ---
	daily_overlay = _create_modal_backdrop()
	var d_panel := _create_modal_card(daily_overlay, Vector2(360, 310), "DAILY REWARD")

	daily_status_label = _make_label("", Vector2(20, 85), Vector2(320, 70), 18, Color.WHITE,
			HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_TOP, true)
	d_panel.add_child(daily_status_label)

	claim_daily_btn = _create_menu_button(
		Vector2(65, 170), Vector2(230, 54), "CLAIM GEMS", Color("#e056fd"), _on_claim_daily_pressed)
	d_panel.add_child(claim_daily_btn)

	d_panel.add_child(_create_menu_button(
		Vector2(105, 240), Vector2(150, 44), "CLOSE", Color("#58585e"),
		func() -> void: daily_overlay.visible = false))


# =============================================================================
# CALLBACKS
# =============================================================================

func _on_launch_pressed(game_id: String) -> void:
	SoundFX.trigger_haptic(15)
	GameHub.launch(game_id)


# First tap arms the button ("SURE?"), a second tap within a couple of seconds wipes that
# game's save and starts fresh. Only the chosen game's save is touched.
func _on_new_pressed(btn: Button, game_id: String) -> void:
	var armed: bool = btn.get_meta("armed", false)
	if armed:
		SaveManager.delete_save(game_id)
		GameHub.launch(game_id)
		return

	btn.set_meta("armed", true)
	btn.text = "SURE?"
	_apply_button_style(btn, Color("#eb4d4b"), 16, 5)
	get_tree().create_timer(NEW_CONFIRM_SECONDS).timeout.connect(func() -> void:
		if is_instance_valid(btn):
			btn.set_meta("armed", false)
			btn.text = "NEW"
			_apply_button_style(btn, Color("#f5a623"), 16, 5)
	)


func _on_settings_pressed() -> void:
	settings_overlay.visible = true


func _on_toggle_sound() -> void:
	SoundFX.is_muted = not SoundFX.is_muted
	var on := not SoundFX.is_muted
	sound_toggle_btn.text = "SOUND: ON" if on else "SOUND: OFF"
	_apply_button_style(sound_toggle_btn, Color("#38a3d1") if on else Color("#58585e"), 16, 5)
	_write_meta_value("sound_enabled", on)


func _on_toggle_haptics() -> void:
	SoundFX.haptics_enabled = not SoundFX.haptics_enabled
	var on := SoundFX.haptics_enabled
	haptics_toggle_btn.text = "HAPTICS: ON" if on else "HAPTICS: OFF"
	_apply_button_style(haptics_toggle_btn, Color("#38a3d1") if on else Color("#58585e"), 16, 5)
	if on:
		SoundFX.trigger_haptic(30)
	_write_meta_value("haptics_enabled", on)


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
	if not result.get("claimed", false):
		return
	var reward := int(result["gems"])

	# claim_daily_reward already wrote its own meta keys; add the gems on top of the current balance
	var meta: Dictionary = SaveManager.read_meta()
	gems = int(meta.get("gems", 0)) + reward
	meta["gems"] = gems
	SaveManager.write_meta(meta)

	gems_label.text = str(gems)
	SoundFX.play_level_up()
	SoundFX.trigger_haptic(40)
	calendar_badge.visible = false
	daily_status_label.text = "Claimed +%d Gems!\nCurrent Streak: Day %d" % [reward, int(result["streak"])]
	claim_daily_btn.disabled = true


# =============================================================================
# UI BUILDERS (same look as the games)
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
		v_align: VerticalAlignment = VERTICAL_ALIGNMENT_TOP,
		wrap: bool = false) -> Label:
	var lbl := Label.new()
	# Wrapping must be on before the text and size are set: a label that is not in the tree yet
	# caches its minimum size, and without wrapping that is the full single-line text width.
	if wrap:
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.text = text_str
	lbl.position = pos
	lbl.size = label_size
	lbl.horizontal_alignment = h_align
	lbl.vertical_alignment = v_align
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl


# Raised, rounded button look; also used to recolor a button (toggle state, "SURE?")
func _apply_button_style(btn: Button, bg_color: Color, corner: int, border: int) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(corner)
	style.border_width_bottom = border
	style.border_color = bg_color.darkened(0.35)
	btn.add_theme_stylebox_override("normal", style)

	var hover: StyleBoxFlat = style.duplicate()
	hover.bg_color = bg_color.lightened(0.1)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)


func _create_menu_button(pos: Vector2, btn_size: Vector2, text_str: String, bg_color: Color,
		callback: Callable, font_size: int = 22) -> Button:
	var btn := Button.new()
	btn.position = pos
	btn.size = btn_size
	btn.text = text_str
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", Color.WHITE)
	_apply_button_style(btn, bg_color, 16, 5)
	if callback.is_valid():
		btn.pressed.connect(callback)
	return btn


func _create_icon_square_button(bg_color: Color, icon_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.size = Vector2(48, 48)
	btn.text = icon_text
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_color_override("font_color", Color.WHITE)
	_apply_button_style(btn, bg_color, 12, 3)
	btn.pressed.connect(callback)
	return btn


func _create_modal_backdrop() -> ColorRect:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.72)
	backdrop.size = screen_size
	backdrop.z_index = 40
	backdrop.visible = false
	add_child(backdrop)
	return backdrop


func _create_modal_card(parent: Control, card_size: Vector2, title_text: String) -> Panel:
	var card := _make_panel((screen_size - card_size) * 0.5, card_size, Color("#28282c"), 20)
	var style: StyleBoxFlat = card.get_theme_stylebox("panel")
	style.set_border_width_all(3)
	style.border_color = Color("#42424a")
	parent.add_child(card)

	card.add_child(_make_label(title_text, Vector2(0, 22), Vector2(card_size.x, 36), 24))
	return card
