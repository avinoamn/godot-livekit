extends Node3D
## A godot-livekit check client, from the voice spike (#147): joins a LiveKit room, publishes a mic
## (or a test tone) and a made-up 192 x 192 face at 15 fps, and plays and shows everyone else, each
## voice on its own bus (its volume, and its level as the speaking light). Started by run.mjs.
##
## Options (after --): --url, --tokens=<a,b,...> (one room connection each; only the first
## subscribes), --mic=device|tone|off, --tone-hz, --video=1|0, --volume-db (for every voice),
## --log=<file>, --quit-after=<seconds>, --aec=1 (the mic through WebRTC's echo canceller, noise
## suppression and high-pass filter, with the Master bus as the reference; --agc=1 adds auto gain).

const FACE := 192
const FACE_FPS := 15.0
const SPEAKING_DB := -45.0

var _rooms: Array[LiveKitRoom] = []
var _mic_source: LiveKitAudioSource
## Extra connections stand in for more people: a tone each.
var _extra_audio: Array[LiveKitAudioSource] = []
var _faces: Array[LiveKitVideoSource] = []
var _face_image: Image
var _face_clock: float = 0.0
var _tone_phase: float = 0.0
var _tone_clock: float = 0.0
var _capture: AudioEffectCapture
var _voices: Dictionary = {}
var _videos: Dictionary = {}
var _opts: Dictionary = {}
var _log: FileAccess
var _hud: Label
var _second: float = 0.0
var _frame_times: Array[float] = []
var _started_usec: int = 0
## 10 ms of samples at the mix rate: WebRTC takes audio in 10 ms frames.
var _chunk: int = 480
## The loudest mic sample this second, to show the mic hears something.
var _mic_peak: float = 0.0
var _apm: LiveKitAudioProcessingModule
## What the speakers play (the Master bus), the echo canceller's reference.
var _reverse: AudioEffectCapture
## Per voice: how loud they come in while our tone is on and while it's off, [sum, count] of the
## linear peak each, for the echo test: our tone coming back in their voice is echo.
var _echo: Dictionary = {}
## Per second: total and worst single call, in usec, of each part of a frame.
var _timing: Dictionary = {}
var _audio_thread: Thread
var _audio_mutex := Mutex.new()
var _audio_ready := Semaphore.new()
var _audio_queue: Array = []
var _tracks: Array[LiveKitTrack] = []
var _seconds: int = 0


class SpikeVoice:
	var stream: LiveKitAudioStream
	var playback: AudioStreamGeneratorPlayback
	var bus: int
	var speaking: bool = false
	var pushed: int = 0


class Video:
	var stream: LiveKitVideoStream
	var mesh: MeshInstance3D
	var frames: int = 0


func _ready() -> void:
	_started_usec = Time.get_ticks_usec()
	_chunk = int(AudioServer.get_mix_rate()) / 100
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var parts := arg.substr(2).split("=", true, 1)
			_opts[parts[0]] = parts[1] if parts.size() > 1 else "1"
	var events := get_node_or_null("/root/NetworkEvents")
	if events != null:
		events.set("enabled", false)
	if _opt("log", "") != "":
		_log = FileAccess.open(_opt("log", ""), FileAccess.WRITE)
	# --leave-at=S: leave the room at S seconds (and with --rejoin, join it again 2 s later).
	var leave_at := float(_opt("leave-at", "0"))
	if leave_at > 0:
		get_tree().create_timer(leave_at).timeout.connect(_leave)
	var quit_after := float(_opt("quit-after", "0"))
	if quit_after > 0:
		get_tree().create_timer(quit_after).timeout.connect(_quit)
	_build_view()
	_face_image = Image.create(FACE, FACE, false, Image.FORMAT_RGBA8)
	if _opt("mic", "tone") == "device":
		_start_mic()
	var tokens := _opt("tokens", "").split(",", false)
	for i in tokens.size():
		var room := LiveKitRoom.new()
		_rooms.append(room)
		room.connected.connect(_on_connected.bind(room, i))
		room.connection_failed.connect(
			func(error: Variant) -> void: _write(["failed", i, str(error)])
		)
		room.disconnected.connect(func() -> void: _write(["disconnected", i]))
		if i == 0 and _opt("subscribe", "1") == "1":
			room.track_subscribed.connect(_on_track_subscribed)
			room.track_unsubscribed.connect(_on_track_unsubscribed)
			room.participant_connected.connect(
				func(p: LiveKitRemoteParticipant) -> void: _write(["joined", p.get_identity()])
			)
			room.participant_disconnected.connect(_on_participant_disconnected)
		room.connect_to_room(_opt("url", "ws://127.0.0.1:7880"), tokens[i], {})
	print(
		(
			"livekit spike: %d connection(s), devices in %s, out %s"
			% [
				tokens.size(),
				AudioServer.get_input_device_list(),
				AudioServer.get_output_device_list()
			]
		)
	)


func _opt(key: String, fallback: String) -> String:
	return str(_opts.get(key, fallback))


func _build_view() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 6)
	add_child(camera)
	var light := DirectionalLight3D.new()
	add_child(light)
	_hud = Label.new()
	_hud.position = Vector2(12, 12)
	var layer := CanvasLayer.new()
	layer.add_child(_hud)
	add_child(layer)


## The mic through Godot's audio input: a microphone stream on a muted bus, read back with an
## AudioEffectCapture.
func _start_mic() -> void:
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Mic")
	AudioServer.set_bus_mute(bus, true)
	_capture = AudioEffectCapture.new()
	AudioServer.add_bus_effect(bus, _capture)
	var player := AudioStreamPlayer.new()
	player.stream = AudioStreamMicrophone.new()
	player.bus = "Mic"
	add_child(player)
	player.play()
	if _opt("aec", "0") == "1":
		_apm = (
			LiveKitAudioProcessingModule
			. create(
				{
					"echo_cancellation": true,
					"noise_suppression": true,
					"high_pass_filter": true,
					"auto_gain_control": _opt("agc", "0") == "1",
				}
			)
		)
		_reverse = AudioEffectCapture.new()
		AudioServer.add_bus_effect(0, _reverse)


func _on_connected(room: LiveKitRoom, index: int) -> void:
	_write(["connected", index, room.get_local_participant().get_identity()])
	var local := room.get_local_participant()
	if _opt("mic", "tone") != "off":
		var source := LiveKitAudioSource.create(
			int(AudioServer.get_mix_rate()), 1, int(_opt("queue-ms", "0"))
		)
		if index == 0:
			_mic_source = source
		var track := LiveKitLocalAudioTrack.create("mic", source)
		local.publish_track(track, {"dtx": true, "source": LiveKitTrack.SOURCE_MICROPHONE})
		if index > 0:
			_extra_audio.append(source)
	if _opt("video", "1") == "1":
		var face := LiveKitVideoSource.create(FACE, FACE)
		_faces.append(face)
		var track := LiveKitLocalVideoTrack.create("face", face)
		local.publish_track(track, {"source": LiveKitTrack.SOURCE_CAMERA})


func _on_track_subscribed(
	track: LiveKitTrack,
	publication: LiveKitRemoteTrackPublication,
	participant: LiveKitRemoteParticipant
) -> void:
	var who := participant.get_identity()
	_write(["subscribed", who, track.get_kind(), track.get_name(), publication.get_mime_type()])
	_tracks.append(track)
	track.stats_received.connect(
		func(stats: Variant) -> void:
			_write(["stats", who, track.get_name(), JSON.stringify(stats)])
	)
	if track.get_kind() == LiveKitTrack.KIND_AUDIO:
		var voice := SpikeVoice.new()
		voice.stream = LiveKitAudioStream.from_track(track)
		voice.bus = AudioServer.bus_count
		AudioServer.add_bus(voice.bus)
		AudioServer.set_bus_name(voice.bus, "Voice " + who)
		AudioServer.set_bus_volume_db(voice.bus, float(_opt("volume-db", "0")))
		var generator := AudioStreamGenerator.new()
		generator.mix_rate = AudioServer.get_mix_rate()
		generator.buffer_length = 0.2
		var player := AudioStreamPlayer.new()
		player.stream = generator
		player.bus = AudioServer.get_bus_name(voice.bus)
		add_child(player)
		player.play()
		voice.playback = player.get_stream_playback()
		_voices[who] = voice
	elif track.get_kind() == LiveKitTrack.KIND_VIDEO:
		var video := Video.new()
		video.stream = LiveKitVideoStream.from_track(track)
		video.stream.frame_received.connect(func() -> void: video.frames += 1)
		video.mesh = MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(1.2, 1.2)
		video.mesh.mesh = quad
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		video.mesh.material_override = material
		video.mesh.position = Vector3(
			-3 + 1.4 * (_videos.size() % 5), 1 - 1.4 * (_videos.size() / 5), 0
		)
		add_child(video.mesh)
		_videos[who] = video


func _on_track_unsubscribed(
	track: LiveKitTrack,
	_publication: LiveKitRemoteTrackPublication,
	participant: LiveKitRemoteParticipant
) -> void:
	_write(["unsubscribed", participant.get_identity(), track.get_kind()])


## Logs who left, then again a second later, after the SDK has freed the participant: the wrapper
## should still give the identity it was bound with.
func _on_participant_disconnected(participant: LiveKitRemoteParticipant) -> void:
	_write(["gone", participant.get_identity()])
	await get_tree().create_timer(1.0).timeout
	_write(["identity later", participant.get_identity()])


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_push_audio(delta)
	var faces_started := Time.get_ticks_usec()
	_push_faces(delta)
	_time("faces", faces_started)
	for who: String in _voices:
		var voice: SpikeVoice = _voices[who]
		var poll_started := Time.get_ticks_usec()
		voice.pushed += voice.stream.poll(voice.playback)
		_time("poll", poll_started)
		var level := AudioServer.get_bus_peak_volume_left_db(voice.bus, 0)
		_note_echo(who, level)
		var speaking := level > SPEAKING_DB
		if speaking != voice.speaking:
			voice.speaking = speaking
			_write(
				[
					"speaking",
					who,
					int(speaking),
					"%.1f" % level,
					"%.1f" % AudioServer.get_bus_peak_volume_left_db(0, 0)
				]
			)
	for who: String in _videos:
		var video: Video = _videos[who]
		var texture := video.stream.get_texture()
		if texture != null:
			(video.mesh.material_override as StandardMaterial3D).albedo_texture = texture
	_frame_times.append(delta)
	_second += delta
	if _second >= 1.0:
		_second -= 1.0
		_report(Time.get_ticks_usec() - started)
		_seconds += 1
		if _seconds % 5 == 0:
			for track in _tracks:
				track.request_stats()
			_echo_report()


## Our tone is on for the first second of every two (by the wall clock). Their voice is sampled
## late in each half, after the round trip and playout, so it's our tone coming back or not.
func _note_echo(who: String, level_db: float) -> void:
	if _opt("mic", "tone") != "tone":
		return
	var phase := fmod(Time.get_ticks_msec() / 1000.0, 2.0)
	var half := ""
	if phase >= 0.5 and phase < 1.0:
		half = "on"
	elif phase >= 1.5:
		half = "off"
	if half.is_empty():
		return
	var entry: Dictionary = _echo.get(who, {"on": [0.0, 0], "off": [0.0, 0]})
	var sums: Array = entry[half]
	sums[0] = float(sums[0]) + db_to_linear(level_db)
	sums[1] = int(sums[1]) + 1
	_echo[who] = entry


func _echo_report() -> void:
	for who: String in _echo:
		var entry: Dictionary = _echo[who]
		var on: Array = entry["on"]
		var off: Array = entry["off"]
		if int(on[1]) > 0 and int(off[1]) > 0:
			var on_db := linear_to_db(float(on[0]) / int(on[1]))
			var off_db := linear_to_db(float(off[0]) / int(off[1]))
			_write(["echo", who, "%.1f" % on_db, "%.1f" % off_db, "%.1f" % (on_db - off_db)])
	_echo.clear()  # each line covers the last 5 s only


## The mic's samples (or a tone, 1 s on and 1 s off, like speech and silence) in 10 ms chunks.
func _push_audio(delta: float) -> void:
	if _capture != null and _mic_source != null:
		while _capture.get_frames_available() >= _chunk:
			var stereo := _capture.get_buffer(_chunk)
			var mono := PackedFloat32Array()
			mono.resize(_chunk)
			for i in _chunk:
				mono[i] = (stereo[i].x + stereo[i].y) * 0.5
				_mic_peak = maxf(_mic_peak, absf(mono[i]))
			if _apm != null:
				# The reference first: what has gone to the speakers up to now.
				var rate := int(AudioServer.get_mix_rate())
				while _reverse.get_frames_available() >= _chunk:
					var played := _reverse.get_buffer(_chunk)
					var reference := PackedFloat32Array()
					reference.resize(_chunk)
					for i in _chunk:
						reference[i] = (played[i].x + played[i].y) * 0.5
					_apm.process_reverse_stream(reference, rate, 1)
				mono = _apm.process_stream(mono, rate, 1)
			_send_audio(_mic_source, mono)
		return
	if _opt("mic", "tone") != "tone" or (_mic_source == null and _extra_audio.is_empty()):
		return
	_tone_clock += delta
	var rate := AudioServer.get_mix_rate()
	var hz := float(_opt("tone-hz", "440"))
	while _tone_clock >= _chunk / rate:
		_tone_clock -= _chunk / rate
		var on := fmod(Time.get_ticks_msec() / 1000.0, 2.0) < 1.0
		var chunk := PackedFloat32Array()
		chunk.resize(_chunk)
		for i in _chunk:
			chunk[i] = 0.3 * sin(_tone_phase) if on else 0.0
			_tone_phase += TAU * hz / rate
		for source: LiveKitAudioSource in (
			([_mic_source] if _mic_source != null else []) + _extra_audio
		):
			_send_audio(source, chunk)


## capture_frame blocks while the SDK waits on its core (up to 20 ms a call), so with --thread it's
## called from a worker thread and the frame only queues the chunk.
func _send_audio(source: LiveKitAudioSource, chunk: PackedFloat32Array) -> void:
	var started := Time.get_ticks_usec()
	if _opt("thread", "0") == "1":
		if _audio_thread == null:
			_audio_thread = Thread.new()
			_audio_thread.start(_audio_worker)
		_audio_mutex.lock()
		_audio_queue.append([source, chunk])
		_audio_mutex.unlock()
		_audio_ready.post()
	else:
		source.capture_frame(chunk, int(AudioServer.get_mix_rate()), 1, _chunk)
	_time("audio", started)


func _audio_worker() -> void:
	var rate := int(AudioServer.get_mix_rate())
	while true:
		_audio_ready.wait()
		_audio_mutex.lock()
		var item: Array = [] if _audio_queue.is_empty() else _audio_queue.pop_front()
		_audio_mutex.unlock()
		if item.is_empty():
			return
		(item[0] as LiveKitAudioSource).capture_frame(item[1], rate, 1, _chunk)


## A made-up face: a moving gradient with a bright square, so frames differ like a webcam's.
func _push_faces(delta: float) -> void:
	if _faces.is_empty():
		return
	_face_clock += delta
	if _face_clock < 1.0 / FACE_FPS:
		return
	_face_clock = fmod(_face_clock, 1.0 / FACE_FPS)
	var t := Time.get_ticks_msec() / 1000.0
	_face_image.fill(Color.from_hsv(fmod(t * 0.1, 1.0), 0.5, 0.8))
	var x := int((sin(t * 2.0) * 0.5 + 0.5) * (FACE - 48))
	_face_image.fill_rect(Rect2i(x, 72, 48, 48), Color.WHITE)
	for face in _faces:
		face.capture_frame(_face_image, Time.get_ticks_usec(), 0)


func _time(part: String, started: int) -> void:
	var spent := Time.get_ticks_usec() - started
	var entry: Array = _timing.get(part, [0, 0])
	_timing[part] = [int(entry[0]) + spent, maxi(int(entry[1]), spent)]


func _report(work_usec: int) -> void:
	if _capture != null:
		_write(["mic", "%.1f" % linear_to_db(_mic_peak)])
		_mic_peak = 0.0
	var frames := _frame_times.size()
	var worst := 0.0
	for t in _frame_times:
		worst = maxf(worst, t)
	_frame_times.clear()
	var timing := _timing.duplicate()
	_timing.clear()
	var video_frames := PackedStringArray()
	for who: String in _videos:
		var video: Video = _videos[who]
		video_frames.append("%s:%d" % [who, video.frames])
		video.frames = 0
	var audio := PackedStringArray()
	for who: String in _voices:
		var voice: SpikeVoice = _voices[who]
		audio.append("%s:%d" % [who, voice.pushed])
		voice.pushed = 0
	_write(
		[
			"second",
			frames,
			"%.1f" % (worst * 1000.0),
			_timing_text(timing),
			work_usec,
			" ".join(video_frames),
			" ".join(audio),
		]
	)
	if _hud != null:
		_hud.text = (
			"%d fps   voices %s   faces %s" % [frames, " ".join(audio), " ".join(video_frames)]
		)


static func _timing_text(timing: Dictionary) -> String:
	var parts := PackedStringArray()
	for part: String in timing:
		parts.append("%s:%d/%d" % [part, timing[part][0], timing[part][1]])
	return " ".join(parts)


func _write(fields: Array) -> void:
	var line := ",".join(PackedStringArray(fields.map(func(f: Variant) -> String: return str(f))))
	var seconds := (Time.get_ticks_usec() - _started_usec) / 1e6
	line = "%.2f,%s" % [seconds, line]
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


func _leave() -> void:
	_write(["leaving"])
	# Stop sending and receiving first: nothing may touch a source or stream of a room that's gone.
	_mic_source = null
	_extra_audio.clear()
	_faces.clear()
	for who: String in _voices:
		(_voices[who] as SpikeVoice).stream.close()
	for who: String in _videos:
		var video: Video = _videos[who]
		video.stream.close()
		video.mesh.queue_free()
	_voices.clear()
	_videos.clear()
	_tracks.clear()
	await get_tree().process_frame
	_rooms[0].disconnect_from_room()
	_write(["left"])
	if _opt("rejoin", "0") == "1":
		await get_tree().create_timer(2.0).timeout
		_write(["rejoining"])
		_rooms[0].connect_to_room(
			_opt("url", "ws://127.0.0.1:7880"), _opt("tokens", "").split(",")[0], {}
		)


func _quit() -> void:
	var dir := _opt("log", "").get_base_dir()
	if _log != null:
		for who: String in _videos:
			var texture := (_videos[who] as Video).stream.get_texture()
			var image := texture.get_image() if texture != null else null
			if image != null:
				image.save_png(dir.path_join("face-%s.png" % who))
		if DisplayServer.get_name() != "headless":
			get_viewport().get_texture().get_image().save_png(dir.path_join("screen.png"))
	if _audio_thread != null:
		_audio_mutex.lock()
		_audio_queue.clear()
		_audio_mutex.unlock()
		_audio_ready.post()
		_audio_thread.wait_to_finish()
	# --shutdown: "disconnect" (then quit at once), "wait" (disconnect, close the streams, wait 1 s)
	# or "none" (just quit).
	var shutdown := _opt("shutdown", "disconnect")
	if shutdown == "wait":
		for who: String in _voices:
			(_voices[who] as SpikeVoice).stream.close()
		for who: String in _videos:
			(_videos[who] as Video).stream.close()
	if shutdown != "none":
		for room in _rooms:
			room.disconnect_from_room()
	if shutdown == "wait":
		await get_tree().create_timer(1.0).timeout
		_voices.clear()
		_videos.clear()
		_rooms.clear()
		_mic_source = null
		_extra_audio.clear()
		_faces.clear()
		await get_tree().create_timer(0.5).timeout
	get_tree().quit()
