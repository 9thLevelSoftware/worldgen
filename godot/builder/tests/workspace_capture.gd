extends SceneTree
## Visual verification helper (windowed):
##   godot --path godot/builder -s tests/workspace_capture.gd -- out.png 1600 900

var _frames := 0
var _output := "res://../../target/builder_workspace.png"
var _size := Vector2i(1600, 900)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_output = str(args[0])
	if args.size() >= 3:
		_size = Vector2i(int(args[1]), int(args[2]))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	change_scene_to_file("res://builder.tscn")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 45:
		return false
	var image := root.get_viewport().get_texture().get_image()
	var error := image.save_png(_output)
	if error != OK:
		push_error("WORKSPACE_CAPTURE: failed %s (%d)" % [_output, error])
		quit(1)
	else:
		print("WORKSPACE_CAPTURE: saved %s at %dx%d" % [_output, image.get_width(), image.get_height()])
		quit(0)
	return true
