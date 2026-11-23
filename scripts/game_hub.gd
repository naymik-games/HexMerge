extends Node

# Autoload "GameHub": the list of games in the app and the routing between them.
#
# To add a game: give it a scene, add one entry to GAMES, and have the game
#   - use its own id with SaveManager (read_save / write_save / delete_save / best score)
#   - call GameHub.go_home() from its "HOME SCREEN" button (save first: leaving frees the scene)
# The home screen builds its cards from this list, so it needs no changes.

const HOME_SCENE: String = "res://scenes/home_screen.tscn"

const GAMES: Array[Dictionary] = [
	{
		"id": "hex2048",                   # also the SaveManager slot; "hex2048" keeps the original save file
		"title": "HEX 2048",
		"tagline": "Drop pieces and merge 3 or more to double them.",
		"scene": "res://scenes/main.tscn",        # your existing game scene
		"accent": Color("#38a3d1"),
		"icon_text": "2048",
	},
	{
		"id": "hextrail",
		"title": "HEX TRAIL",
		"tagline": "Draw a trail to place tiles. Match 3 to count up.",
		"scene": "res://scenes/trail_main.tscn",
		"accent": Color("#36b37e"),
		"icon_text": "123",
	},
	{
		"id": "hexladder",
		"title": "HEX LADDER",
		"tagline": "Build runs like 1-2-3. Touching steps merge into the next number.",
		"scene": "res://scenes/ladder_main.tscn",
		"accent": Color("#f5a623"),
		"icon_text": "+1",
	},
]

var current_game_id: String = ""


func launch(game_id: String) -> void:
	for game in GAMES:
		if game["id"] != game_id:
			continue
		var scene_path: String = game["scene"]
		if not ResourceLoader.exists(scene_path):
			push_error("GameHub: scene not found for '%s': %s" % [game_id, scene_path])
			return
		current_game_id = game_id
		get_tree().change_scene_to_file(scene_path)
		return
	push_error("GameHub: unknown game id '%s'" % game_id)


func go_home() -> void:
	current_game_id = ""
	get_tree().change_scene_to_file(HOME_SCENE)
