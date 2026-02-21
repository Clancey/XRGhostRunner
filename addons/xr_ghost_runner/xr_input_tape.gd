extends Node

signal recording_saved(path: String, event_count: int)
signal replay_finished(event_count: int)

enum Mode {
	NONE,
	RECORD,
	REPLAY,
}

const STREAM_TAPE_VERSION := 3
const STREAM_TAPE_FORMAT := "xrg_stream"
const STREAM_FLUSH_EVERY := 120
const STREAM_PREFETCH_LIMIT := 256
const STREAM_RECORD_EVENT_QUEUE_LIMIT := 8192
const STREAM_RECORD_FRAME_QUEUE_LIMIT := 2048
const ADAPTIVE_OVERLOAD_HIGH_WATERMARK := 0.75
const ADAPTIVE_RECOVERY_LOW_WATERMARK := 0.25
const ADAPTIVE_OVERLOAD_TICKS := 8
const ADAPTIVE_RECOVERY_TICKS := 120
const DEFAULT_RECORD_DIR := "user://captures"
const DEFAULT_REPLAY_PATH := "user://xrg_recording.xrtape"

const DEFAULT_POSE_NAMES := [
	"default",
	"aim",
	"grip",
	"palm",
	"wrist",
]

const DEFAULT_CONTROLLER_INPUT_NAMES := [
	"trigger",
	"trigger_click",
	"trigger_touch",
	"squeeze",
	"squeeze_click",
	"squeeze_touch",
	"grip",
	"grip_click",
	"grip_force",
	"primary",
	"secondary",
	"primary_click",
	"secondary_click",
	"primary_touch",
	"secondary_touch",
	"menu_button",
	"system",
	"thumbstick",
	"thumbstick_click",
	"thumbstick_touch",
	"trackpad",
	"trackpad_click",
	"trackpad_touch",
	"thumbrest",
	"ax_button",
	"by_button",
	"index_pointing",
	"thumb_up",
]

var auto_quit_after_replay := false
var capture_physics_frames := true
var frame_capture_interval := 1
var adaptive_frame_sampling := true
var adaptive_max_frame_step := 8

var _mode: Mode = Mode.NONE
var _record_path := ""
var _record_start_usec := 0
var _physics_capture_tick := 0
var _record_paths: Dictionary = {}
var _record_event_count := 0
var _record_frame_count := 0
var _record_flush_counter := 0
var _record_writer_thread: Thread = null
var _record_writer_mutex := Mutex.new()
var _record_writer_semaphore := Semaphore.new()
var _record_writer_event_queue: Array = []
var _record_writer_frame_queue: Array = []
var _record_writer_stop := false
var _record_writer_flush_requested := false
var _record_writer_failed := false
var _record_writer_error := ""
var _record_dropped_event_count := 0
var _record_dropped_frame_count := 0
var _record_peak_event_queue := 0
var _record_peak_frame_queue := 0
var _adaptive_frame_step := 1
var _adaptive_overload_ticks := 0
var _adaptive_recovery_ticks := 0

var _extra_pose_names: Array = []
var _extra_controller_input_names: Array = []
var _pose_names: Array = []
var _controller_input_names: Array = []

var _replay_start_usec := 0
var _next_replay_event_index := 0
var _next_replay_frame_index := 0
var _replay_completed := false
var _replay_created_trackers: Dictionary = {}
var _replay_paths: Dictionary = {}
var _replay_stream_events_done := true
var _replay_stream_frames_done := true
var _replay_next_event_record: Dictionary = {}
var _replay_next_frame_record: Dictionary = {}
var _replay_reader_thread: Thread = null
var _replay_reader_mutex := Mutex.new()
var _replay_reader_semaphore := Semaphore.new()
var _replay_reader_event_queue: Array = []
var _replay_reader_frame_queue: Array = []
var _replay_reader_events_done := true
var _replay_reader_frames_done := true
var _replay_reader_stop := false
var _replay_reader_error := ""
var _replay_peak_event_queue := 0
var _replay_peak_frame_queue := 0
var _replay_event_wait_count := 0
var _replay_frame_wait_count := 0

func _ready() -> void:
	_refresh_probe_lists()
	_refresh_processing_state()
	_apply_cli_args(_collect_cli_args())

func _collect_cli_args() -> PackedStringArray:
	var user_args := OS.get_cmdline_user_args()
	if not user_args.is_empty():
		return user_args

	var raw_args := OS.get_cmdline_args()
	var filtered_args := PackedStringArray()
	var takes_value := {
		"--xrg-record": true,
		"--xrg-replay": true,
		"--xrg-frame-step": true,
		"--xrg-adaptive-max-step": true,
		"--xrg-pose-name": true,
		"--xrg-input-name": true,
	}

	var i := 0
	while i < raw_args.size():
		var arg := String(raw_args[i])
		if arg.begins_with("--xrg-"):
			filtered_args.append(arg)
			if takes_value.has(arg) and i + 1 < raw_args.size():
				var next_arg := String(raw_args[i + 1])
				if not next_arg.begins_with("--"):
					filtered_args.append(next_arg)
					i += 1
		i += 1
	return filtered_args

func _input(event: InputEvent) -> void:
	if _mode != Mode.RECORD:
		return
	if _record_writer_thread == null or _record_writer_failed:
		return
	if _enqueue_record_event({
		"t_usec": Time.get_ticks_usec() - _record_start_usec,
		"event": event,
	}):
		_record_event_count += 1
		_record_flush_counter += 1
		_flush_record_stream_if_needed()

func _process(_delta: float) -> void:
	if _mode != Mode.REPLAY or _replay_completed:
		return

	var elapsed_usec := Time.get_ticks_usec() - _replay_start_usec
	_replay_stream_events_up_to(elapsed_usec)
	_finalize_replay_if_done()

func _physics_process(_delta: float) -> void:
	if _mode == Mode.RECORD and capture_physics_frames:
		_physics_capture_tick += 1
		_update_adaptive_frame_sampling()
		var effective_interval := _effective_frame_capture_interval()
		if effective_interval <= 1 or _physics_capture_tick % effective_interval == 0:
			if _enqueue_record_frame({
				"t_usec": Time.get_ticks_usec() - _record_start_usec,
				"trackers": _snapshot_trackers(),
			}):
				_record_frame_count += 1
				_record_flush_counter += 1
				_flush_record_stream_if_needed()

	if _mode == Mode.REPLAY and not _replay_completed:
		var elapsed_usec := Time.get_ticks_usec() - _replay_start_usec
		_replay_stream_frames_up_to(elapsed_usec)
		_finalize_replay_if_done()

func _exit_tree() -> void:
	if _mode == Mode.RECORD:
		_save_recording()
	elif _mode == Mode.REPLAY:
		stop_replay()

func add_pose_probe_name(name: String) -> void:
	if name.is_empty() or _extra_pose_names.has(name):
		return
	_extra_pose_names.append(name)
	_refresh_probe_lists()

func add_controller_input_name(name: String) -> void:
	if name.is_empty() or _extra_controller_input_names.has(name):
		return
	_extra_controller_input_names.append(name)
	_refresh_probe_lists()

func start_recording(path: String = "") -> void:
	_refresh_probe_lists()

	_record_path = path if not path.is_empty() else _build_default_record_path()
	if not _open_record_stream(_record_path):
		_mode = Mode.NONE
		_refresh_processing_state()
		return

	_mode = Mode.RECORD
	_refresh_processing_state()
	_record_start_usec = Time.get_ticks_usec()
	_physics_capture_tick = 0
	_adaptive_frame_step = 1
	_adaptive_overload_ticks = 0
	_adaptive_recovery_ticks = 0
	print("[XRGhostRunner] Recording XR input to %s" % _record_path)

func stop_recording(save_to_disk := true) -> void:
	if _mode != Mode.RECORD:
		return
	_mode = Mode.NONE
	_refresh_processing_state()
	if save_to_disk:
		_save_recording()
	else:
		_close_record_stream_files()

func start_replay(path: String = DEFAULT_REPLAY_PATH) -> bool:
	var replay_path := path if not path.is_empty() else DEFAULT_REPLAY_PATH
	_replay_stream_events_done = true
	_replay_stream_frames_done = true
	_replay_next_event_record.clear()
	_replay_next_frame_record.clear()
	_replay_peak_event_queue = 0
	_replay_peak_frame_queue = 0
	_replay_event_wait_count = 0
	_replay_frame_wait_count = 0

	if not _open_stream_replay(replay_path):
		push_error("[XRGhostRunner] Failed to load stream tape: %s" % replay_path)
		_refresh_processing_state()
		return false

	_mode = Mode.REPLAY
	_refresh_processing_state()
	_replay_start_usec = Time.get_ticks_usec()
	_next_replay_event_index = 0
	_next_replay_frame_index = 0
	_replay_completed = false
	print("[XRGhostRunner] Replaying XR input from %s" % replay_path)
	return true

func stop_replay() -> void:
	if _mode != Mode.REPLAY:
		return
	_close_replay_stream_files()
	for tracker in _replay_created_trackers.values():
		if tracker != null:
			XRServer.remove_tracker(tracker)
	_replay_created_trackers.clear()

	_mode = Mode.NONE
	_refresh_processing_state()
	_next_replay_event_index = 0
	_next_replay_frame_index = 0
	_replay_completed = false

func get_mode_name() -> String:
	match _mode:
		Mode.RECORD:
			return "RECORD"
		Mode.REPLAY:
			return "REPLAY"
		_:
			return "NONE"

func get_stream_metrics() -> Dictionary:
	var writer_queue_events := 0
	var writer_queue_frames := 0
	_record_writer_mutex.lock()
	writer_queue_events = _record_writer_event_queue.size()
	writer_queue_frames = _record_writer_frame_queue.size()
	_record_writer_mutex.unlock()

	var reader_queue_events := 0
	var reader_queue_frames := 0
	_replay_reader_mutex.lock()
	reader_queue_events = _replay_reader_event_queue.size()
	reader_queue_frames = _replay_reader_frame_queue.size()
	_replay_reader_mutex.unlock()

	return {
		"mode": get_mode_name(),
		"record": {
			"events_written": _record_event_count,
			"frames_written": _record_frame_count,
			"events_dropped": _record_dropped_event_count,
			"frames_dropped": _record_dropped_frame_count,
			"queue_events": writer_queue_events,
			"queue_frames": writer_queue_frames,
			"peak_queue_events": _record_peak_event_queue,
			"peak_queue_frames": _record_peak_frame_queue,
			"event_queue_limit": STREAM_RECORD_EVENT_QUEUE_LIMIT,
			"frame_queue_limit": STREAM_RECORD_FRAME_QUEUE_LIMIT,
			"adaptive_sampling_enabled": adaptive_frame_sampling,
			"adaptive_frame_step": _adaptive_frame_step,
			"effective_frame_interval": _effective_frame_capture_interval(),
		},
		"replay": {
			"events_replayed": _next_replay_event_index,
			"frames_replayed": _next_replay_frame_index,
			"queue_events": reader_queue_events,
			"queue_frames": reader_queue_frames,
			"peak_queue_events": _replay_peak_event_queue,
			"peak_queue_frames": _replay_peak_frame_queue,
			"event_waits": _replay_event_wait_count,
			"frame_waits": _replay_frame_wait_count,
			"prefetch_limit": STREAM_PREFETCH_LIMIT,
		},
	}

func _effective_frame_capture_interval() -> int:
	var base_interval := maxi(1, frame_capture_interval)
	return base_interval * maxi(1, _adaptive_frame_step)

func _refresh_processing_state() -> void:
	var is_recording := _mode == Mode.RECORD
	var is_replaying := _mode == Mode.REPLAY
	set_process_input(is_recording)
	set_process(is_replaying)
	set_physics_process((is_recording and capture_physics_frames) or is_replaying)

func _update_adaptive_frame_sampling() -> void:
	if not adaptive_frame_sampling or _record_writer_thread == null:
		_adaptive_frame_step = 1
		_adaptive_overload_ticks = 0
		_adaptive_recovery_ticks = 0
		return

	var queue_events := 0
	var queue_frames := 0
	_record_writer_mutex.lock()
	queue_events = _record_writer_event_queue.size()
	queue_frames = _record_writer_frame_queue.size()
	_record_writer_mutex.unlock()

	var event_pressure := float(queue_events) / float(STREAM_RECORD_EVENT_QUEUE_LIMIT)
	var frame_pressure := float(queue_frames) / float(STREAM_RECORD_FRAME_QUEUE_LIMIT)
	var overloaded := event_pressure >= ADAPTIVE_OVERLOAD_HIGH_WATERMARK or frame_pressure >= ADAPTIVE_OVERLOAD_HIGH_WATERMARK
	var recovering := event_pressure <= ADAPTIVE_RECOVERY_LOW_WATERMARK and frame_pressure <= ADAPTIVE_RECOVERY_LOW_WATERMARK

	if overloaded:
		_adaptive_overload_ticks += 1
		_adaptive_recovery_ticks = 0
		if _adaptive_overload_ticks >= ADAPTIVE_OVERLOAD_TICKS and _adaptive_frame_step < adaptive_max_frame_step:
			_adaptive_frame_step = mini(_adaptive_frame_step * 2, maxi(1, adaptive_max_frame_step))
			_adaptive_overload_ticks = 0
	elif recovering and _adaptive_frame_step > 1:
		_adaptive_recovery_ticks += 1
		_adaptive_overload_ticks = 0
		if _adaptive_recovery_ticks >= ADAPTIVE_RECOVERY_TICKS:
			_adaptive_frame_step = maxi(int(_adaptive_frame_step / 2), 1)
			_adaptive_recovery_ticks = 0
	else:
		_adaptive_overload_ticks = 0
		_adaptive_recovery_ticks = 0

func _apply_cli_args(args: PackedStringArray) -> void:
	var record_requested := false
	var record_path := ""
	var replay_path := ""
	var i := 0

	while i < args.size():
		var arg := args[i]
		if arg == "--xrg-record":
			record_requested = true
			record_path = _next_arg_value(args, i, "")
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				i += 1
		elif arg.begins_with("--xrg-record="):
			record_requested = true
			record_path = arg.trim_prefix("--xrg-record=")
		elif arg == "--xrg-replay":
			replay_path = _next_arg_value(args, i, DEFAULT_REPLAY_PATH)
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				i += 1
		elif arg.begins_with("--xrg-replay="):
			replay_path = arg.trim_prefix("--xrg-replay=")
		elif arg == "--xrg-auto-quit":
			auto_quit_after_replay = true
		elif arg == "--xrg-no-frame-capture":
			capture_physics_frames = false
		elif arg == "--xrg-no-adaptive-sampling":
			adaptive_frame_sampling = false
		elif arg == "--xrg-adaptive-max-step":
			adaptive_max_frame_step = maxi(1, int(_next_arg_value(args, i, "8")))
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				i += 1
		elif arg.begins_with("--xrg-adaptive-max-step="):
			adaptive_max_frame_step = maxi(1, int(arg.trim_prefix("--xrg-adaptive-max-step=")))
		elif arg == "--xrg-frame-step":
			frame_capture_interval = maxi(1, int(_next_arg_value(args, i, "1")))
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				i += 1
		elif arg.begins_with("--xrg-frame-step="):
			frame_capture_interval = maxi(1, int(arg.trim_prefix("--xrg-frame-step=")))
		elif arg == "--xrg-pose-name":
			add_pose_probe_name(_next_arg_value(args, i, ""))
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				i += 1
		elif arg.begins_with("--xrg-pose-name="):
			add_pose_probe_name(arg.trim_prefix("--xrg-pose-name="))
		elif arg == "--xrg-input-name":
			add_controller_input_name(_next_arg_value(args, i, ""))
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				i += 1
		elif arg.begins_with("--xrg-input-name="):
			add_controller_input_name(arg.trim_prefix("--xrg-input-name="))
		i += 1

	if record_requested and not replay_path.is_empty():
		push_warning("[XRGhostRunner] Both record and replay were requested. Replay takes precedence.")

	if not replay_path.is_empty():
		start_replay(replay_path)
		return
	if record_requested:
		start_recording(record_path)

func _build_default_record_path() -> String:
	var datetime_variant = Time.get_datetime_dict_from_system()
	var year := 0
	var month := 0
	var day := 0
	var hour := 0
	var minute := 0
	var second := 0
	if typeof(datetime_variant) == TYPE_DICTIONARY:
		var datetime: Dictionary = datetime_variant
		year = int(datetime.get("year", 0))
		month = int(datetime.get("month", 0))
		day = int(datetime.get("day", 0))
		hour = int(datetime.get("hour", 0))
		minute = int(datetime.get("minute", 0))
		second = int(datetime.get("second", 0))
	var usec := int(Time.get_ticks_usec() % 1000000)
	return "%s/run_%04d%02d%02d_%02d%02d%02d_%06d.xrtape" % [DEFAULT_RECORD_DIR, year, month, day, hour, minute, second, usec]

func _next_arg_value(args: PackedStringArray, index: int, fallback: String) -> String:
	var next_index := index + 1
	if next_index < args.size():
		var candidate := args[next_index]
		if not candidate.begins_with("--"):
			return candidate
	return fallback

func _build_stream_paths(path: String) -> Dictionary:
	return {
		"meta": path,
		"events": "%s.events" % path,
		"frames": "%s.frames" % path,
	}

func _open_record_stream(path: String) -> bool:
	_close_record_stream_files()
	_record_paths = _build_stream_paths(path)

	_ensure_parent_dir(String(_record_paths.get("meta", "")))
	_ensure_parent_dir(String(_record_paths.get("events", "")))
	_ensure_parent_dir(String(_record_paths.get("frames", "")))

	var probe_events := FileAccess.open(String(_record_paths.get("events", "")), FileAccess.WRITE)
	var probe_frames := FileAccess.open(String(_record_paths.get("frames", "")), FileAccess.WRITE)
	if probe_events == null or probe_frames == null:
		push_error("[XRGhostRunner] Failed to open stream record files for %s" % path)
		_close_record_stream_files()
		return false

	probe_events = null
	probe_frames = null

	_record_event_count = 0
	_record_frame_count = 0
	_record_flush_counter = 0
	_record_writer_event_queue.clear()
	_record_writer_frame_queue.clear()
	_record_writer_stop = false
	_record_writer_flush_requested = false
	_record_writer_failed = false
	_record_writer_error = ""
	_record_dropped_event_count = 0
	_record_dropped_frame_count = 0
	_record_peak_event_queue = 0
	_record_peak_frame_queue = 0
	_record_writer_thread = Thread.new()

	var writer_start_err := _record_writer_thread.start(_record_writer_loop.bind(_record_paths))
	if writer_start_err != OK:
		push_error("[XRGhostRunner] Failed to start writer thread (%d)." % writer_start_err)
		_record_writer_thread = null
		return false

	return _write_stream_meta(false)

func _close_record_stream_files() -> void:
	if _record_writer_thread != null:
		_record_writer_mutex.lock()
		_record_writer_stop = true
		_record_writer_flush_requested = true
		_record_writer_mutex.unlock()
		_record_writer_semaphore.post()
		_record_writer_thread.wait_to_finish()
		_record_writer_thread = null

	_record_writer_event_queue.clear()
	_record_writer_frame_queue.clear()
	_record_writer_stop = false
	_record_writer_flush_requested = false
	_record_flush_counter = 0

func _flush_record_stream_if_needed(force := false) -> void:
	if _record_writer_thread == null:
		return
	if not force and _record_flush_counter < STREAM_FLUSH_EVERY:
		return
	_record_writer_mutex.lock()
	_record_writer_flush_requested = true
	_record_writer_mutex.unlock()
	_record_writer_semaphore.post()
	_record_flush_counter = 0

func _enqueue_record_event(record: Dictionary) -> bool:
	if _record_writer_thread == null or _record_writer_failed:
		return false
	_record_writer_mutex.lock()
	if _record_writer_event_queue.size() >= STREAM_RECORD_EVENT_QUEUE_LIMIT:
		_record_dropped_event_count += 1
		_record_writer_mutex.unlock()
		return false
	_record_writer_event_queue.append(record)
	if _record_writer_event_queue.size() > _record_peak_event_queue:
		_record_peak_event_queue = _record_writer_event_queue.size()
	_record_writer_mutex.unlock()
	_record_writer_semaphore.post()
	return true

func _enqueue_record_frame(record: Dictionary) -> bool:
	if _record_writer_thread == null or _record_writer_failed:
		return false
	_record_writer_mutex.lock()
	if _record_writer_frame_queue.size() >= STREAM_RECORD_FRAME_QUEUE_LIMIT:
		_record_dropped_frame_count += 1
		_record_writer_mutex.unlock()
		return false
	_record_writer_frame_queue.append(record)
	if _record_writer_frame_queue.size() > _record_peak_frame_queue:
		_record_peak_frame_queue = _record_writer_frame_queue.size()
	_record_writer_mutex.unlock()
	_record_writer_semaphore.post()
	return true

func _record_writer_loop(paths: Dictionary) -> void:
	var events_file := FileAccess.open(String(paths.get("events", "")), FileAccess.WRITE)
	var frames_file := FileAccess.open(String(paths.get("frames", "")), FileAccess.WRITE)
	if events_file == null or frames_file == null:
		_record_writer_mutex.lock()
		_record_writer_failed = true
		_record_writer_error = "Failed to open writer stream files."
		_record_writer_mutex.unlock()
		return

	while true:
		_record_writer_semaphore.wait()

		while true:
			var event_batch: Array
			var frame_batch: Array
			var flush_requested := false
			var should_stop := false

			_record_writer_mutex.lock()
			event_batch = _record_writer_event_queue
			frame_batch = _record_writer_frame_queue
			_record_writer_event_queue = []
			_record_writer_frame_queue = []
			flush_requested = _record_writer_flush_requested
			_record_writer_flush_requested = false
			should_stop = _record_writer_stop
			_record_writer_mutex.unlock()

			if event_batch.is_empty() and frame_batch.is_empty():
				if flush_requested:
					events_file.flush()
					frames_file.flush()
				if should_stop:
					events_file.flush()
					frames_file.flush()
					return
				break

			for event_record_variant in event_batch:
				events_file.store_var(event_record_variant, true)
				if events_file.get_error() != OK:
					_record_writer_mutex.lock()
					_record_writer_failed = true
					_record_writer_error = "Failed writing event stream."
					_record_writer_mutex.unlock()
					return
			for frame_record_variant in frame_batch:
				frames_file.store_var(frame_record_variant, true)
				if frames_file.get_error() != OK:
					_record_writer_mutex.lock()
					_record_writer_failed = true
					_record_writer_error = "Failed writing frame stream."
					_record_writer_mutex.unlock()
					return
			if flush_requested:
				events_file.flush()
				frames_file.flush()

func _write_stream_meta(complete: bool) -> bool:
	var meta_path := String(_record_paths.get("meta", _record_path))
	var meta_file := FileAccess.open(meta_path, FileAccess.WRITE)
	if meta_file == null:
		push_error("[XRGhostRunner] Failed to write tape metadata: %s" % meta_path)
		return false

	meta_file.store_var({
		"format": STREAM_TAPE_FORMAT,
		"version": STREAM_TAPE_VERSION,
		"complete": complete,
		"created_unix": Time.get_unix_time_from_system(),
		"event_count": _record_event_count,
		"frame_count": _record_frame_count,
		"meta": {
			"pose_names": _pose_names,
			"controller_input_names": _controller_input_names,
		},
		"files": {
			"events": String(_record_paths.get("events", "")),
			"frames": String(_record_paths.get("frames", "")),
		},
		"stats": {
			"events_dropped": _record_dropped_event_count,
			"frames_dropped": _record_dropped_frame_count,
			"peak_queue_events": _record_peak_event_queue,
			"peak_queue_frames": _record_peak_frame_queue,
			"adaptive_sampling_enabled": adaptive_frame_sampling,
			"adaptive_frame_step": _adaptive_frame_step,
			"effective_frame_interval": _effective_frame_capture_interval(),
		},
	}, true)
	meta_file.flush()
	return true

func _open_stream_replay(path: String) -> bool:
	_close_replay_stream_files()
	_replay_paths = _build_stream_paths(path)

	var meta_path := String(_replay_paths.get("meta", ""))
	var meta_file := FileAccess.open(meta_path, FileAccess.READ)
	if meta_file == null:
		return false

	var header_variant = meta_file.get_var(true)
	if typeof(header_variant) != TYPE_DICTIONARY:
		return false

	var header: Dictionary = header_variant
	if String(header.get("format", "")) != STREAM_TAPE_FORMAT:
		return false
	if int(header.get("version", 0)) != STREAM_TAPE_VERSION:
		return false

	var files_variant = header.get("files", {})
	if typeof(files_variant) == TYPE_DICTIONARY:
		var files: Dictionary = files_variant
		if files.has("events"):
			_replay_paths["events"] = String(files.get("events", _replay_paths.get("events", "")))
		if files.has("frames"):
			_replay_paths["frames"] = String(files.get("frames", _replay_paths.get("frames", "")))

	_apply_stream_meta(header)
	_replay_reader_event_queue.clear()
	_replay_reader_frame_queue.clear()
	_replay_reader_events_done = false
	_replay_reader_frames_done = false
	_replay_reader_stop = false
	_replay_reader_error = ""
	_replay_reader_thread = Thread.new()
	var reader_start_err := _replay_reader_thread.start(_replay_reader_loop.bind(_replay_paths))
	if reader_start_err != OK:
		push_error("[XRGhostRunner] Failed to start replay reader thread (%d)." % reader_start_err)
		_replay_reader_thread = null
		return false

	_replay_stream_events_done = false
	_replay_stream_frames_done = false
	_replay_next_event_record.clear()
	_replay_next_frame_record.clear()

	_load_next_stream_event_record()
	_load_next_stream_frame_record()
	print("[XRGhostRunner] Loaded stream tape: %s" % path)
	return true

func _close_replay_stream_files() -> void:
	if _replay_reader_thread != null:
		_replay_reader_mutex.lock()
		_replay_reader_stop = true
		_replay_reader_mutex.unlock()
		_replay_reader_semaphore.post()
		_replay_reader_thread.wait_to_finish()
		_replay_reader_thread = null

	_replay_reader_event_queue.clear()
	_replay_reader_frame_queue.clear()
	_replay_reader_events_done = true
	_replay_reader_frames_done = true
	_replay_reader_stop = false
	_replay_reader_error = ""
	_replay_stream_events_done = true
	_replay_stream_frames_done = true
	_replay_next_event_record.clear()
	_replay_next_frame_record.clear()
	_replay_paths.clear()

func _apply_stream_meta(header: Dictionary) -> void:
	var meta_variant = header.get("meta", {})
	if typeof(meta_variant) != TYPE_DICTIONARY:
		return
	var meta: Dictionary = meta_variant
	var pose_names_variant = meta.get("pose_names", [])
	if typeof(pose_names_variant) == TYPE_ARRAY:
		for pose_name_variant in pose_names_variant:
			add_pose_probe_name(String(pose_name_variant))
	var input_names_variant = meta.get("controller_input_names", [])
	if typeof(input_names_variant) == TYPE_ARRAY:
		for input_name_variant in input_names_variant:
			add_controller_input_name(String(input_name_variant))

func _load_next_stream_event_record() -> void:
	_replay_next_event_record.clear()
	var record: Dictionary = {}
	var done := false
	_replay_reader_mutex.lock()
	if not _replay_reader_event_queue.is_empty():
		record = _replay_reader_event_queue.pop_front()
	done = _replay_reader_events_done and _replay_reader_event_queue.is_empty()
	_replay_reader_mutex.unlock()

	if not record.is_empty():
		_replay_next_event_record = record
		_replay_stream_events_done = false
	else:
		_replay_stream_events_done = done
		if not done:
			_replay_event_wait_count += 1
	_replay_reader_semaphore.post()

func _load_next_stream_frame_record() -> void:
	_replay_next_frame_record.clear()
	var record: Dictionary = {}
	var done := false
	_replay_reader_mutex.lock()
	if not _replay_reader_frame_queue.is_empty():
		record = _replay_reader_frame_queue.pop_front()
	done = _replay_reader_frames_done and _replay_reader_frame_queue.is_empty()
	_replay_reader_mutex.unlock()

	if not record.is_empty():
		_replay_next_frame_record = record
		_replay_stream_frames_done = false
	else:
		_replay_stream_frames_done = done
		if not done:
			_replay_frame_wait_count += 1
	_replay_reader_semaphore.post()

func _replay_stream_events_up_to(elapsed_usec: int) -> void:
	if _replay_next_event_record.is_empty():
		_load_next_stream_event_record()
	while not _replay_next_event_record.is_empty():
		var timestamp_usec := int(_replay_next_event_record.get("t_usec", -1))
		if timestamp_usec < 0 or timestamp_usec > elapsed_usec:
			break

		var replay_event = _replay_next_event_record.get("event", null)
		if replay_event is InputEvent:
			Input.parse_input_event(replay_event)
		_next_replay_event_index += 1
		_load_next_stream_event_record()

func _replay_stream_frames_up_to(elapsed_usec: int) -> void:
	if _replay_next_frame_record.is_empty():
		_load_next_stream_frame_record()
	while not _replay_next_frame_record.is_empty():
		var timestamp_usec := int(_replay_next_frame_record.get("t_usec", -1))
		if timestamp_usec < 0 or timestamp_usec > elapsed_usec:
			break
		_apply_replay_frame(_replay_next_frame_record)
		_next_replay_frame_index += 1
		_load_next_stream_frame_record()

func _read_next_stream_record(file: FileAccess, required_key: String) -> Dictionary:
	if file == null:
		return {}
	while true:
		if file.get_position() >= file.get_length():
			return {}
		var record_variant = file.get_var(true)
		if typeof(record_variant) != TYPE_DICTIONARY:
			continue
		var record: Dictionary = record_variant
		if not record.has("t_usec") or not record.has(required_key):
			continue
		return record
	return {}

func _replay_reader_loop(paths: Dictionary) -> void:
	var events_file := FileAccess.open(String(paths.get("events", "")), FileAccess.READ)
	var frames_file := FileAccess.open(String(paths.get("frames", "")), FileAccess.READ)
	var events_done := events_file == null
	var frames_done := frames_file == null

	while true:
		_replay_reader_mutex.lock()
		var should_stop := _replay_reader_stop
		var event_queue_size := _replay_reader_event_queue.size()
		var frame_queue_size := _replay_reader_frame_queue.size()
		_replay_reader_mutex.unlock()

		if should_stop:
			return

		var did_work := false
		if not events_done and event_queue_size < STREAM_PREFETCH_LIMIT:
			var event_record := _read_next_stream_record(events_file, "event")
			if event_record.is_empty():
				events_done = true
			else:
				_replay_reader_mutex.lock()
				_replay_reader_event_queue.append(event_record)
				if _replay_reader_event_queue.size() > _replay_peak_event_queue:
					_replay_peak_event_queue = _replay_reader_event_queue.size()
				_replay_reader_mutex.unlock()
			did_work = true

		if not frames_done and frame_queue_size < STREAM_PREFETCH_LIMIT:
			var frame_record := _read_next_stream_record(frames_file, "trackers")
			if frame_record.is_empty():
				frames_done = true
			else:
				_replay_reader_mutex.lock()
				_replay_reader_frame_queue.append(frame_record)
				if _replay_reader_frame_queue.size() > _replay_peak_frame_queue:
					_replay_peak_frame_queue = _replay_reader_frame_queue.size()
				_replay_reader_mutex.unlock()
			did_work = true

		_replay_reader_mutex.lock()
		_replay_reader_events_done = events_done
		_replay_reader_frames_done = frames_done
		_replay_reader_mutex.unlock()

		if events_done and frames_done:
			return
		if not did_work:
			_replay_reader_semaphore.wait()

func _refresh_probe_lists() -> void:
	_pose_names = DEFAULT_POSE_NAMES.duplicate()
	for pose_name_variant in _extra_pose_names:
		var pose_name := String(pose_name_variant)
		if not pose_name.is_empty() and not _pose_names.has(pose_name):
			_pose_names.append(pose_name)

	_controller_input_names = DEFAULT_CONTROLLER_INPUT_NAMES.duplicate()
	for action_variant in InputMap.get_actions():
		var action_name := String(action_variant)
		if not action_name.is_empty() and not _controller_input_names.has(action_name):
			_controller_input_names.append(action_name)
	for input_name_variant in _extra_controller_input_names:
		var input_name := String(input_name_variant)
		if not input_name.is_empty() and not _controller_input_names.has(input_name):
			_controller_input_names.append(input_name)

func _snapshot_trackers() -> Array:
	var tracker_snapshots: Array = []
	var tracker_map_variant = XRServer.get_trackers(XRServer.TRACKER_ANY)
	if typeof(tracker_map_variant) != TYPE_DICTIONARY:
		return tracker_snapshots

	var tracker_map: Dictionary = tracker_map_variant
	var tracker_names: PackedStringArray = []
	for key in tracker_map.keys():
		tracker_names.append(String(key))
	tracker_names.sort()

	for tracker_name in tracker_names:
		var tracker = tracker_map.get(StringName(tracker_name), null)
		if tracker == null:
			tracker = tracker_map.get(tracker_name, null)
		if tracker == null or not (tracker is XRTracker):
			continue
		tracker_snapshots.append(_snapshot_tracker(tracker))

	return tracker_snapshots

func _snapshot_tracker(tracker: XRTracker) -> Dictionary:
	var snapshot := {
		"name": String(tracker.get_tracker_name()),
		"type": int(tracker.get_tracker_type()),
		"desc": String(tracker.get_tracker_desc()),
		"class": tracker.get_class(),
	}

	if tracker is XRPositionalTracker:
		snapshot["positional"] = _snapshot_positional_tracker(tracker as XRPositionalTracker)
	if tracker is XRControllerTracker:
		snapshot["controller"] = _snapshot_controller_tracker(tracker as XRControllerTracker)
	if tracker is XRHandTracker:
		snapshot["hand"] = _snapshot_hand_tracker(tracker as XRHandTracker)
	if tracker is XRBodyTracker:
		snapshot["body"] = _snapshot_body_tracker(tracker as XRBodyTracker)
	if tracker is XRFaceTracker:
		snapshot["face"] = _snapshot_face_tracker(tracker as XRFaceTracker)

	return snapshot

func _snapshot_positional_tracker(tracker: XRPositionalTracker) -> Dictionary:
	var poses := {}
	for pose_name_variant in _pose_names:
		var pose_name := String(pose_name_variant)
		if not tracker.has_pose(pose_name):
			continue
		var pose := tracker.get_pose(pose_name)
		if pose == null:
			continue
		poses[pose_name] = {
			"has_tracking_data": pose.get_has_tracking_data(),
			"transform": pose.get_transform(),
			"linear_velocity": pose.get_linear_velocity(),
			"angular_velocity": pose.get_angular_velocity(),
			"tracking_confidence": int(pose.get_tracking_confidence()),
		}

	return {
		"tracker_profile": tracker.get_tracker_profile(),
		"tracker_hand": int(tracker.get_tracker_hand()),
		"poses": poses,
	}

func _snapshot_controller_tracker(tracker: XRControllerTracker) -> Dictionary:
	var inputs := {}
	for input_name_variant in _controller_input_names:
		var input_name := String(input_name_variant)
		inputs[input_name] = tracker.get_input(input_name)
	return {
		"inputs": inputs,
	}

func _snapshot_hand_tracker(tracker: XRHandTracker) -> Dictionary:
	var joints := []
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		joints.append({
			"flags": int(tracker.get_hand_joint_flags(joint)),
			"transform": tracker.get_hand_joint_transform(joint),
			"radius": float(tracker.get_hand_joint_radius(joint)),
			"linear_velocity": tracker.get_hand_joint_linear_velocity(joint),
			"angular_velocity": tracker.get_hand_joint_angular_velocity(joint),
		})
	return {
		"has_tracking_data": tracker.get_has_tracking_data(),
		"hand_tracking_source": int(tracker.get_hand_tracking_source()),
		"joints": joints,
	}

func _snapshot_body_tracker(tracker: XRBodyTracker) -> Dictionary:
	var joints := []
	for joint in range(XRBodyTracker.JOINT_MAX):
		joints.append({
			"flags": int(tracker.get_joint_flags(joint)),
			"transform": tracker.get_joint_transform(joint),
		})
	return {
		"has_tracking_data": tracker.get_has_tracking_data(),
		"body_flags": int(tracker.get_body_flags()),
		"joints": joints,
	}

func _snapshot_face_tracker(tracker: XRFaceTracker) -> Dictionary:
	return {
		"blend_shapes": tracker.get_blend_shapes(),
	}

func _apply_replay_frame(frame: Dictionary) -> void:
	var trackers_variant = frame.get("trackers", [])
	if typeof(trackers_variant) != TYPE_ARRAY:
		return

	for tracker_snapshot_variant in trackers_variant:
		if typeof(tracker_snapshot_variant) != TYPE_DICTIONARY:
			continue
		var tracker_snapshot: Dictionary = tracker_snapshot_variant
		var tracker := _resolve_or_create_replay_tracker(tracker_snapshot)
		if tracker == null:
			continue
		_apply_tracker_snapshot(tracker, tracker_snapshot)

func _resolve_or_create_replay_tracker(snapshot: Dictionary) -> XRTracker:
	var tracker_name := String(snapshot.get("name", ""))
	if tracker_name.is_empty():
		return null

	var existing_tracker = XRServer.get_tracker(StringName(tracker_name))
	if existing_tracker is XRTracker:
		return existing_tracker
	if _replay_created_trackers.has(tracker_name):
		return _replay_created_trackers[tracker_name]

	var created_tracker := _create_tracker_for_snapshot(snapshot)
	if created_tracker == null:
		return null

	XRServer.add_tracker(created_tracker)
	_replay_created_trackers[tracker_name] = created_tracker
	return created_tracker

func _create_tracker_for_snapshot(snapshot: Dictionary) -> XRTracker:
	var tracker_name := String(snapshot.get("name", ""))
	var tracker_type := int(snapshot.get("type", XRServer.TRACKER_UNKNOWN))
	var tracker_desc := String(snapshot.get("desc", ""))
	var tracker_class_name := String(snapshot.get("class", "XRPositionalTracker"))

	var tracker: XRTracker = null
	match tracker_class_name:
		"XRControllerTracker":
			tracker = XRControllerTracker.new()
		"XRHandTracker":
			tracker = XRHandTracker.new()
		"XRBodyTracker":
			tracker = XRBodyTracker.new()
		"XRFaceTracker":
			tracker = XRFaceTracker.new()
		"XRPositionalTracker":
			tracker = XRPositionalTracker.new()
		_:
			if snapshot.has("face"):
				tracker = XRFaceTracker.new()
			elif snapshot.has("hand"):
				tracker = XRHandTracker.new()
			elif snapshot.has("body"):
				tracker = XRBodyTracker.new()
			elif snapshot.has("controller"):
				tracker = XRControllerTracker.new()
			else:
				tracker = XRPositionalTracker.new()

	if tracker == null:
		return null

	tracker.set_tracker_name(tracker_name)
	tracker.set_tracker_type(tracker_type)
	tracker.set_tracker_desc(tracker_desc)
	return tracker

func _apply_tracker_snapshot(tracker: XRTracker, snapshot: Dictionary) -> void:
	if tracker is XRPositionalTracker and snapshot.has("positional"):
		var positional_data = snapshot.get("positional", {})
		if typeof(positional_data) == TYPE_DICTIONARY:
			_apply_positional_snapshot(tracker as XRPositionalTracker, positional_data)

	if tracker is XRControllerTracker and snapshot.has("controller"):
		var controller_data = snapshot.get("controller", {})
		if typeof(controller_data) == TYPE_DICTIONARY:
			_apply_controller_snapshot(tracker as XRControllerTracker, controller_data)

	if tracker is XRHandTracker and snapshot.has("hand"):
		var hand_data = snapshot.get("hand", {})
		if typeof(hand_data) == TYPE_DICTIONARY:
			_apply_hand_snapshot(tracker as XRHandTracker, hand_data)

	if tracker is XRBodyTracker and snapshot.has("body"):
		var body_data = snapshot.get("body", {})
		if typeof(body_data) == TYPE_DICTIONARY:
			_apply_body_snapshot(tracker as XRBodyTracker, body_data)

	if tracker is XRFaceTracker and snapshot.has("face"):
		var face_data = snapshot.get("face", {})
		if typeof(face_data) == TYPE_DICTIONARY:
			_apply_face_snapshot(tracker as XRFaceTracker, face_data)

func _apply_positional_snapshot(tracker: XRPositionalTracker, positional_data: Dictionary) -> void:
	if positional_data.has("tracker_profile"):
		tracker.set_tracker_profile(String(positional_data.get("tracker_profile", "")))
	if positional_data.has("tracker_hand"):
		tracker.set_tracker_hand(int(positional_data.get("tracker_hand", XRPositionalTracker.TRACKER_HAND_UNKNOWN)))

	var poses_variant = positional_data.get("poses", {})
	if typeof(poses_variant) != TYPE_DICTIONARY:
		return

	var poses: Dictionary = poses_variant
	for pose_name_variant in poses.keys():
		var pose_name := String(pose_name_variant)
		var pose_data_variant = poses[pose_name_variant]
		if typeof(pose_data_variant) != TYPE_DICTIONARY:
			continue
		var pose_data: Dictionary = pose_data_variant
		if not bool(pose_data.get("has_tracking_data", true)):
			tracker.invalidate_pose(pose_name)
			continue
		tracker.set_pose(
			pose_name,
			pose_data.get("transform", Transform3D.IDENTITY),
			pose_data.get("linear_velocity", Vector3.ZERO),
			pose_data.get("angular_velocity", Vector3.ZERO),
			int(pose_data.get("tracking_confidence", 0))
		)

func _apply_controller_snapshot(tracker: XRControllerTracker, controller_data: Dictionary) -> void:
	var inputs_variant = controller_data.get("inputs", {})
	if typeof(inputs_variant) != TYPE_DICTIONARY:
		return

	var inputs: Dictionary = inputs_variant
	for input_name_variant in inputs.keys():
		var input_name := String(input_name_variant)
		tracker.set_input(input_name, inputs[input_name_variant])

func _apply_hand_snapshot(tracker: XRHandTracker, hand_data: Dictionary) -> void:
	tracker.set_has_tracking_data(bool(hand_data.get("has_tracking_data", false)))
	tracker.set_hand_tracking_source(int(hand_data.get("hand_tracking_source", XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN)))

	var joints_variant = hand_data.get("joints", [])
	if typeof(joints_variant) != TYPE_ARRAY:
		return

	var joints: Array = joints_variant
	var joint_count := mini(joints.size(), XRHandTracker.HAND_JOINT_MAX)
	for joint_index in range(joint_count):
		var joint_variant = joints[joint_index]
		if typeof(joint_variant) != TYPE_DICTIONARY:
			continue
		var joint_data: Dictionary = joint_variant
		tracker.set_hand_joint_flags(joint_index, int(joint_data.get("flags", 0)))
		tracker.set_hand_joint_transform(joint_index, joint_data.get("transform", Transform3D.IDENTITY))
		tracker.set_hand_joint_radius(joint_index, float(joint_data.get("radius", 0.0)))
		tracker.set_hand_joint_linear_velocity(joint_index, joint_data.get("linear_velocity", Vector3.ZERO))
		tracker.set_hand_joint_angular_velocity(joint_index, joint_data.get("angular_velocity", Vector3.ZERO))

func _apply_body_snapshot(tracker: XRBodyTracker, body_data: Dictionary) -> void:
	tracker.set_has_tracking_data(bool(body_data.get("has_tracking_data", false)))
	tracker.set_body_flags(int(body_data.get("body_flags", 0)))

	var joints_variant = body_data.get("joints", [])
	if typeof(joints_variant) != TYPE_ARRAY:
		return

	var joints: Array = joints_variant
	var joint_count := mini(joints.size(), XRBodyTracker.JOINT_MAX)
	for joint_index in range(joint_count):
		var joint_variant = joints[joint_index]
		if typeof(joint_variant) != TYPE_DICTIONARY:
			continue
		var joint_data: Dictionary = joint_variant
		tracker.set_joint_flags(joint_index, int(joint_data.get("flags", 0)))
		tracker.set_joint_transform(joint_index, joint_data.get("transform", Transform3D.IDENTITY))

func _apply_face_snapshot(tracker: XRFaceTracker, face_data: Dictionary) -> void:
	if face_data.has("blend_shapes"):
		tracker.set_blend_shapes(face_data["blend_shapes"])

func _finalize_replay_if_done() -> void:
	if _replay_completed:
		return
	if not _replay_stream_events_done or not _replay_stream_frames_done:
		return
	if not _replay_next_event_record.is_empty() or not _replay_next_frame_record.is_empty():
		return

	_replay_completed = true
	emit_signal("replay_finished", _next_replay_event_index)
	print("[XRGhostRunner] Replay finished (%d events, %d frames)." % [_next_replay_event_index, _next_replay_frame_index])
	if auto_quit_after_replay:
		get_tree().quit(0)

func _save_recording() -> void:
	_flush_record_stream_if_needed(true)
	_close_record_stream_files()
	if _record_writer_failed:
		push_error("[XRGhostRunner] Writer thread error: %s" % _record_writer_error)
		_write_stream_meta(false)
		return
	if _record_dropped_event_count > 0 or _record_dropped_frame_count > 0:
		push_warning("[XRGhostRunner] Queue limits were hit. Dropped events=%d, frames=%d." % [_record_dropped_event_count, _record_dropped_frame_count])
	if not _write_stream_meta(true):
		return
	emit_signal("recording_saved", _record_path, _record_event_count)
	print("[XRGhostRunner] Saved %d events and %d frames to %s (stream sidecars: .events/.frames, peak queues events=%d frames=%d, effective frame interval=%d)." % [_record_event_count, _record_frame_count, _record_path, _record_peak_event_queue, _record_peak_frame_queue, _effective_frame_capture_interval()])

func _ensure_parent_dir(path: String) -> void:
	var base_dir := path.get_base_dir()
	if base_dir.is_empty():
		return
	var absolute_dir := ProjectSettings.globalize_path(base_dir)
	var err := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("[XRGhostRunner] Could not create directory: %s" % absolute_dir)
