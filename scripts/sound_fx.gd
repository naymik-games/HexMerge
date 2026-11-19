extends Node

const SAMPLE_RATE: int = 22050
var is_muted: bool = false
var haptics_enabled: bool = true

func play_tone(freq_start: float, freq_end: float, duration: float, volume_db: float = -8.0, wave_type: String = "sine") -> void:
	if is_muted:
		return
		
	var num_samples := int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2) # 16-bit mono
	
	var phase: float = 0.0
	for i in range(num_samples):
		var t := float(i) / float(num_samples)
		var freq := lerpf(freq_start, freq_end, t)
		phase += (TAU * freq) / float(SAMPLE_RATE)
		
		# Smooth attack & exponential decay envelope
		var envelope := sin(minf(t * 15.0, 1.0) * PI * 0.5) * pow(1.0 - t, 1.8)
		
		var sample_val: float = 0.0
		match wave_type:
			"sine":
				sample_val = sin(phase)
			"triangle":
				sample_val = asin(sin(phase)) * (2.0 / PI)
			"noise":
				sample_val = randf_range(-1.0, 1.0)
				
		var pcm := int(clampf(sample_val * envelope * 32767.0, -32768.0, 32767.0))
		data.encode_s16(i * 2, pcm)
		
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.data = data
	
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

# --- GAME SOUND PRESETS ---

func play_rotate() -> void:
	play_tone(420.0, 580.0, 0.06, -12.0, "triangle")

func play_place() -> void:
	play_tone(220.0, 140.0, 0.08, -10.0, "sine")

func play_merge(combo: int = 1) -> void:
	# Escalate musical pitch with every step in a chain reaction
	var pitch_mult := pow(1.12, combo - 1)
	play_tone(330.0 * pitch_mult, 660.0 * pitch_mult, 0.18, -7.0, "triangle")

func play_smash() -> void:
	play_tone(180.0, 55.0, 0.22, -6.0, "noise")

func play_level_up() -> void:
	play_tone(523.25, 1046.5, 0.35, -6.0, "triangle")

func trigger_haptic(duration_ms: int = 25) -> void:
	if haptics_enabled:
		Input.vibrate_handheld(duration_ms)
