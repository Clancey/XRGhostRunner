@tool
extends EditorPlugin

const AUTOLOAD_NAME := "XRInputTape"
const AUTOLOAD_PATH := "res://addons/xr_ghost_runner/xr_input_tape.gd"
var _autoload_added_by_plugin := false

func _enter_tree() -> void:
	_ensure_autoload_singleton()

func _exit_tree() -> void:
	if _autoload_added_by_plugin:
		remove_autoload_singleton(AUTOLOAD_NAME)
		_autoload_added_by_plugin = false

func _ensure_autoload_singleton() -> void:
	var key := "autoload/%s" % AUTOLOAD_NAME
	if ProjectSettings.has_setting(key):
		var value := String(ProjectSettings.get_setting(key, ""))
		if value == AUTOLOAD_PATH or value == "*%s" % AUTOLOAD_PATH:
			return
		push_warning("[XRGhostRunner] Existing autoload '%s' is not managed by this plugin: %s" % [AUTOLOAD_NAME, value])
		return
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_autoload_added_by_plugin = true
