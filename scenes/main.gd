extends Node

func _ready() -> void:
	print("XRGhostRunner demo scene loaded.")
	if has_node("/root/XRInputTape"):
		var tape = get_node("/root/XRInputTape")
		print("XRInputTape mode: %s" % tape.get_mode_name())
	else:
		print("XRInputTape singleton not found.")
