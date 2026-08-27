extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/guided_workspace_check.gd
## Guided workspace shell, honest stage selection, and neutral empty startup.

const STAGES := [
	"Geometry",
	"Connections",
	"Props & Assets",
	"Gameplay",
	"Validate & Run",
]

var _failed := false


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var scene = load("res://builder.tscn")
	if scene == null:
		_fail("builder.tscn missing")
		_finish()
		return
	var app = scene.instantiate()
	root.add_child(app)

	_check_document_bar(app)
	_check_stage_shell(app)
	_check_persistent_guidance(app)
	_check_problems_panel(app)
	_check_inspector_onboarding(app)

	# Let the compile debounce elapse. A fresh document must remain a neutral
	# authoring state, not run Rust validation against empty occupancy.
	await create_timer(0.12).timeout
	var issues: ItemList = app.get_node_or_null("%IssuesList")
	if issues == null or issues.item_count == 0:
		_fail("empty document guidance missing")
	else:
		var text := issues.get_item_text(0)
		if text.find("Start with Geometry") < 0:
			_fail("empty document should guide Geometry, got '%s'" % text)
		if text.find("OccupancyMalformed") >= 0:
			_fail("empty document surfaced OccupancyMalformed")

	await _check_unlocked_stage_context(app)

	app.free()
	_finish()


func _check_document_bar(app: Node) -> void:
	var expected := {
		"NewBtn": "New",
		"OpenBtn": "Open",
		"SaveBtn": "Save",
		"SaveAsBtn": "Save As",
		"UndoBtn": "Undo",
		"RedoBtn": "Redo",
		"RunGameBtn": "Run in Game",
	}
	for node_name in expected:
		var button: Button = app.get_node_or_null("%%%s" % node_name)
		if button == null:
			_fail("document action %s missing" % node_name)
		elif button.text != expected[node_name]:
			_fail("%s label got '%s'" % [node_name, button.text])
	var dirty: Label = app.get_node_or_null("%DirtyLabel")
	if dirty == null or dirty.text.find("Saved") < 0:
		_fail("saved/dirty state is not persistent")
	var run: Button = app.get_node_or_null("%RunGameBtn")
	if run != null and not run.disabled:
		_fail("Run in Game must remain blocked until the runtime runner exists")


func _check_stage_shell(app: Node) -> void:
	var bar: TabBar = app.get_node_or_null("%PhaseBar")
	if bar == null:
		_fail("PhaseBar missing")
		return
	if bar.tab_count != STAGES.size():
		_fail("expected 5 stages, got %d" % bar.tab_count)
		return
	for i in STAGES.size():
		if bar.get_tab_title(i) != STAGES[i]:
			_fail("stage %d got '%s'" % [i, bar.get_tab_title(i)])
		if bar.is_tab_disabled(i):
			_fail("stage %s must stay selectable" % STAGES[i])

	var checklist: ItemList = app.get_node_or_null("%StageChecklist")
	if checklist == null or checklist.item_count != STAGES.size():
		_fail("left stage checklist missing five stages")
		return

	# Props is blocked on an empty document, but selection must not redirect.
	bar.current_tab = 2
	await process_frame
	if bar.current_tab != 2:
		_fail("blocked stage silently redirected to %d" % bar.current_tab)
	var blocker: Label = app.get_node_or_null("%StageBlockerLabel")
	if blocker == null or blocker.text.find("Paint at least one room") < 0:
		_fail("blocked Props stage lacks exact prerequisite")


func _check_persistent_guidance(app: Node) -> void:
	var current: Label = app.get_node_or_null("%CurrentToolLabel")
	var next: Label = app.get_node_or_null("%NextActionLabel")
	var pending: Label = app.get_node_or_null("%PendingEndpointLabel")
	if current == null or current.text.find("Current tool") < 0:
		_fail("persistent current-tool label missing")
	if next == null or next.text.find("Next action") < 0:
		_fail("persistent next-action label missing")
	if pending == null or pending.text.find("Endpoint") < 0:
		_fail("persistent pending-endpoint label missing")
	if current == null or next == null or pending == null:
		return
	var before := [current.text, next.text, pending.text]
	var lattice = app.get_node_or_null("%OccupancyLattice")
	if lattice != null:
		lattice.hover_info.emit("temporary hover text")
	if [current.text, next.text, pending.text] != before:
		_fail("hover text overwrote persistent guidance")
	if lattice != null:
		lattice._begin_pending(Vector3i(2, 3, 1))
		if pending.text.find("(2, 3) on deck 1") < 0:
			_fail("pending endpoint does not update independently of hover text")
		lattice._cancel_pending()
		if pending.text.find("none selected") < 0:
			_fail("cleared endpoint stayed visible without a hover event")
		lattice._begin_pending(Vector3i(4, 5, 0))
		lattice.cancel_pointer()
		if pending.text.find("none selected") < 0:
			_fail("pointer cancellation left a stale endpoint indicator")


func _check_problems_panel(app: Node) -> void:
	var title: Label = app.get_node_or_null("%ProblemsTitle")
	var list: ItemList = app.get_node_or_null("%IssuesList")
	if title == null or title.text != "Problems":
		_fail("Problems panel title missing")
	if list == null:
		_fail("Problems list missing")


func _check_inspector_onboarding(app: Node) -> void:
	var inspector = app.get_node_or_null("%InspectorDock")
	if inspector == null or inspector._empty == null:
		_fail("inspector onboarding missing")
		return
	var copy := str(inspector._empty.text)
	if copy.find("stamps+selects") >= 0:
		_fail("inspector still claims occupied paint stamps a role")
	if copy.find("Workspace checklist") < 0:
		_fail("inspector onboarding does not point to the guided workflow")


func _check_unlocked_stage_context(app: Node) -> void:
	var lattice = app.get_node("%OccupancyLattice")
	lattice.active_role = "airlock"
	if not lattice.paint_cell(Vector3i.ZERO):
		_fail("could not paint representative room")
		return
	# Stage-shell behavior is isolated here; Rust compile/preview parity is
	# covered by the structural and module-picker checks.
	app._compile_timer.stop()
	app._set_phase2_ready(true)
	await process_frame
	var checklist: ItemList = app.get_node("%StageChecklist")
	if checklist.get_item_text(1).find("[BLOCKED]") >= 0:
		_fail("Connections stayed blocked after painting a room")
	if checklist.get_item_text(2).find("[BLOCKED]") >= 0:
		_fail("Props & Assets stayed blocked after successful compile")

	checklist.item_selected.emit(1)
	await process_frame
	if app.get_node("%PhaseBar").current_tab != 1:
		_fail("left checklist did not select Connections")
	if not app.get_node("%StateList").visible or app.get_node("VBox/Body/LeftDock/RoleScroll").visible:
		_fail("Connections shelf did not hide Geometry-only controls")
	var visible_connection_tools := 0
	for child in app.get_node("%ToolList").get_children():
		if child is Button and child.visible:
			visible_connection_tools += 1
	if visible_connection_tools != 2:
		_fail("Connections shelf expected 2 tools, got %d" % visible_connection_tools)

	checklist.item_selected.emit(2)
	await process_frame
	if not app.get_node("%PaletteDock").visible:
		_fail("Props & Assets did not show the asset browser")

	app._show_issues([{"code": "TestProblem", "detail": "focus me", "deck": 0, "target_id": "airlock_01"}])
	var issues: ItemList = app.get_node("%IssuesList")
	issues.item_selected.emit(0)
	if app.get_node("%StatusLabel").text.find("airlock_01") < 0:
		_fail("selecting a problem did not focus its authored target")


func _finish() -> void:
	if _failed:
		print("GUIDED_WORKSPACE: FAIL")
		quit(1)
	else:
		print("GUIDED_WORKSPACE: PASS")
		quit(0)


func _fail(msg: String) -> void:
	push_error("FAIL: %s" % msg)
	_failed = true
