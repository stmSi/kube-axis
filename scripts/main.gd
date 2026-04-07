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

var client = KubeClient.new()
var dashboard_state: Dictionary = {}
var ui := {}
var context_button_group := ButtonGroup.new()
var resource_button_group := ButtonGroup.new()
var selected_context := ""
var selected_namespace := ALL_NAMESPACES
var selected_resource := "Workloads"
var selected_group_key := ""
var port_forward_pid := 0
var auto_refresh_timer: Timer
var metric_history := {
	"cpu": [],
	"memory": [],
	"pods": [],
	"events": [],
}


func _ready() -> void:
	DisplayServer.window_set_min_size(Vector2i(1180, 680))
	theme = _build_theme()
	_cache_ui_refs()
	_connect_static_controls()
	_set_status("Initializing dashboard...")
	auto_refresh_timer = Timer.new()
	auto_refresh_timer.wait_time = 8.0
	auto_refresh_timer.autostart = true
	auto_refresh_timer.timeout.connect(_refresh_dashboard)
	add_child(auto_refresh_timer)
	call_deferred("_refresh_dashboard")


func _exit_tree() -> void:
	_stop_port_forward()


func _draw() -> void:
	var rect := get_rect()
	draw_rect(rect, BG_TOP, true)
	var bands := 8
	for index in range(bands):
		var height := rect.size.y / float(bands)
		var band_rect := Rect2(0.0, height * index, rect.size.x, height)
		var blend := float(index) / float(max(bands - 1, 1))
		var band_color := BG_TOP.lerp(BG_BOTTOM, blend)
		band_color.a = 0.7
		draw_rect(band_rect, band_color, true)
	var x := 0.0
	while x < rect.size.x:
		draw_line(Vector2(x, 0.0), Vector2(x, rect.size.y), Color(0.12, 0.24, 0.3, 0.08), 1.0)
		x += 44.0
	var y := 0.0
	while y < rect.size.y:
		draw_line(Vector2(0.0, y), Vector2(rect.size.x, y), Color(0.12, 0.24, 0.3, 0.06), 1.0)
		y += 44.0
	_draw_shell_frame(rect)
	_draw_top_rulers(rect)
	_draw_corner_energy(rect)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _cache_ui_refs() -> void:
	ui.summary_context = %SummaryContext
	ui.summary_meta = %SummaryMeta
	ui.summary_pods = %SummaryPods
	ui.summary_nodes = %SummaryNodes
	ui.summary_cpu = %SummaryCPU
	ui.summary_memory = %SummaryMemory
	ui.connection_mode = %ConnectionMode
	ui.refresh_button = %RefreshButton
	ui.context_buttons = %ContextsButtons
	ui.namespace_option = %NamespaceOption
	ui.mode_hint = %ModeHint
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
		"Workloads": %NavWorkloads,
		"Nodes": %NavNodes,
		"Events": %NavEvents,
		"Logs": %NavLogs,
		"Metrics": %NavMetrics,
		"Terminal": %NavTerminal,
	}
	ui.metric_cards = {
		"cpu": %MetricCPU,
		"memory": %MetricMemory,
		"pods": %MetricPods,
		"events": %MetricEvents,
	}


func _connect_static_controls() -> void:
	ui.refresh_button.pressed.connect(_refresh_dashboard)
	ui.namespace_option.item_selected.connect(_on_namespace_selected)
	ui.cluster_map.group_selected.connect(_on_group_selected)
	ui.detail_tabs.tab_changed.connect(_on_detail_tab_changed)
	ui.exec_button.pressed.connect(_on_exec_shell_pressed)
	ui.yaml_button.pressed.connect(_on_view_yaml_pressed)
	ui.port_button.pressed.connect(_on_port_forward_pressed)
	ui.telemetry_spark.set_line_color(ACCENT)
	for resource_name in ui.resource_buttons.keys():
		var button: BaseButton = ui.resource_buttons[resource_name]
		button.button_group = resource_button_group
		button.button_pressed = resource_name == selected_resource
		button.pressed.connect(_on_resource_selected.bind(resource_name))


func _draw_shell_frame(rect: Rect2) -> void:
	var frame := _bevel_points(rect.grow(-4.0), 26.0)
	_draw_polyline(frame, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.12), 8.0)
	_draw_polyline(frame, Color(BORDER.r, BORDER.g, BORDER.b, 0.92), 2.0)
	var inner := _bevel_points(rect.grow(-12.0), 18.0)
	_draw_polyline(inner, Color(BORDER_SOFT.r, BORDER_SOFT.g, BORDER_SOFT.b, 0.75), 1.0)


func _draw_top_rulers(rect: Rect2) -> void:
	var y := 18.0
	var start_x := 340.0
	var end_x := rect.size.x - 168.0
	draw_line(Vector2(start_x, y), Vector2(end_x, y), Color(BORDER_SOFT.r, BORDER_SOFT.g, BORDER_SOFT.b, 0.55), 1.0)
	draw_line(Vector2(start_x, y), Vector2(start_x + 120.0, y), ACCENT, 2.0)
	draw_line(Vector2(end_x - 160.0, y), Vector2(end_x, y), Color(ACCENT_WARM.r, ACCENT_WARM.g, ACCENT_WARM.b, 0.95), 2.0)
	draw_line(Vector2(start_x + 70.0, y + 8.0), Vector2(end_x - 90.0, y + 8.0), Color(BORDER_SOFT.r, BORDER_SOFT.g, BORDER_SOFT.b, 0.22), 1.0)
	var notch := PackedVector2Array([
		Vector2(284.0, 12.0),
		Vector2(308.0, 12.0),
		Vector2(324.0, 28.0),
		Vector2(300.0, 28.0),
	])
	draw_colored_polygon(notch, Color(0.12, 0.2, 0.29, 0.9))
	_draw_polyline(notch, Color(BORDER_SOFT.r, BORDER_SOFT.g, BORDER_SOFT.b, 0.85), 1.0, false)
	_draw_window_controls(rect)


func _draw_window_controls(rect: Rect2) -> void:
	var base_x := rect.size.x - 108.0
	var y := 18.0
	draw_line(Vector2(base_x, y), Vector2(base_x + 12.0, y), TEXT_MUTED, 2.0)
	draw_rect(Rect2(Vector2(base_x + 28.0, y - 6.0), Vector2(12.0, 12.0)), Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.1), false, 2.0)
	draw_rect(Rect2(Vector2(base_x + 58.0, y - 8.0), Vector2(14.0, 14.0)), Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.1), false, 2.0)


func _draw_corner_energy(rect: Rect2) -> void:
	draw_line(Vector2(18.0, rect.size.y - 86.0), Vector2(18.0, rect.size.y - 34.0), Color(ACCENT_WARM.r, ACCENT_WARM.g, ACCENT_WARM.b, 0.65), 2.0)
	draw_line(Vector2(rect.size.x - 18.0, rect.size.y * 0.33), Vector2(rect.size.x - 18.0, rect.size.y * 0.65), Color(ACCENT_WARM.r, ACCENT_WARM.g, ACCENT_WARM.b, 0.48), 2.0)
	draw_line(Vector2(rect.size.x - 30.0, rect.size.y * 0.5), Vector2(rect.size.x - 18.0, rect.size.y * 0.5), ACCENT_WARM, 2.0)


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
	_set_status("Refreshing cluster state...")
	dashboard_state = client.refresh(selected_context)
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
	_update_detail_panel()
	_update_terminal_hint()
	_update_mode_labels()
	_set_status("Last refresh %s" % dashboard_state.get("timestamp", "just now"))


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
	ui.summary_context.text = "%s  |  %s" % [(selected_context if not selected_context.is_empty() else "No Context").to_upper(), "LIVE" if mode_name == "live" else "DEMO"]
	ui.summary_meta.text = "SYNC VIA %s  |  NAMESPACE SCOPE %s" % [
		"kubectl" if mode_name == "live" else "demo fixtures",
		selected_namespace.to_upper(),
	]
	ui.summary_pods.text = "PODS %d" % _filtered_pods().size()
	ui.summary_nodes.text = "NODES %d" % dashboard_state.get("nodes", []).size()
	ui.summary_cpu.text = "CPU %.0f%%" % float(summary.get("cpu_percent", 0.0))
	ui.summary_memory.text = "MEM %.0f%%" % float(summary.get("memory_percent", 0.0))
	ui.connection_mode.text = "MODE %s" % ("LIVE CLUSTER BRIDGE" if mode_name == "live" else "DEMO CLUSTER PLAYBACK")
	ui.overview_title.text = "CLUSTER OVERVIEW // %s" % selected_context.to_upper()
	ui.overview_status.text = "%d WORKLOADS ACTIVE  |  %d EVENTS VISIBLE" % [_filtered_groups().size(), _filtered_events().size()]


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
	_append_metric("cpu", float(summary.get("cpu_percent", 0.0)))
	_append_metric("memory", float(summary.get("memory_percent", 0.0)))
	var pod_readiness := 100.0
	if _filtered_pods().size() > 0:
		var ready := 0
		for pod in _filtered_pods():
			if int(pod.get("ready_containers", 0)) >= int(pod.get("total_containers", 1)):
				ready += 1
		pod_readiness = float(ready) / float(_filtered_pods().size()) * 100.0
	_append_metric("pods", pod_readiness)
	_append_metric("events", float(_filtered_events().size()))
	for metric_name in ui.metric_cards.keys():
		var card = ui.metric_cards[metric_name]
		card.set_value_text(_metric_label(metric_name))
		card.set_points(metric_history[metric_name])
	ui.telemetry_spark.set_points(metric_history.cpu)


func _update_detail_panel() -> void:
	var group := _selected_group()
	var pod := _selected_pod()
	if group.is_empty():
		ui.detail_title.text = "No workload selected"
		ui.detail_subtitle.text = "Choose a workload from the topology to inspect it."
		ui.detail_overview.text = "No workload selected."
		ui.detail_logs.text = ""
		ui.detail_events.text = ""
		ui.detail_metrics.text = ""
		ui.detail_footer.text = "Select a workload or change namespace scope."
		return
	ui.detail_title.text = String(pod.get("name", group.get("name", "workload")))
	ui.detail_subtitle.text = "%s  |  %s  |  %d/%d pods ready" % [
		String(group.get("namespace", "default")),
		String(group.get("owner_kind", "Workload")),
		int(group.get("ready_pods", 0)),
		int(group.get("pod_count", 0)),
	]
	ui.detail_overview.text = _build_overview_text(group, pod)
	ui.detail_events.text = _build_selected_events_text()
	ui.detail_metrics.text = _build_metrics_text(group, pod)
	ui.detail_footer.text = "Ports: %s  |  Nodes: %s" % [
		_format_ports(group.get("ports", [])),
		", ".join(group.get("nodes", [])),
	]
	_update_detail_tab_if_needed()


func _update_detail_tab_if_needed() -> void:
	match selected_resource:
		"Logs":
			ui.detail_tabs.current_tab = 1
		"Events":
			ui.detail_tabs.current_tab = 2
		"Metrics":
			ui.detail_tabs.current_tab = 3
		_:
			pass
	if ui.detail_tabs.current_tab == 1:
		_load_selected_logs()


func _update_terminal_hint() -> void:
	var pod := _selected_pod()
	var group := _selected_group()
	if pod.is_empty() or group.is_empty():
		ui.terminal_title.text = "No active command"
		ui.terminal_output.text = "Select a workload to prepare kubectl actions."
		return
	var namespace_name := String(group.get("namespace", "default"))
	var args = client.build_exec_args(selected_context, namespace_name, String(pod.get("name", "")))
	ui.terminal_title.text = "user@%s:~$ kubectl ..." % selected_context
	ui.terminal_output.text = "$ %s\n\nReady actions:\n- Exec shell\n- View YAML\n- Port-forward workload\n- Tail logs via Inspector > Logs" % _format_shell_command("kubectl", args)


func _update_mode_labels() -> void:
	var mode_name := String(dashboard_state.get("mode", "demo"))
	ui.mode_hint.text = String(dashboard_state.get("message", "")).to_upper()
	ui.telemetry_summary.text = "%s MODE ACTIVE. %d NODES VISIBLE WITH %d PODS IN SCOPE." % [
		"LIVE" if mode_name == "live" else "DEMO",
		dashboard_state.get("nodes", []).size(),
		_filtered_pods().size(),
	]
	ui.telemetry_footer.text = "SCOPE: %s\nCONTEXT: %s\nRESOURCE FOCUS: %s" % [selected_namespace.to_upper(), selected_context.to_upper(), selected_resource.to_upper()]


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
	if resource_name == "Terminal":
		ui.terminal_output.grab_focus()
	_set_status("Focused %s view." % resource_name)
	_update_cluster_map()
	_update_detail_panel()
	_update_mode_labels()


func _on_group_selected(group_key: String) -> void:
	selected_group_key = group_key
	_update_cluster_map()
	_update_detail_panel()
	_update_terminal_hint()


func _on_detail_tab_changed(tab_index: int) -> void:
	if tab_index == 1:
		_load_selected_logs()


func _load_selected_logs() -> void:
	var pod := _selected_pod()
	var group := _selected_group()
	if pod.is_empty() or group.is_empty():
		ui.detail_logs.text = "No workload selected."
		return
	ui.detail_logs.text = client.fetch_pod_logs(
		selected_context,
		String(group.get("namespace", "default")),
		String(pod.get("name", "")),
		80
	)


func _on_view_yaml_pressed() -> void:
	var pod := _selected_pod()
	var group := _selected_group()
	if pod.is_empty() or group.is_empty():
		_set_status("Select a workload before requesting YAML.")
		return
	var yaml = client.fetch_pod_yaml(
		selected_context,
		String(group.get("namespace", "default")),
		String(pod.get("name", ""))
	)
	ui.terminal_title.text = "YAML dump"
	ui.terminal_output.text = yaml
	_set_status("Loaded YAML for %s." % pod.get("name", "pod"))


func _on_port_forward_pressed() -> void:
	if port_forward_pid > 0:
		_stop_port_forward()
		_set_status("Stopped port-forward session.")
		return
	var pod := _selected_pod()
	var group := _selected_group()
	if pod.is_empty() or group.is_empty():
		_set_status("Select a workload before starting port-forward.")
		return
	var ports: Array = group.get("ports", [])
	var remote_port := int(ports[0]) if not ports.is_empty() else 8080
	var local_port := remote_port if remote_port >= 1024 else 8080
	var args = client.build_port_forward_args(
		selected_context,
		String(group.get("namespace", "default")),
		String(pod.get("name", "")),
		local_port,
		remote_port
	)
	var pid := OS.create_process("kubectl", args)
	if pid <= 0:
		_set_status("Unable to start kubectl port-forward.")
		return
	port_forward_pid = pid
	ui.port_button.text = "STOP FORWARD"
	ui.terminal_title.text = "Port-forward"
	ui.terminal_output.text = "$ %s\n\nForwarding http://127.0.0.1:%d to pod/%s:%d" % [
		_format_shell_command("kubectl", args),
		local_port,
		String(pod.get("name", "")),
		remote_port,
	]
	_set_status("Port-forward active on localhost:%d." % local_port)


func _stop_port_forward() -> void:
	if port_forward_pid <= 0:
		return
	var output: Array = []
	OS.execute("kill", PackedStringArray([str(port_forward_pid)]), output, true)
	port_forward_pid = 0
	ui.port_button.text = "PORT FORWARD"


func _on_exec_shell_pressed() -> void:
	var pod := _selected_pod()
	var group := _selected_group()
	if pod.is_empty() or group.is_empty():
		_set_status("Select a workload before opening a shell.")
		return
	var command := _format_shell_command(
		"kubectl",
		client.build_exec_args(
			selected_context,
			String(group.get("namespace", "default")),
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
	var groups: Array = dashboard_state.get("workload_groups", [])
	if selected_namespace == ALL_NAMESPACES:
		return groups
	var filtered := []
	for group in groups:
		if String(group.get("namespace", "")) == selected_namespace:
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
	var group := _selected_group()
	if group.is_empty():
		return {}
	var pod_names: Array = group.get("pods", [])
	if pod_names.is_empty():
		return {}
	var candidate_name := String(pod_names[0])
	for pod in _filtered_pods():
		if String(pod.get("name", "")) == candidate_name:
			return pod
	for pod in _filtered_pods():
		if String(pod.get("namespace", "")) == String(group.get("namespace", "")) and pod_names.has(pod.get("name", "")):
			return pod
	return {}


func _build_overview_text(group: Dictionary, pod: Dictionary) -> String:
	return "\n".join([
		"Workload: %s" % group.get("name", ""),
		"Namespace: %s" % group.get("namespace", ""),
		"Pods: %d ready / %d total" % [group.get("ready_pods", 0), group.get("pod_count", 0)],
		"Restarts: %d" % group.get("restart_count", 0),
		"Active pod: %s" % pod.get("name", ""),
		"Phase: %s" % pod.get("phase", "Unknown"),
		"Node: %s" % pod.get("node_name", ""),
		"Image: %s" % pod.get("image", ""),
		"IP: %s" % pod.get("pod_ip", ""),
		"Ports: %s" % _format_ports(group.get("ports", [])),
		"Nodes carrying workload: %s" % ", ".join(group.get("nodes", [])),
	])


func _build_selected_events_text() -> String:
	var group := _selected_group()
	var pod := _selected_pod()
	if group.is_empty():
		return "No workload selected."
	var lines := []
	for event in _filtered_events():
		var object_name := String(event.get("object_name", ""))
		if object_name == String(pod.get("name", "")) or object_name == String(group.get("name", "")):
			lines.append("%s  %s  %s" % [
				_shorten_time(String(event.get("time", ""))),
				String(event.get("reason", "")),
				String(event.get("message", "")),
			])
	if lines.is_empty():
		lines.append("No workload-specific events in current scope.")
	return "\n".join(lines)


func _build_metrics_text(group: Dictionary, pod: Dictionary) -> String:
	return "\n".join([
		"CPU usage: %.0f mCPU" % float(group.get("cpu_mcpu", 0.0)),
		"Memory usage: %.0f Mi" % float(group.get("memory_mib", 0.0)),
		"Pod CPU: %.0f mCPU" % float(pod.get("cpu_mcpu", 0.0)),
		"Pod memory: %.0f Mi" % float(pod.get("memory_mib", 0.0)),
		"Restart count: %d" % int(group.get("restart_count", 0)),
		"Ports exposed: %s" % _format_ports(group.get("ports", [])),
		"Status spread: %s" % _format_status_counts(group.get("status_counts", {})),
	])


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
	ui.connection_mode.text = message


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
	built_theme.set_stylebox("normal", "OptionButton", _button_style(PANEL_BG_ALT, BORDER_SOFT))
	built_theme.set_stylebox("hover", "OptionButton", _button_style(PANEL_BG_ALT.lightened(0.05), BORDER))
	built_theme.set_stylebox("pressed", "OptionButton", _button_style(Color(0.11, 0.25, 0.36, 0.98), ACCENT_WARM))
	built_theme.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	built_theme.set_stylebox("panel", "TextEdit", _editor_style())
	built_theme.set_stylebox("tab_selected", "TabBar", _button_style(Color(0.11, 0.23, 0.34, 1.0), ACCENT_WARM))
	built_theme.set_stylebox("tab_hovered", "TabBar", _button_style(Color(0.09, 0.19, 0.29, 1.0), BORDER))
	built_theme.set_stylebox("tab_unselected", "TabBar", _button_style(Color(0.06, 0.12, 0.18, 1.0), BORDER_SOFT))
	built_theme.set_stylebox("tabbar_background", "TabContainer", StyleBoxEmpty.new())
	built_theme.set_stylebox("panel", "TabContainer", StyleBoxEmpty.new())
	built_theme.set_constant("side_margin", "Button", 14)
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
