extends SceneTree
## Headless end-to-end check:
##   godot --headless --path godot/builder -s tests/run_in_game_check.gd
## Builds a real builder document, launches The Synaptic Sea preview runner,
## and verifies the machine-readable runtime acceptance result.

const FIXTURE := "crates/derelict_core/assets/golden_areas/airlock_2x2.json"
const TIMEOUT_SECONDS := 45.0

var _failed := false
var _app: Node
var _preview_pid := -1


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	_app = load("res://builder.tscn").instantiate()
	root.add_child(_app)
	await process_frame
	if not is_instance_valid(_app):
		_fail("builder app failed to instantiate")
		_finish()
		return

	var expected_root := OS.get_environment("SYNAPTIC_SEA_ROOT").simplify_path()
	if expected_root.is_empty():
		expected_root = _repo_root().get_base_dir().path_join("the-synaptic-sea").simplify_path()
	var actual_root := str(_app._content_root_path).simplify_path()
	if actual_root.to_lower() != expected_root.to_lower():
		_fail("content root did not resolve to %s: %s" % [expected_root, actual_root])

	var fixture_path := _repo_root().path_join(FIXTURE)
	var fixture_file := FileAccess.open(fixture_path, FileAccess.READ)
	if fixture_file == null:
		_fail("fixture missing: %s" % fixture_path)
		await _cleanup_app()
		_finish()
		return
	var document: Dictionary = _app.author.load_golden(fixture_file.get_as_text())
	if document.is_empty():
		_fail("fixture could not be loaded by DerelictAuthor")
	else:
		# The committed fixture is an airlock, which the builder deliberately marks
		# as preview-only for fire because it has no live hull compartment. Exercise
		# Run in Game with a supported bridge room so the authored fire must ignite
		# in the production compartment model instead of asserting an unsupported
		# visual-only overlay is runtime-ready.
		var topology: Dictionary = document.get("topology", {})
		var rooms: Array = topology.get("rooms", [])
		if rooms.is_empty() or not (rooms[0] is Dictionary):
			_fail("fixture has no room to adapt for runtime acceptance")
			await _cleanup_app()
			_finish()
			return
		var preview_room: Dictionary = rooms[0]
		preview_room["role"] = "bridge"
		rooms[0] = preview_room
		topology["rooms"] = rooms
		document["topology"] = topology
		# Keep the fixture's explicit-inventory prop in the runtime acceptance,
		# but adapt its furnishing identity to the room role alongside the room.
		# Hydration intentionally rejects the original airlock-only suit_locker in
		# a bridge, just as interactive placement would.
		var props: Array = document.get("props", [])
		if props.is_empty() or not (props[0] is Dictionary):
			_fail("fixture has no prop to adapt for runtime acceptance")
			await _cleanup_app()
			_finish()
			return
		var preview_prop: Dictionary = props[0]
		preview_prop["proto"] = "bridge_locker"
		preview_prop["visual_id"] = "generic_locker"
		props[0] = preview_prop
		document["props"] = props
		var zone_base := {
			"from_room": "airlock_01", "to_room": "airlock_01",
			"from_cell": [0, 0, 0], "to_cell": [1, 0, 0],
			"module_id": "", "compartment_id": "bridge", "rationale": "runtime preview acceptance",
		}
		var hazards: Dictionary = document.get("hazards", {})
		for hazard in [
			["fire_zones", "preview_fire", "timed_fire"],
			["arc_zones", "preview_arc", "electrical_arc"],
			["breach_zones", "preview_breach", "hull_breach"],
			["radiation_zones", "preview_radiation", "radiation"],
		]:
			var zone := zone_base.duplicate(true)
			zone["id"] = hazard[1]
			zone["kind"] = hazard[2]
			hazards[hazard[0]] = [zone]
		document["hazards"] = hazards
		_app._session.start_new(document)
		if not _app._apply_source_document(document):
			_fail("fixture hydration failed")
		await create_timer(0.35).timeout
		if not _app._compile_ok or not _app._session.validation_matches_current():
			_fail("fixture did not reach current validation: compile_ok=%s current=%s result=%s" % [
				_app._compile_ok, _app._session.validation_matches_current(), _app._session.compile_result,
			])
		else:
			_app._on_run_game_pressed()
			_preview_pid = int(_app._preview_process_id)
			await _wait_for_preview_result()
			_check_internal_preview_timeout()

	await _cleanup_app()
	_finish()


func _wait_for_preview_result() -> void:
	var elapsed := 0.0
	while elapsed < TIMEOUT_SECONDS:
		if not str(_app._preview_result_path).is_empty() and FileAccess.file_exists(_app._preview_result_path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_app._preview_result_path))
			if not (parsed is Dictionary):
				_fail("preview result was not a JSON object")
				return
			var result: Dictionary = parsed
			if not bool(result.get("ok", false)):
				_fail("runtime acceptance failed: %s" % "; ".join(result.get("errors", [])))
				return
			var checks: Dictionary = result.get("checks", {})
			for check in [
				"structural_collision", "navigation", "objectives", "props", "loot", "vertical_links",
				"fire", "arc", "electrical", "radiation", "breach", "atmosphere", "portal_interaction",
			]:
				if not bool(checks.get(check, false)):
					_fail("runtime acceptance check was false or missing: %s (%s)" % [check, checks])
			print("RUN_IN_GAME result checks=%s" % checks)
			return
		if _preview_pid > 0 and not OS.is_process_running(_preview_pid):
			_fail("preview process exited before writing a result (pid=%d)" % _preview_pid)
			return
		await create_timer(0.25).timeout
		elapsed += 0.25
	_fail("preview did not produce a result within %.1fs (pid=%d)" % [TIMEOUT_SECONDS, _preview_pid])


func _check_internal_preview_timeout() -> void:
	_app._preview_result_path = "user://derelict_builder/missing_preview_result.json"
	_app._preview_process_id = -1
	_app._preview_deadline_msec = Time.get_ticks_msec() - 1
	_app._preview_result_timer.start()
	_app._poll_preview_result()
	if not _app._preview_result_timer.is_stopped():
		_fail("internal preview timeout left the poller running")
	if int(_app._preview_process_id) != -1 or int(_app._preview_deadline_msec) != 0:
		_fail("internal preview timeout did not reset process state")
	if not str(_app._status.text).contains("within 45 seconds"):
		_fail("internal preview timeout did not surface an actionable error")
	if _app.get_node("%RunGameBtn").disabled:
		_fail("internal preview timeout left Run in Game disabled")


func _cleanup_app() -> void:
	if _preview_pid > 0 and OS.is_process_running(_preview_pid):
		OS.kill(_preview_pid)
		await create_timer(0.1).timeout
	_preview_pid = -1
	if is_instance_valid(_app):
		_app.get_tree().auto_accept_quit = true
		_app.queue_free()
		await process_frame
		await process_frame
	_app = null


func _repo_root() -> String:
	return ProjectSettings.globalize_path("res://../..")


func _finish() -> void:
	if _failed:
		print("RUN_IN_GAME: FAIL")
		quit(1)
	else:
		print("RUN_IN_GAME: PASS")
		quit(0)


func _fail(message: String) -> void:
	push_error("FAIL: %s" % message)
	_failed = true
