extends Node

const SAVE_PATH: String = "user://hexmerge-savegame.json"
const META_PATH: String = "user://hexmerge-meta.json"
const DAILY_REWARD_GEMS: int = 50


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(SAVE_PATH)

func write_save(data: Dictionary) -> void:
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()

func read_save() -> Dictionary:
	if not has_save():
		return {}
		
	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
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

func update_best_score(new_score: int) -> int:
	var meta := read_meta()
	var current_best := int(meta.get("best_score", 0))
	if new_score > current_best:
		meta["best_score"] = new_score
		write_meta(meta)
		return new_score
	return current_best

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
