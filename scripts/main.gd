extends Control

const KubeClient = preload("res://scripts/kube_client.gd")
const NAV_BUTTON_SCENE = preload("res://scenes/components/nav_button.tscn")

const ALL_NAMESPACES := "All Namespaces"
const BG_TOP := Color8(4, 9, 16, 255)
const BG_BOTTOM := Color8(7, 18, 30, 255)
const PANEL_BG := Color8(9, 20, 33, 232)
const PANEL_BG_ALT := Color8(12, 26, 42, 236)
const BORDER := Color8(76, 215, 255, 180)
const BORDER_SOFT := Color8(40, 96, 124, 180)
const TEXT := Color8(226, 244, 255, 255)
const TEXT_MUTED := Color8(121, 158, 184, 255)
const ACCENT := Color8(88, 240, 255, 255)
const ACCENT_WARM := Color8(255, 183, 67, 255)

static var _theme_texture_cache := {}

var client = KubeClient.new()
var dashboard_state: Dictionary = {}
var ui := {}
var context_button_group := ButtonGroup.new()
var resource_button_group := ButtonGroup.new()
var selected_context := ""
var selected_namespace := ALL_NAMESPACES
var selected_resource := "Applications"
var selected_group_key := ""
var port_forward_pid := 0
var auto_refresh_timer: Timer
var import_error_tween: Tween
var last_status_message := ""
var pending_import_validation := false
var refresh_thread: Thread
var refresh_mutex := Mutex.new()
var refresh_payload_ready := false
var refresh_payload: Dictionary = {}
var refresh_in_progress := false
var active_refresh_snapshot: Dictionary = {}
var pending_refresh := false
var pending_refresh_snapshot: Dictionary = {}
var pending_refresh_context := ""
var pending_refresh_status := ""
var metrics_poll_enabled := false
var metric_history := {
	"cpu": [],
	"memory": [],
	"pods": [],
	"events": [],
}


func _ready() -> void:
	DisplayServer.window_set_min_size(Vector2i(960, 600))
	theme = _build_theme()
	_cache_ui_refs()
	_connect_static_controls()
	var boot_snapshot: Dictionary = client.make_snapshot()
	_set_status("Loading demo cluster..." if bool(boot_snapshot.get("force_demo_mode", false)) else "Fetching kubeconfig clusters...")
	auto_refresh_timer = Timer.new()
	auto_refresh_timer.wait_time = 8.0
	auto_refresh_timer.autostart = true
	auto_refresh_timer.timeout.connect(_refresh_dashboard)
	add_child(auto_refresh_timer)
	call_deferred("_refresh_dashboard")


func _exit_tree() -> void:
	_stop_port_forward()
	if refresh_thread:
		refresh_thread.wait_to_finish()
		refresh_thread = null


func _draw() -> void:
	var rect := get_rect()
	draw_rect(rect, BG_TOP, true)
	var bands := 6
	for index in range(bands):
		var height := rect.size.y / float(bands)
		var band_rect := Rect2(0.0, height * index, rect.size.x, height)
		var blend := float(index) / float(max(bands - 1, 1))
		var band_color := BG_TOP.lerp(BG_BOTTOM, blend)
		band_color.a = 0.86
		draw_rect(band_rect, band_color, true)
	draw_rect(Rect2(0.0, 0.0, rect.size.x, 82.0), Color(0.03, 0.08, 0.13, 0.72), true)
	draw_rect(Rect2(0.0, rect.size.y - 110.0, rect.size.x, 110.0), Color(0.01, 0.03, 0.06, 0.22), true)
	_draw_shell_frame(rect)
	_draw_top_rulers(rect)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _process(_delta: float) -> void:
	if not refresh_in_progress:
		set_process(false)
		return
	var payload := _take_refresh_payload()
	if payload.is_empty():
		return
	_finish_refresh(payload)


func _unhandled_input(event: InputEvent) -> void:
	if ui.is_empty() or not ui.has("import_error_popup") or not ui.import_error_popup.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		if (key_event.ctrl_pressed or key_event.meta_pressed) and key_event.keycode == KEY_C:
			_copy_import_error_to_clipboard()
			get_viewport().set_input_as_handled()
		elif key_event.keycode == KEY_ESCAPE:
			_hide_import_error()
			get_viewport().set_input_as_handled()


func _cache_ui_refs() -> void:
	ui.summary_context = %SummaryContext
	ui.summary_meta = %SummaryMeta
	ui.summary_pods = %SummaryPods
	ui.summary_nodes = %SummaryNodes
	ui.summary_cpu = %SummaryCPU
	ui.summary_memory = %SummaryMemory
	ui.connection_mode = %ConnectionMode
	ui.status_message = %StatusMessage
	ui.status_detail = %StatusDetail
	ui.refresh_button = %RefreshButton
	ui.context_buttons = %ContextsButtons
	ui.namespace_option = %NamespaceOption
	ui.mode_hint = %ModeHint
	ui.import_kubeconfig_button = %ImportKubeconfigButton
	ui.use_demo_button = %UseDemoButton
	ui.kubeconfig_dialog = %KubeconfigDialog
	ui.import_error_popup = %ImportErrorPopup
	ui.import_error_message = %ImportErrorMessage
	ui.import_error_copy_button = %ImportErrorCopyButton
	ui.import_error_dismiss_button = %ImportErrorDismissButton
	ui.import_error_use_demo_button = %ImportErrorUseDemoButton
	ui.telemetry_summary = %TelemetrySummary
	ui.telemetry_spark = %TelemetrySpark
	ui.telemetry_footer = %TelemetryFooter
	ui.overview_title = %OverviewTitle
	ui.overview_status = %OverviewStatus
	ui.cluster_map = %ClusterMap
	ui.event_stream = %EventStream
	ui.terminal_title = %TerminalTitle
	ui.terminal_output = %TerminalOutput
	ui.detail_title = %DetailTitle
	ui.detail_subtitle = %DetailSubtitle
	ui.detail_tabs = %DetailTabs
	ui.detail_overview = %Overview
	ui.detail_logs = %Logs
	ui.detail_events = %Events
	ui.detail_metrics = %Metrics
	ui.exec_button = %ExecButton
	ui.yaml_button = %YamlButton
	ui.port_button = %PortButton
	ui.detail_footer = %DetailFooter
	ui.namespace_option = %NamespaceOption
	ui.resource_buttons = {
		"Applications": %NavApplications,
		"Pods": %NavPods,
		"Deployments": %NavDeployments,
		"Nodes": %NavNodes,
		"ConfigMaps": %NavConfigMaps,
		"Network": %NavNetwork,
		"Storage": %NavStorage,
		"Helm": %NavHelm,
		"Access": %NavAccess,
	}
	ui.metric_cards = {
		"cpu": %MetricCPU,
		"memory": %MetricMemory,
		"pods": %MetricPods,
		"events": %MetricEvents,
	}
	ui.metrics_mode_label = %MetricsModeLabel
	ui.metrics_toggle_button = %MetricsToggleButton


func _connect_static_controls() -> void:
	ui.refresh_button.pressed.connect(_refresh_dashboard)
	ui.namespace_option.item_selected.connect(_on_namespace_selected)
	ui.import_kubeconfig_button.pressed.connect(_on_import_kubeconfig_pressed)
	ui.use_demo_button.pressed.connect(_on_use_demo_pressed)
	ui.kubeconfig_dialog.file_selected.connect(_on_kubeconfig_file_selected)
	ui.import_error_copy_button.pressed.connect(_copy_import_error_to_clipboard)
	ui.import_error_dismiss_button.pressed.connect(_hide_import_error)
	ui.import_error_use_demo_button.pressed.connect(_on_import_error_use_demo_pressed)
	ui.cluster_map.group_selected.connect(_on_group_selected)
	ui.detail_tabs.tab_changed.connect(_on_detail_tab_changed)
	ui.exec_button.pressed.connect(_on_exec_shell_pressed)
	ui.yaml_button.pressed.connect(_on_view_yaml_pressed)
	ui.port_button.pressed.connect(_on_port_forward_pressed)
	ui.metrics_toggle_button.pressed.connect(_on_metrics_toggle_pressed)
	ui.telemetry_spark.set_line_color(ACCENT)
	for resource_name in ui.resource_buttons.keys():
		var button: BaseButton = ui.resource_buttons[resource_name]
		button.button_group = resource_button_group
		button.button_pressed = resource_name == selected_resource
		button.pressed.connect(_on_resource_selected.bind(resource_name))


func _draw_shell_frame(rect: Rect2) -> void:
	var frame := _bevel_points(rect.grow(-5.0), 20.0)
	_draw_polyline(frame, Color(BORDER.r, BORDER.g, BORDER.b, 0.34), 1.5)
	var inner := _bevel_points(rect.grow(-11.0), 14.0)
	_draw_polyline(inner, Color(BORDER_SOFT.r, BORDER_SOFT.g, BORDER_SOFT.b, 0.2), 1.0)


func _draw_top_rulers(rect: Rect2) -> void:
	var y := 18.0
	var start_x := 300.0
	var end_x := rect.size.x - 112.0
	draw_line(Vector2(start_x, y), Vector2(end_x, y), Color(BORDER_SOFT.r, BORDER_SOFT.g, BORDER_SOFT.b, 0.28), 1.0)
	draw_line(Vector2(start_x, y), Vector2(start_x + 136.0, y), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.75), 2.0)
	_draw_window_controls(rect)


func _draw_window_controls(rect: Rect2) -> void:
	var base_x := rect.size.x - 104.0
	var y := 18.0
	draw_line(Vector2(base_x, y), Vector2(base_x + 10.0, y), Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.88), 2.0)
	draw_rect(Rect2(Vector2(base_x + 28.0, y - 5.0), Vector2(10.0, 10.0)), Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.08), false, 1.5)
	draw_rect(Rect2(Vector2(base_x + 54.0, y - 7.0), Vector2(12.0, 12.0)), Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.08), false, 1.5)


func _bevel_points(rect: Rect2, cut: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(rect.position.x + cut, rect.position.y),
		Vector2(rect.end.x - cut, rect.position.y),
		Vector2(rect.end.x, rect.position.y + cut),
		Vector2(rect.end.x, rect.end.y - cut),
		Vector2(rect.end.x - cut, rect.end.y),
		Vector2(rect.position.x + cut, rect.end.y),
		Vector2(rect.position.x, rect.end.y - cut),
		Vector2(rect.position.x, rect.position.y + cut),
	])


func _draw_polyline(points: PackedVector2Array, color: Color, width: float, close: bool = true) -> void:
	var line := PackedVector2Array(points)
	if close:
		line.append(points[0])
	draw_polyline(line, color, width, true)


func _refresh_dashboard() -> void:
	_request_refresh(selected_context, _default_refresh_status())


func _request_refresh(context_name: String, status_message: String) -> void:
	var snapshot: Dictionary = client.make_snapshot()
	snapshot["focus_domain"] = selected_resource
	snapshot["metrics_enabled"] = metrics_poll_enabled
	if refresh_in_progress:
		_queue_refresh(snapshot, context_name, status_message)
		return
	_start_refresh(snapshot, context_name, status_message)


func _start_refresh(snapshot: Dictionary, context_name: String, status_message: String) -> void:
	active_refresh_snapshot = snapshot.duplicate(true)
	refresh_in_progress = true
	refresh_payload_ready = false
	refresh_payload.clear()
	_set_refresh_ui_busy(true)
	_set_status(status_message)
	refresh_thread = Thread.new()
	var start_error := refresh_thread.start(_refresh_worker.bind(active_refresh_snapshot.duplicate(true), context_name))
	if start_error != OK:
		refresh_in_progress = false
		refresh_thread = null
		_set_refresh_ui_busy(false)
		_set_status("Unable to start background refresh.")
		return
	set_process(true)


func _queue_refresh(snapshot: Dictionary, context_name: String, status_message: String) -> void:
	var normalized_status := status_message if not status_message.is_empty() else "Refreshing cluster state..."
	if pending_refresh and _refresh_request_matches(snapshot, context_name, pending_refresh_snapshot, pending_refresh_context):
		return
	pending_refresh = true
	pending_refresh_snapshot = snapshot.duplicate(true)
	pending_refresh_context = context_name
	pending_refresh_status = normalized_status
	_set_status("Refresh queued...")


func _refresh_worker(snapshot: Dictionary, context_name: String) -> void:
	var worker_client: Variant = KubeClient.new()
	worker_client.apply_snapshot(snapshot)
	var result: Dictionary = worker_client.refresh(
		context_name,
		String(snapshot.get("focus_domain", "Applications")),
		bool(snapshot.get("metrics_enabled", false))
	)
	refresh_mutex.lock()
	refresh_payload = {
		"snapshot": snapshot,
		"context": context_name,
		"result": result,
	}
	refresh_payload_ready = true
	refresh_mutex.unlock()


func _take_refresh_payload() -> Dictionary:
	refresh_mutex.lock()
	var payload := {}
	if refresh_payload_ready:
		payload = refresh_payload.duplicate(true)
		refresh_payload_ready = false
		refresh_payload.clear()
	refresh_mutex.unlock()
	return payload


func _finish_refresh(payload: Dictionary) -> void:
	if refresh_thread:
		refresh_thread.wait_to_finish()
		refresh_thread = null
	var worker_snapshot: Dictionary = payload.get("snapshot", {})
	var worker_context := String(payload.get("context", ""))
	var result: Dictionary = payload.get("result", {})
	var skip_apply := false
	if pending_refresh:
		if _refresh_request_matches(worker_snapshot, worker_context, pending_refresh_snapshot, pending_refresh_context):
			_clear_pending_refresh()
		else:
			skip_apply = true
	if not skip_apply:
		_apply_dashboard_state(result)
	refresh_in_progress = false
	active_refresh_snapshot.clear()
	if pending_refresh:
		var next_snapshot := pending_refresh_snapshot.duplicate(true)
		var next_context := pending_refresh_context
		var next_status := pending_refresh_status
		_clear_pending_refresh()
		_start_refresh(next_snapshot, next_context, next_status)
		return
	_set_refresh_ui_busy(false)
	set_process(false)


func _refresh_request_matches(left_snapshot: Dictionary, left_context: String, right_snapshot: Dictionary, right_context: String) -> bool:
	return (
		left_context == right_context
		and String(left_snapshot.get("kubeconfig_path", "")) == String(right_snapshot.get("kubeconfig_path", ""))
		and bool(left_snapshot.get("force_demo_mode", false)) == bool(right_snapshot.get("force_demo_mode", false))
		and String(left_snapshot.get("focus_domain", "Applications")) == String(right_snapshot.get("focus_domain", "Applications"))
		and bool(left_snapshot.get("metrics_enabled", false)) == bool(right_snapshot.get("metrics_enabled", false))
	)


func _clear_pending_refresh() -> void:
	pending_refresh = false
	pending_refresh_snapshot.clear()
	pending_refresh_context = ""
	pending_refresh_status = ""


func _set_refresh_ui_busy(is_busy: bool) -> void:
	ui.refresh_button.disabled = is_busy
	ui.metrics_toggle_button.disabled = is_busy
	_refresh_status_display()


func _apply_dashboard_state(new_state: Dictionary) -> void:
	dashboard_state = new_state
	var contexts: Array = dashboard_state.get("contexts", [])
	if contexts.is_empty():
		selected_context = ""
	else:
		if selected_context.is_empty() or not contexts.has(selected_context):
			selected_context = String(dashboard_state.get("current_context", contexts[0]))
	_sync_namespace_selection()
	_sync_group_selection()
	_rebuild_context_buttons()
	_rebuild_namespace_options()
	_update_summary()
	_update_cluster_map()
	_update_event_stream()
	_update_metrics()
	_update_metrics_toggle_ui()
	_update_detail_panel()
	_update_terminal_hint()
	_update_mode_labels()
	if pending_import_validation:
		pending_import_validation = false
		if String(dashboard_state.get("mode", "demo")) != "live":
			var refresh_error := String(dashboard_state.get("message", "Unable to use the imported kubeconfig.")).strip_edges()
			if not refresh_error.is_empty():
				_show_import_error(refresh_error)
	var refresh_message: String = String(dashboard_state.get("message", "")).strip_edges()
	var refresh_timestamp: String = String(dashboard_state.get("timestamp", "just now"))
	if refresh_message.is_empty():
		_set_status("Last refresh %s" % refresh_timestamp)
	else:
		_set_status("%s | %s" % [refresh_message, refresh_timestamp])


func _sync_namespace_selection() -> void:
	var namespaces: Array = dashboard_state.get("namespaces", [])
	if selected_namespace != ALL_NAMESPACES and not namespaces.has(selected_namespace):
		selected_namespace = ALL_NAMESPACES


func _sync_group_selection() -> void:
	var groups := _filtered_groups()
	if groups.is_empty():
		selected_group_key = ""
		return
	for group in groups:
		if String(group.get("key", "")) == selected_group_key:
			return
	selected_group_key = String(groups[0].get("key", ""))


func _rebuild_context_buttons() -> void:
	for child in ui.context_buttons.get_children():
		child.queue_free()
	for context_name in dashboard_state.get("contexts", []):
		var context_button = NAV_BUTTON_SCENE.instantiate()
		context_button.label_text = _nav_button_text(String(context_name))
		context_button.button_group = context_button_group
		context_button.button_pressed = String(context_name) == selected_context
		context_button.pressed.connect(_on_context_selected.bind(String(context_name)))
		ui.context_buttons.add_child(context_button)


func _rebuild_namespace_options() -> void:
	ui.namespace_option.clear()
	ui.namespace_option.add_item(ALL_NAMESPACES)
	var index := 0
	for namespace_name in dashboard_state.get("namespaces", []):
		ui.namespace_option.add_item(String(namespace_name))
	for item_index in range(ui.namespace_option.item_count):
		if ui.namespace_option.get_item_text(item_index) == selected_namespace:
			index = item_index
			break
	ui.namespace_option.select(index)


func _update_summary() -> void:
	var summary: Dictionary = dashboard_state.get("summary", {})
	var mode_name := String(dashboard_state.get("mode", "demo"))
	var kubeconfig_path := String(dashboard_state.get("kubeconfig_path", ""))
	var full_context := selected_context if not selected_context.is_empty() else "No Context"
	var context_badge := _compact_ui_text(full_context.to_upper(), 24)
	var summary_context := "CTX %s | %s" % [context_badge, "LIVE" if mode_name == "live" else "DEMO"]
	ui.summary_context.text = summary_context
	ui.summary_context.tooltip_text = "%s | %s" % [full_context, "Live cluster" if mode_name == "live" else "Demo cluster"]
	var sync_source := "KUBECTL" if mode_name == "live" else "DEMO"
	var kubeconfig_name := _display_kubeconfig_name(kubeconfig_path)
	var summary_meta := "SYNC %s | NS %s" % [
		sync_source,
		_compact_ui_text(selected_namespace.to_upper(), 18),
	]
	if kubeconfig_name != "DEFAULT":
		summary_meta += " | CFG %s" % _compact_ui_text(kubeconfig_name.to_upper(), 16)
	ui.summary_meta.text = summary_meta
	ui.summary_meta.tooltip_text = "Sync via %s | Namespace scope %s | Kubeconfig %s" % [
		"kubectl" if mode_name == "live" else "demo fixtures",
		selected_namespace,
		kubeconfig_path if not kubeconfig_path.is_empty() else "default",
	]
	ui.summary_pods.text = "PODS %d" % _filtered_pods().size()
	ui.summary_nodes.text = "NODES %d" % dashboard_state.get("nodes", []).size()
	if _metrics_available_for_display():
		ui.summary_cpu.text = "CPU %.0f%%" % float(summary.get("cpu_percent", 0.0))
		ui.summary_memory.text = "MEM %.0f%%" % float(summary.get("memory_percent", 0.0))
	else:
		ui.summary_cpu.text = "CPU OFF"
		ui.summary_memory.text = "MEM OFF"
	var overview_context := selected_context.to_upper() if not selected_context.is_empty() else "NO CONTEXT"
	ui.overview_title.text = "CLUSTER OVERVIEW // %s" % overview_context
	ui.overview_status.text = "%d %s VISIBLE  |  %d EVENTS IN SCOPE" % [
		_filtered_groups().size(),
		selected_resource.to_upper(),
		_filtered_events().size(),
	]


func _update_cluster_map() -> void:
	ui.cluster_map.set_dashboard_data(_filtered_groups(), dashboard_state.get("nodes", []), selected_group_key, selected_resource)


func _update_event_stream() -> void:
	var lines := []
	for event in _filtered_events().slice(0, min(_filtered_events().size(), 10)):
		lines.append("%s  [%s]  %s  %s" % [
			_shorten_time(String(event.get("time", ""))),
			String(event.get("type", "Normal")).to_upper(),
			String(event.get("reason", "")),
			String(event.get("message", "")),
		])
	ui.event_stream.text = "\n".join(lines) if not lines.is_empty() else "No events in current scope."


func _update_metrics() -> void:
	var summary: Dictionary = dashboard_state.get("summary", {})
	var metrics_available := _metrics_available_for_display()
	if metrics_available:
		_append_metric("cpu", float(summary.get("cpu_percent", 0.0)))
		_append_metric("memory", float(summary.get("memory_percent", 0.0)))
	else:
		metric_history.cpu = []
		metric_history.memory = []
	var pod_readiness := 100.0
	if _filtered_pods().size() > 0:
		var ready := 0
		for pod in _filtered_pods():
			if int(pod.get("ready_containers", 0)) >= int(pod.get("total_containers", 1)):
				ready += 1
		pod_readiness = float(ready) / float(_filtered_pods().size()) * 100.0
	_append_metric("pods", pod_readiness)
	_append_metric("events", float(_filtered_events().size()))
	ui.metric_cards.cpu.set_value_text(_metric_label("cpu") if metrics_available else "polling disabled")
	ui.metric_cards.cpu.set_points(metric_history.cpu)
	ui.metric_cards.memory.set_value_text(_metric_label("memory") if metrics_available else "polling disabled")
	ui.metric_cards.memory.set_points(metric_history.memory)
	ui.metric_cards.pods.set_value_text(_metric_label("pods"))
	ui.metric_cards.pods.set_points(metric_history.pods)
	ui.metric_cards.events.set_value_text(_metric_label("events"))
	ui.metric_cards.events.set_points(metric_history.events)
	ui.telemetry_spark.set_points(metric_history.cpu)


func _update_detail_panel() -> void:
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty():
		ui.detail_title.text = "No %s selected" % selected_resource.to_lower()
		ui.detail_subtitle.text = "Choose a %s item from the topology to inspect it." % selected_resource.to_lower()
		ui.detail_overview.text = "No %s selected." % selected_resource.to_lower()
		ui.detail_logs.text = ""
		ui.detail_events.text = ""
		ui.detail_metrics.text = ""
		ui.detail_footer.text = "Select a resource or change namespace scope."
		_update_detail_actions({})
		return
	ui.detail_title.text = String(item.get("name", "resource"))
	ui.detail_subtitle.text = String(item.get("map_subtitle", "%s  |  %s" % [String(item.get("namespace", "cluster")), String(item.get("kind", "Resource"))]))
	ui.detail_overview.text = _build_overview_text(item, pod)
	ui.detail_events.text = _build_selected_events_text()
	ui.detail_metrics.text = _build_metrics_text(item, pod)
	ui.detail_footer.text = String(item.get("detail_footer", "No additional resource details."))
	_update_detail_actions(item)


func _update_terminal_hint() -> void:
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty():
		ui.terminal_title.text = "No active command"
		ui.terminal_output.text = "Select a resource to prepare kubectl actions."
		return
	var action_lines := []
	if bool(item.get("supports_exec", false)) and not pod.is_empty():
		var exec_args: PackedStringArray = client.build_exec_args(selected_context, String(item.get("namespace", "default")), String(pod.get("name", "")))
		ui.terminal_title.text = "user@%s:~$ kubectl ..." % (selected_context if not selected_context.is_empty() else "cluster")
		action_lines.append("- Exec shell")
		if bool(item.get("supports_yaml", false)):
			action_lines.append("- View YAML")
		if bool(item.get("supports_port_forward", false)):
			action_lines.append("- Port-forward resource")
		if bool(item.get("supports_logs", false)):
			action_lines.append("- Tail logs via Inspector > Logs")
		ui.terminal_output.text = "$ %s\n\nReady actions:\n%s" % [
			_format_shell_command("kubectl", exec_args),
			"\n".join(action_lines),
		]
		return
	var get_args := _build_resource_get_args(item)
	ui.terminal_title.text = "user@%s:~$ kubectl ..." % (selected_context if not selected_context.is_empty() else "cluster")
	if bool(item.get("supports_yaml", false)):
		action_lines.append("- View YAML")
	if bool(item.get("supports_port_forward", false)):
		action_lines.append("- Port-forward resource")
	ui.terminal_output.text = "$ %s\n\nReady actions:\n%s" % [
		_format_shell_command("kubectl", get_args),
		"\n".join(action_lines) if not action_lines.is_empty() else "- Inspect resource details",
	]


func _update_mode_labels() -> void:
	var mode_name := String(dashboard_state.get("mode", "demo"))
	var kubeconfig_path := String(dashboard_state.get("kubeconfig_path", ""))
	var raw_message := String(dashboard_state.get("message", "")).strip_edges()
	var mode_hint_text := ""
	if not raw_message.is_empty():
		mode_hint_text = _compact_ui_text(raw_message.to_upper(), 34)
	if not kubeconfig_path.is_empty():
		var config_snippet := "CFG %s" % _compact_ui_text(_display_kubeconfig_name(kubeconfig_path).to_upper(), 10)
		mode_hint_text = config_snippet if mode_hint_text.is_empty() else _compact_ui_text("%s | %s" % [mode_hint_text, config_snippet], 40)
	ui.mode_hint.text = mode_hint_text
	ui.mode_hint.tooltip_text = raw_message if not raw_message.is_empty() else "No active status."
	if not kubeconfig_path.is_empty():
		ui.mode_hint.tooltip_text += "\nKubeconfig: %s" % kubeconfig_path
	ui.telemetry_summary.text = "%s | %dN | %dP" % [
		"LIVE" if mode_name == "live" else "DEMO",
		dashboard_state.get("nodes", []).size(),
		_filtered_pods().size(),
	]
	ui.telemetry_summary.tooltip_text = "%s mode active. %d nodes visible with %d pods in scope." % [
		"LIVE" if mode_name == "live" else "DEMO",
		dashboard_state.get("nodes", []).size(),
		_filtered_pods().size(),
	]
	var kubeconfig_name := _display_kubeconfig_name(kubeconfig_path)
	var context_name := selected_context if not selected_context.is_empty() else "No Context"
	ui.telemetry_footer.text = "NS %s | CTX %s\n%s | CFG %s" % [
		_compact_ui_text(selected_namespace.to_upper(), 12),
		_compact_ui_text(context_name.to_upper(), 12),
		_compact_ui_text(selected_resource.to_upper(), 8),
		_compact_ui_text(kubeconfig_name.to_upper(), 8),
	]
	ui.telemetry_footer.tooltip_text = "Namespace: %s\nContext: %s\nNavigation: %s\nKubeconfig: %s" % [
		selected_namespace,
		context_name,
		selected_resource,
		kubeconfig_path if not kubeconfig_path.is_empty() else "default",
	]
	ui.use_demo_button.visible = mode_name == "live" or not kubeconfig_path.is_empty()
	_refresh_status_display()


func _on_import_kubeconfig_pressed() -> void:
	_hide_import_error()
	var last_path: String = client.get_kubeconfig_path()
	if not last_path.is_empty():
		ui.kubeconfig_dialog.current_path = last_path
	else:
		var home_dir := OS.get_environment("HOME")
		if home_dir.is_empty():
			home_dir = OS.get_environment("USERPROFILE")
		if not home_dir.is_empty():
			ui.kubeconfig_dialog.current_dir = home_dir
	ui.kubeconfig_dialog.popup_centered_ratio(0.72)


func _on_kubeconfig_file_selected(kubeconfig_path: String) -> void:
	_set_status("Validating kubeconfig file...")
	var result: Dictionary = client.import_kubeconfig(kubeconfig_path)
	if not bool(result.get("ok", false)):
		var import_error := String(result.get("message", "Unable to import kubeconfig."))
		_set_status(import_error)
		_show_import_error(import_error)
		return
	selected_context = ""
	selected_namespace = ALL_NAMESPACES
	selected_group_key = ""
	pending_import_validation = true
	_set_status(String(result.get("message", "Kubeconfig imported.")))
	_request_refresh("", "Fetching kubeconfig clusters...")


func _on_use_demo_pressed() -> void:
	_hide_import_error()
	var result: Dictionary = client.use_demo_cluster()
	selected_context = ""
	selected_namespace = ALL_NAMESPACES
	selected_group_key = ""
	pending_import_validation = false
	_set_status(String(result.get("message", "Demo cluster enabled.")))
	_request_refresh("", "Loading demo cluster...")


func _on_import_error_use_demo_pressed() -> void:
	_on_use_demo_pressed()


func _on_metrics_toggle_pressed() -> void:
	metrics_poll_enabled = not metrics_poll_enabled
	_update_metrics_toggle_ui()
	_request_refresh(selected_context, "Live metrics %s." % ("enabled" if metrics_poll_enabled else "disabled"))


func _on_context_selected(context_name: String) -> void:
	selected_context = context_name
	_refresh_dashboard()


func _on_namespace_selected(index: int) -> void:
	selected_namespace = ui.namespace_option.get_item_text(index)
	_sync_group_selection()
	_update_summary()
	_update_cluster_map()
	_update_event_stream()
	_update_metrics()
	_update_detail_panel()
	_update_terminal_hint()
	_update_mode_labels()


func _on_resource_selected(resource_name: String) -> void:
	selected_resource = resource_name
	selected_group_key = ""
	_request_refresh(selected_context, "Loading %s resources..." % resource_name.to_lower())


func _on_group_selected(group_key: String) -> void:
	selected_group_key = group_key
	_update_cluster_map()
	_update_detail_panel()
	_update_terminal_hint()


func _on_detail_tab_changed(tab_index: int) -> void:
	if tab_index == 1 and bool(_selected_group().get("supports_logs", false)):
		_load_selected_logs()


func _load_selected_logs() -> void:
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty() or not bool(item.get("supports_logs", false)) or pod.is_empty():
		ui.detail_logs.text = "Logs are unavailable for this resource."
		return
	ui.detail_logs.text = client.fetch_pod_logs(
		selected_context,
		String(item.get("namespace", "default")),
		String(pod.get("name", "")),
		80
	)


func _on_view_yaml_pressed() -> void:
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty() or not bool(item.get("supports_yaml", false)):
		_set_status("Select a resource with YAML support first.")
		return
	var yaml := ""
	if bool(item.get("supports_logs", false)) and not pod.is_empty():
		yaml = client.fetch_pod_yaml(
			selected_context,
			String(item.get("namespace", "default")),
			String(pod.get("name", ""))
		)
	else:
		yaml = client.fetch_resource_yaml(
			selected_context,
			String(item.get("resource_type", "")),
			String(item.get("namespace", "")),
			String(item.get("name", "")),
			String(item.get("scope", "Namespaced"))
		)
	ui.terminal_title.text = "YAML dump"
	ui.terminal_output.text = yaml
	_set_status("Loaded YAML for %s." % String(item.get("name", "resource")))


func _on_port_forward_pressed() -> void:
	if port_forward_pid > 0:
		_stop_port_forward()
		_set_status("Stopped port-forward session.")
		return
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty() or not bool(item.get("supports_port_forward", false)):
		_set_status("Select a resource with a forwardable port first.")
		return
	var ports: Array = item.get("ports", [])
	var remote_port := int(ports[0]) if not ports.is_empty() else 8080
	var local_port := remote_port if remote_port >= 1024 else 8080
	var target_ref := String(item.get("port_forward_ref", ""))
	if target_ref.is_empty():
		if not pod.is_empty():
			target_ref = "pod/%s" % String(pod.get("name", ""))
		else:
			target_ref = String(item.get("name", ""))
	var args = client.build_port_forward_args(
		selected_context,
		String(item.get("namespace", "default")),
		target_ref,
		local_port,
		remote_port
	)
	var pid := OS.create_process("kubectl", args)
	if pid <= 0:
		_set_status("Unable to start kubectl port-forward.")
		return
	port_forward_pid = pid
	ui.port_button.label_text = "STOP FORWARD"
	ui.terminal_title.text = "Port-forward"
	ui.terminal_output.text = "$ %s\n\nForwarding http://127.0.0.1:%d to %s:%d" % [
		_format_shell_command("kubectl", args),
		local_port,
		target_ref,
		remote_port,
	]
	_set_status("Port-forward active on localhost:%d." % local_port)


func _stop_port_forward() -> void:
	if port_forward_pid <= 0:
		return
	var output: Array = []
	OS.execute("kill", PackedStringArray([str(port_forward_pid)]), output, true)
	port_forward_pid = 0
	ui.port_button.label_text = "PORT FORWARD"


func _on_exec_shell_pressed() -> void:
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty() or not bool(item.get("supports_exec", false)) or pod.is_empty():
		_set_status("Select a pod-backed resource before opening a shell.")
		return
	var command := _format_shell_command(
		"kubectl",
		client.build_exec_args(
			selected_context,
			String(item.get("namespace", "default")),
			String(pod.get("name", ""))
		)
	)
	if _launch_terminal(command):
		_set_status("Opened shell command in an external terminal.")
		return
	DisplayServer.clipboard_set(command)
	ui.terminal_title.text = "Exec command copied"
	ui.terminal_output.text = command
	_set_status("No terminal emulator detected. Command copied to clipboard.")


func _launch_terminal(command: String) -> bool:
	var shell_command := "%s; exec $SHELL" % command
	var candidates := [
		{"cmd": "x-terminal-emulator", "args": PackedStringArray(["-e", "sh", "-lc", shell_command])},
		{"cmd": "gnome-terminal", "args": PackedStringArray(["--", "sh", "-lc", shell_command])},
		{"cmd": "konsole", "args": PackedStringArray(["-e", "sh", "-lc", shell_command])},
		{"cmd": "xterm", "args": PackedStringArray(["-e", "sh", "-lc", shell_command])},
	]
	for candidate in candidates:
		var pid := OS.create_process(String(candidate.get("cmd", "")), candidate.get("args", PackedStringArray()))
		if pid > 0:
			return true
	return false


func _filtered_groups() -> Array:
	var groups: Array = _current_resource_items()
	if selected_namespace == ALL_NAMESPACES:
		return groups
	var filtered := []
	for group in groups:
		if String(group.get("scope", "Namespaced")) == "Cluster" or String(group.get("namespace", "")) == selected_namespace:
			filtered.append(group)
	return filtered


func _filtered_pods() -> Array:
	var pods: Array = dashboard_state.get("pods", [])
	if selected_namespace == ALL_NAMESPACES:
		return pods
	var filtered := []
	for pod in pods:
		if String(pod.get("namespace", "")) == selected_namespace:
			filtered.append(pod)
	return filtered


func _filtered_events() -> Array:
	var events: Array = dashboard_state.get("events", [])
	if selected_namespace == ALL_NAMESPACES:
		return events
	var filtered := []
	for event in events:
		if String(event.get("namespace", "")) == selected_namespace:
			filtered.append(event)
	return filtered


func _selected_group() -> Dictionary:
	for group in _filtered_groups():
		if String(group.get("key", "")) == selected_group_key:
			return group
	return {}


func _selected_pod() -> Dictionary:
	var item := _selected_group()
	if item.is_empty():
		return {}
	if String(item.get("kind", "")) == "Pod":
		for pod in _filtered_pods():
			if String(pod.get("namespace", "")) == String(item.get("namespace", "")) and String(pod.get("name", "")) == String(item.get("name", "")):
				return pod
	var pod_names: Array = item.get("pod_names", [])
	if pod_names.is_empty():
		return {}
	var candidate_name := String(pod_names[0])
	for pod in _filtered_pods():
		if String(pod.get("namespace", "")) == String(item.get("namespace", "")) and String(pod.get("name", "")) == candidate_name:
			return pod
	for pod in _filtered_pods():
		if String(pod.get("namespace", "")) == String(item.get("namespace", "")) and pod_names.has(pod.get("name", "")):
			return pod
	return {}


func _build_overview_text(group: Dictionary, pod: Dictionary) -> String:
	var overview_text := String(group.get("overview_text", "No overview available.")).strip_edges()
	if not pod.is_empty() and String(group.get("kind", "")) != "Pod":
		overview_text += "\n\nRepresentative pod: %s\nPod phase: %s\nNode: %s\nPod IP: %s" % [
			String(pod.get("name", "")),
			String(pod.get("phase", "Unknown")),
			String(pod.get("node_name", "")),
			String(pod.get("pod_ip", "")),
		]
	return overview_text


func _build_selected_events_text() -> String:
	var item := _selected_group()
	var pod := _selected_pod()
	if item.is_empty():
		return "No resource selected."
	var selected_names := {}
	selected_names[String(item.get("name", ""))] = true
	for pod_name in item.get("pod_names", []):
		selected_names[String(pod_name)] = true
	if not pod.is_empty():
		selected_names[String(pod.get("name", ""))] = true
	var lines := []
	for event in _filtered_events():
		var object_name := String(event.get("object_name", ""))
		if selected_names.has(object_name):
			lines.append("%s  %s  %s" % [
				_shorten_time(String(event.get("time", ""))),
				String(event.get("reason", "")),
				String(event.get("message", "")),
			])
	if lines.is_empty():
		lines.append("No resource-specific events in current scope.")
	return "\n".join(lines)


func _build_metrics_text(group: Dictionary, pod: Dictionary) -> String:
	if bool(group.get("requires_metrics_poll", false)) and not _metrics_available_for_display():
		return "Live CPU and memory polling is disabled.\nEnable metrics in the Metrics panel to populate resource usage."
	var metrics_text := String(group.get("metrics_text", "")).strip_edges()
	if metrics_text.is_empty():
		return "No metrics available for this resource."
	return metrics_text


func _append_metric(metric_name: String, value: float) -> void:
	var history: Array = metric_history[metric_name]
	history.append(value)
	while history.size() > 24:
		history.pop_front()
	metric_history[metric_name] = history


func _metric_label(metric_name: String) -> String:
	match metric_name:
		"cpu":
			return "%.0f%% avg" % (metric_history.cpu[-1] if not metric_history.cpu.is_empty() else 0.0)
		"memory":
			return "%.0f%% avg" % (metric_history.memory[-1] if not metric_history.memory.is_empty() else 0.0)
		"pods":
			return "%.0f%% ready" % (metric_history.pods[-1] if not metric_history.pods.is_empty() else 0.0)
		_:
			return "%d in scope" % int(metric_history.events[-1] if not metric_history.events.is_empty() else 0)


func _set_status(message: String) -> void:
	last_status_message = _normalize_status_text(message)
	_refresh_status_display()


func _default_refresh_status() -> String:
	var snapshot: Dictionary = client.make_snapshot()
	if dashboard_state.is_empty():
		return "Loading demo cluster..." if bool(snapshot.get("force_demo_mode", false)) else "Fetching kubeconfig clusters..."
	return "Refreshing %s view..." % selected_resource.to_lower()


func _current_resource_items() -> Array:
	var resource_catalog: Dictionary = dashboard_state.get("resource_catalog", {})
	if resource_catalog.has(selected_resource):
		return resource_catalog.get(selected_resource, [])
	if selected_resource == "Applications":
		if resource_catalog.has("Workloads"):
			return resource_catalog.get("Workloads", [])
		return dashboard_state.get("workload_groups", [])
	return []


func _update_detail_actions(item: Dictionary) -> void:
	var supports_logs := bool(item.get("supports_logs", false))
	var supports_yaml := bool(item.get("supports_yaml", false))
	var supports_exec := bool(item.get("supports_exec", false))
	var supports_port_forward := bool(item.get("supports_port_forward", false))
	ui.exec_button.disabled = not supports_exec
	ui.yaml_button.disabled = not supports_yaml
	ui.port_button.disabled = not supports_port_forward and port_forward_pid <= 0
	ui.port_button.label_text = "STOP FORWARD" if port_forward_pid > 0 else "PORT FORWARD"
	ui.detail_tabs.set_tab_disabled(1, not supports_logs)
	if not supports_logs:
		ui.detail_logs.text = "Logs are unavailable for this resource."
		if ui.detail_tabs.current_tab == 1:
			ui.detail_tabs.current_tab = 0


func _build_resource_get_args(item: Dictionary) -> PackedStringArray:
	var args := PackedStringArray([
		"get",
		String(item.get("resource_type", "")),
		String(item.get("name", "")),
	])
	if String(item.get("scope", "Namespaced")) != "Cluster" and not String(item.get("namespace", "")).is_empty():
		args.append("-n")
		args.append(String(item.get("namespace", "")))
	if not selected_context.is_empty():
		var full_args := PackedStringArray(["--context", selected_context])
		full_args.append_array(args)
		return full_args
	return args


func _refresh_status_display() -> void:
	if ui.is_empty() or not ui.has("status_message"):
		return
	var cleaned_message := last_status_message if not last_status_message.is_empty() else "Ready."
	var mode_name := String(dashboard_state.get("mode", "demo"))
	var context_name := selected_context if not selected_context.is_empty() else String(dashboard_state.get("current_context", "No Context"))
	ui.status_message.text = _compact_ui_text(cleaned_message.to_upper(), 120)
	ui.status_message.tooltip_text = cleaned_message
	ui.status_detail.text = "SYNC %s // %s // CTX %s // NS %s" % [
		"BUSY" if refresh_in_progress else "READY",
		"LIVE LINK" if mode_name == "live" else "DEMO LINK",
		_compact_ui_text(context_name.to_upper(), 20),
		_compact_ui_text(selected_namespace.to_upper(), 20),
	]
	ui.status_detail.tooltip_text = "Sync: %s\nMode: %s\nContext: %s\nNamespace: %s" % [
		"busy" if refresh_in_progress else "ready",
		"live" if mode_name == "live" else "demo",
		context_name,
		selected_namespace,
	]
	ui.connection_mode.text = "SYNC BUSY" if refresh_in_progress else ("LINK LIVE" if mode_name == "live" else "LINK DEMO")
	ui.connection_mode.tooltip_text = cleaned_message


func _normalize_status_text(message: String) -> String:
	return " ".join(message.strip_edges().split("\n", false)).replace("  ", " ").strip_edges()


func _compact_ui_text(text: String, max_chars: int) -> String:
	var cleaned := _normalize_status_text(text)
	if max_chars <= 0 or cleaned.length() <= max_chars:
		return cleaned
	if max_chars <= 3:
		return cleaned.left(max_chars)
	return "%s..." % cleaned.left(max_chars - 3)


func _display_kubeconfig_name(kubeconfig_path: String) -> String:
	if kubeconfig_path.is_empty():
		return "DEFAULT"
	return kubeconfig_path.get_file()


func _metrics_available_for_display() -> bool:
	var mode_name := String(dashboard_state.get("mode", "demo"))
	if mode_name != "live":
		return true
	return bool(dashboard_state.get("metrics_enabled", metrics_poll_enabled))


func _update_metrics_toggle_ui() -> void:
	var effective_enabled := bool(dashboard_state.get("metrics_enabled", metrics_poll_enabled)) if not dashboard_state.is_empty() else metrics_poll_enabled
	var mode_name := String(dashboard_state.get("mode", "demo"))
	if mode_name == "live":
		ui.metrics_mode_label.text = "LIVE METRICS POLL // %s" % ("ON" if effective_enabled else "OFF")
	else:
		ui.metrics_mode_label.text = "DEMO METRICS // SIMULATED"
	ui.metrics_toggle_button.label_text = "METRICS ON" if not effective_enabled else "METRICS OFF"


func _show_import_error(message: String) -> void:
	ui.import_error_message.text = _format_import_error_message(message)
	if import_error_tween:
		import_error_tween.kill()
	ui.import_error_popup.visible = true
	ui.import_error_popup.modulate.a = 0.0
	ui.import_error_message.grab_focus()
	import_error_tween = create_tween()
	import_error_tween.set_trans(Tween.TRANS_QUART)
	import_error_tween.set_ease(Tween.EASE_OUT)
	import_error_tween.tween_property(ui.import_error_popup, "modulate:a", 1.0, 0.16)


func _hide_import_error() -> void:
	if ui.is_empty() or not ui.has("import_error_popup") or not ui.import_error_popup.visible:
		return
	if import_error_tween:
		import_error_tween.kill()
	import_error_tween = create_tween()
	import_error_tween.set_trans(Tween.TRANS_QUART)
	import_error_tween.set_ease(Tween.EASE_IN)
	import_error_tween.tween_property(ui.import_error_popup, "modulate:a", 0.0, 0.12)
	import_error_tween.tween_callback(func():
		ui.import_error_popup.visible = false
	)


func _copy_import_error_to_clipboard() -> void:
	var selected_text := String(ui.import_error_message.get_selected_text()).strip_edges()
	var clipboard_text := selected_text
	if clipboard_text.is_empty():
		clipboard_text = String(ui.import_error_message.text).strip_edges()
	if clipboard_text.is_empty():
		return
	DisplayServer.clipboard_set(clipboard_text)
	_set_status("Import error copied to clipboard.")


func _format_import_error_message(message: String) -> String:
	var formatted := message.strip_edges()
	if formatted.contains(" error: "):
		formatted = formatted.replace(" error: ", "\n\nError: ")
	if formatted.contains("; "):
		formatted = formatted.replace("; ", ";\n")
	return formatted


func _format_ports(ports: Array) -> String:
	if ports.is_empty():
		return "n/a"
	var mapped := []
	for port in ports:
		mapped.append(str(port))
	return ", ".join(mapped)


func _format_status_counts(status_counts: Dictionary) -> String:
	var parts := []
	for key in status_counts.keys():
		parts.append("%s:%d" % [key, status_counts[key]])
	return ", ".join(parts) if not parts.is_empty() else "n/a"


func _shorten_time(raw_time: String) -> String:
	if raw_time.length() >= 16 and raw_time.contains("T"):
		return raw_time.split("T")[1].left(5)
	return raw_time


func _format_shell_command(command: String, args: PackedStringArray) -> String:
	var pieces := [command]
	for arg in args:
		pieces.append(_shell_quote(String(arg)))
	return " ".join(pieces)


func _shell_quote(value: String) -> String:
	if value.is_empty():
		return "''"
	if value.find(" ") == -1 and value.find("'") == -1:
		return value
	return "'%s'" % value.replace("'", "'\"'\"'")


func _nav_button_text(name: String) -> String:
	return name.to_upper()


func _build_theme() -> Theme:
	var built_theme := Theme.new()
	built_theme.set_color("font_color", "Label", TEXT)
	built_theme.set_color("font_color", "Button", TEXT)
	built_theme.set_color("font_pressed_color", "Button", TEXT)
	built_theme.set_color("font_hover_color", "Button", TEXT)
	built_theme.set_color("font_color", "OptionButton", TEXT)
	built_theme.set_color("font_hover_color", "OptionButton", TEXT)
	built_theme.set_color("font_pressed_color", "OptionButton", TEXT)
	built_theme.set_color("font_color", "TabBar", TEXT)
	built_theme.set_color("font_selected_color", "TabBar", TEXT)
	built_theme.set_color("font_unselected_color", "TabBar", TEXT_MUTED)
	built_theme.set_color("font_hovered_color", "TabBar", TEXT)
	built_theme.set_color("font_disabled_color", "TextEdit", TEXT_MUTED)
	built_theme.set_color("font_readonly_color", "TextEdit", TEXT)
	built_theme.set_color("font_color", "TextEdit", TEXT)
	built_theme.set_color("caret_color", "TextEdit", ACCENT)
	built_theme.set_color("background_color", "TextEdit", Color(0.05, 0.09, 0.14, 0.92))
	built_theme.set_font_size("font_size", "Button", 13)
	built_theme.set_font_size("font_size", "OptionButton", 13)
	built_theme.set_font_size("font_size", "TabBar", 12)
	built_theme.set_stylebox("panel", "PanelContainer", _panel_style())
	built_theme.set_stylebox("normal", "Button", _button_style(PANEL_BG_ALT, BORDER_SOFT))
	built_theme.set_stylebox("hover", "Button", _button_style(PANEL_BG_ALT.lightened(0.05), BORDER))
	built_theme.set_stylebox("pressed", "Button", _button_style(Color(0.11, 0.25, 0.36, 0.98), ACCENT_WARM))
	built_theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	built_theme.set_stylebox("normal", "OptionButton", _texture_stylebox("res://assets/ui/dropdown_idle.png", 22, 16.0, 44.0, 11.0, 11.0))
	built_theme.set_stylebox("hover", "OptionButton", _texture_stylebox("res://assets/ui/dropdown_hover.png", 22, 16.0, 44.0, 11.0, 11.0))
	built_theme.set_stylebox("pressed", "OptionButton", _texture_stylebox("res://assets/ui/dropdown_pressed.png", 22, 16.0, 44.0, 11.0, 11.0))
	built_theme.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	built_theme.set_stylebox("panel", "TextEdit", _editor_style())
	built_theme.set_stylebox("tab_selected", "TabBar", _texture_stylebox("res://assets/ui/tab_selected.png", 16, 18.0, 18.0, 10.0, 10.0))
	built_theme.set_stylebox("tab_hovered", "TabBar", _texture_stylebox("res://assets/ui/tab_hover.png", 16, 18.0, 18.0, 10.0, 10.0))
	built_theme.set_stylebox("tab_unselected", "TabBar", _texture_stylebox("res://assets/ui/tab_idle.png", 16, 18.0, 18.0, 10.0, 10.0))
	built_theme.set_stylebox("tabbar_background", "TabContainer", StyleBoxEmpty.new())
	built_theme.set_stylebox("panel", "TabContainer", StyleBoxEmpty.new())
	built_theme.set_constant("side_margin", "Button", 14)
	built_theme.set_constant("h_separation", "TabBar", 6)
	built_theme.set_constant("outline_size", "Button", 0)
	return built_theme


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(0.0, 0.45, 0.7, 0.1)
	style.shadow_size = 6
	return style


func _button_style(fill: Color, border_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border_color
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(border_color.r, border_color.g, border_color.b, 0.12)
	style.shadow_size = 8
	style.content_margin_left = 18.0
	style.content_margin_right = 14.0
	style.content_margin_top = 11.0
	style.content_margin_bottom = 11.0
	return style


func _texture_stylebox(texture_path: String, margin: int, content_left: float, content_right: float, content_top: float, content_bottom: float) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = _load_theme_texture(texture_path)
	style.texture_margin_left = margin
	style.texture_margin_top = margin
	style.texture_margin_right = margin
	style.texture_margin_bottom = margin
	style.content_margin_left = content_left
	style.content_margin_right = content_right
	style.content_margin_top = content_top
	style.content_margin_bottom = content_bottom
	style.draw_center = true
	return style


func _editor_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.08, 0.12, 0.94)
	style.border_color = BORDER_SOFT
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_top = 10.0
	style.content_margin_right = 10.0
	style.content_margin_bottom = 10.0
	return style


func _load_theme_texture(texture_path: String) -> Texture2D:
	if _theme_texture_cache.has(texture_path):
		return _theme_texture_cache[texture_path]
	var texture := load(texture_path) as Texture2D
	if texture == null:
		push_warning("Unable to load theme texture: %s" % texture_path)
		return null
	_theme_texture_cache[texture_path] = texture
	return texture
