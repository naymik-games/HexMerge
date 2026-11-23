extends Node

# Run saves and best scores are per game: each game passes its own id (see GameHub.GAMES).
# Calls made without an id act on the first game ("hex2048"), which keeps its original save
# file and "best_score" key, so existing saves survive and the original game's code is unchanged.
# Gems, sound / haptics settings and the daily reward are app-wide and live in the shared meta file.

const DEFAULT_GAME: String = "hex2048"
const SAVE_PATH: String = "user://hexmerge-savegame.json"   # hex2048's save file (name kept on purpose)
const META_PATH: String = "user://hexmerge-meta.json"
const DAILY_REWARD_GEMS: int = 50


# hex2048 keeps its legacy file name; every other game gets user://<game_id>-save.json
func _save_path(game_id: String) -> String:
	if game_id == DEFAULT_GAME:
		return SAVE_PATH
	return "user://%s-save.json" % game_id


func has_save(game_id: String = DEFAULT_GAME) -> bool:
	return FileAccess.file_exists(_save_path(game_id))

func delete_save(game_id: String = DEFAULT_GAME) -> void:
	if has_save(game_id):
		DirAccess.remove_absolute(_save_path(game_id))

func write_save(data: Dictionary, game_id: String = DEFAULT_GAME) -> void:
	var file = FileAccess.open(_save_path(game_id), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()

func read_save(game_id: String = DEFAULT_GAME) -> Dictionary:
	if not has_save(game_id):
		return {}

	var file = FileAccess.open(_save_path(game_id), FileAccess.READ)
	if not file:
		return {}

	var json_text = file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(json_text)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}




func read_meta() -> Dictionary:
	if not FileAccess.file_exists(META_PATH):
		return {
			"best_score": 0,
			"sound_enabled": true,
			"haptics_enabled": true,
			"last_claim_date": "",
			"streak_day": 0
		}
	var file = FileAccess.open(META_PATH, FileAccess.READ)
	if not file:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func write_meta(meta: Dictionary) -> void:
	var file = FileAccess.open(META_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(meta))
		file.close()


# --- BEST SCORES ---
# hex2048 uses the original top-level "best_score" key; other games live under "best_scores".

func _best_from_meta(meta: Dictionary, game_id: String) -> int:
	if game_id == DEFAULT_GAME:
		return int(meta.get("best_score", 0))
	var scores: Dictionary = meta.get("best_scores", {})
	return int(scores.get(game_id, 0))

func get_best_score(game_id: String = DEFAULT_GAME) -> int:
	return _best_from_meta(read_meta(), game_id)

func update_best_score(new_score: int, game_id: String = DEFAULT_GAME) -> int:
	var meta := read_meta()
	var current_best := _best_from_meta(meta, game_id)
	if new_score <= current_best:
		return current_best

	if game_id == DEFAULT_GAME:
		meta["best_score"] = new_score
	else:
		var scores: Dictionary = meta.get("best_scores", {})
		scores[game_id] = new_score
		meta["best_scores"] = scores
	write_meta(meta)
	return new_score


# --- DAILY REWARD (shared by every game) ---

func _get_today_string() -> String:
	var d := Time.get_date_dict_from_system()
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]

func can_claim_daily_reward() -> bool:
	var meta := read_meta()
	return str(meta.get("last_claim_date", "")) != _get_today_string()

func claim_daily_reward() -> Dictionary:
	var meta := read_meta()
	var today := _get_today_string()
	if str(meta.get("last_claim_date", "")) == today:
		return {"claimed": false, "gems": 0, "streak": int(meta.get("streak_day", 1))}
		
	var streak := int(meta.get("streak_day", 0)) + 1
	var reward : int = DAILY_REWARD_GEMS + min(streak - 1, 6) * 15 # Scales up to +140 gems/day
	
	meta["last_claim_date"] = today
	meta["streak_day"] = streak
	write_meta(meta)
	
	return {"claimed": true, "gems": reward, "streak": streak}
