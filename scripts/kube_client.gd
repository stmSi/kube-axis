extends RefCounted

const DEMO_CONTEXTS := ["prod-cluster", "dev-cluster", "test-cluster"]
const DEMO_NAMESPACES := ["default", "payments", "platform", "monitoring"]
const SETTINGS_FILE := "user://kube_axis.cfg"
const SETTINGS_SECTION := "kube"
const SETTINGS_KEY_KUBECONFIG := "kubeconfig_path"

var _kubeconfig_path := ""


func _init() -> void:
	_load_saved_kubeconfig()


func import_kubeconfig(kubeconfig_path: String) -> Dictionary:
	var trimmed_path := kubeconfig_path.strip_edges()
	if trimmed_path.is_empty():
		return {
			"ok": false,
			"message": "No kubeconfig file selected.",
		}
	if not FileAccess.file_exists(trimmed_path):
		return {
			"ok": false,
			"message": "Selected kubeconfig file does not exist.",
		}
	_kubeconfig_path = trimmed_path
	OS.set_environment("KUBECONFIG", _kubeconfig_path)
	var save_error := _save_kubeconfig()
	if save_error != OK:
		return {
			"ok": true,
			"message": "Kubeconfig loaded for this session, but persistence failed.",
		}
	return {
		"ok": true,
		"message": "Kubeconfig loaded: %s" % _kubeconfig_path.get_file(),
	}


func get_kubeconfig_path() -> String:
	return _kubeconfig_path


func refresh(context_name: String = "") -> Dictionary:
	var version_result := _run_kubectl(PackedStringArray(["version", "--client", "--output=json"]))
	if not version_result.ok:
		return _build_demo_state("kubectl is unavailable. Running in demo mode.")

	var contexts_result := _run_kubectl(PackedStringArray(["config", "get-contexts", "-o", "name"]))
	var contexts := _lines(contexts_result.stdout)
	if contexts.is_empty():
		return _build_demo_state("No kube contexts found. Running in demo mode.")

	var current_context_result := _run_kubectl(PackedStringArray(["config", "current-context"]))
	var effective_context := context_name
	if effective_context.is_empty():
		effective_context = current_context_result.stdout.strip_edges()
	if effective_context.is_empty():
		effective_context = contexts[0]

	var nodes_result := _run_kubectl(_with_context(PackedStringArray(["get", "nodes", "-o", "json"]), effective_context))
	var pods_result := _run_kubectl(_with_context(PackedStringArray(["get", "pods", "-A", "-o", "json"]), effective_context))
	var namespaces_result := _run_kubectl(_with_context(PackedStringArray(["get", "namespaces", "-o", "json"]), effective_context))
	var events_result := _run_kubectl(_with_context(PackedStringArray(["get", "events", "-A", "-o", "json", "--sort-by=.lastTimestamp"]), effective_context))
	if not nodes_result.ok or not pods_result.ok:
		var failure_message := "Unable to query cluster state. Running in demo mode."
		if not nodes_result.stdout.strip_edges().is_empty():
			failure_message = nodes_result.stdout.strip_edges()
		elif not pods_result.stdout.strip_edges().is_empty():
			failure_message = pods_result.stdout.strip_edges()
		return _build_demo_state(failure_message)

	var nodes_json := _parse_json_dictionary(nodes_result.stdout)
	var pods_json := _parse_json_dictionary(pods_result.stdout)
	var namespaces_json := _parse_json_dictionary(namespaces_result.stdout)
	var events_json := _parse_json_dictionary(events_result.stdout)
	var node_metrics_result := _run_kubectl(_with_context(PackedStringArray(["top", "nodes", "--no-headers"]), effective_context))
	var pod_metrics_result := _run_kubectl(_with_context(PackedStringArray(["top", "pods", "-A", "--no-headers"]), effective_context))
	var node_metrics := _parse_node_metrics(node_metrics_result.stdout)
	var pod_metrics := _parse_pod_metrics(pod_metrics_result.stdout)

	var nodes := _parse_nodes(nodes_json, node_metrics)
	var pods := _parse_pods(pods_json, pod_metrics)
	var namespaces := _parse_namespaces(namespaces_json)
	if namespaces.is_empty():
		namespaces = _extract_namespaces_from_pods(pods)
	var events := _parse_events(events_json)
	var groups := _build_workload_groups(pods)
	var summary := _build_summary(nodes, pods)
	return {
		"mode": "live",
		"message": "Live cluster data via kubectl.",
		"kubeconfig_path": _kubeconfig_path,
		"contexts": contexts,
		"current_context": effective_context,
		"namespaces": namespaces,
		"nodes": nodes,
		"pods": pods,
		"events": events,
		"workload_groups": groups,
		"summary": summary,
		"timestamp": Time.get_datetime_string_from_system(false, true),
	}


func fetch_pod_logs(context_name: String, namespace_name: String, pod_name: String, tail_lines: int = 80) -> String:
	if pod_name.is_empty():
		return "Select a workload to inspect logs."
	var result := _run_kubectl(
		_with_context(
			PackedStringArray([
				"logs",
				"-n",
				namespace_name,
				pod_name,
				"--tail=%d" % tail_lines,
				"--all-containers=true",
			]),
			context_name
		)
	)
	if result.ok and not result.stdout.strip_edges().is_empty():
		return result.stdout.strip_edges()
	return _build_demo_logs(namespace_name, pod_name)


func fetch_pod_yaml(context_name: String, namespace_name: String, pod_name: String) -> String:
	if pod_name.is_empty():
		return "Select a workload to inspect YAML."
	var result := _run_kubectl(
		_with_context(
			PackedStringArray(["get", "pod", pod_name, "-n", namespace_name, "-o", "yaml"]),
			context_name
		)
	)
	if result.ok and not result.stdout.strip_edges().is_empty():
		return result.stdout.strip_edges()
	return _build_demo_yaml(namespace_name, pod_name)


func fetch_pod_description(context_name: String, namespace_name: String, pod_name: String) -> String:
	if pod_name.is_empty():
		return "Select a workload to inspect."
	var result := _run_kubectl(
		_with_context(
			PackedStringArray(["describe", "pod", pod_name, "-n", namespace_name]),
			context_name
		)
	)
	if result.ok and not result.stdout.strip_edges().is_empty():
		return result.stdout.strip_edges()
	return _build_demo_description(namespace_name, pod_name)


func build_exec_args(context_name: String, namespace_name: String, pod_name: String) -> PackedStringArray:
	return _with_context(
		PackedStringArray(["exec", "-it", "-n", namespace_name, pod_name, "--", "sh"]),
		context_name
	)


func build_port_forward_args(context_name: String, namespace_name: String, pod_name: String, local_port: int, remote_port: int) -> PackedStringArray:
	return _with_context(
		PackedStringArray([
			"port-forward",
			"-n",
			namespace_name,
			"pod/%s" % pod_name,
			"%d:%d" % [local_port, remote_port],
		]),
		context_name
	)


func _build_summary(nodes: Array, pods: Array) -> Dictionary:
	var cpu_samples := 0
	var memory_samples := 0
	var cpu_total := 0.0
	var memory_total := 0.0
	var ready_pods := 0
	for node in nodes:
		var cpu_percent := float(node.get("cpu_percent", -1.0))
		var memory_percent := float(node.get("memory_percent", -1.0))
		if cpu_percent >= 0.0:
			cpu_total += cpu_percent
			cpu_samples += 1
		if memory_percent >= 0.0:
			memory_total += memory_percent
			memory_samples += 1
	for pod in pods:
		if int(pod.get("ready_containers", 0)) >= int(pod.get("total_containers", 1)):
			ready_pods += 1
	return {
		"pods": pods.size(),
		"ready_pods": ready_pods,
		"nodes": nodes.size(),
		"cpu_percent": cpu_total / max(cpu_samples, 1),
		"memory_percent": memory_total / max(memory_samples, 1),
	}


func _parse_nodes(nodes_json: Dictionary, node_metrics: Dictionary) -> Array:
	var nodes: Array = []
	for item in nodes_json.get("items", []):
		var metadata: Dictionary = item.get("metadata", {})
		var status_info: Dictionary = item.get("status", {})
		var labels: Dictionary = metadata.get("labels", {})
		var conditions: Array = status_info.get("conditions", [])
		var roles: Array = []
		for key in labels.keys():
			var label_key := String(key)
			if label_key.begins_with("node-role.kubernetes.io/"):
				var role := label_key.trim_prefix("node-role.kubernetes.io/")
				roles.append(role if not role.is_empty() else "worker")
		if roles.is_empty():
			roles.append("worker")
		var ready_state := "Unknown"
		for condition in conditions:
			if condition.get("type", "") == "Ready":
				ready_state = "Ready" if condition.get("status", "") == "True" else "NotReady"
				break
		var node_name := String(metadata.get("name", "node"))
		var metrics: Dictionary = node_metrics.get(node_name, {})
		nodes.append({
			"name": node_name,
			"roles": roles,
			"status": ready_state,
			"cpu_mcpu": float(metrics.get("cpu_mcpu", -1.0)),
			"memory_mib": float(metrics.get("memory_mib", -1.0)),
			"cpu_percent": float(metrics.get("cpu_percent", -1.0)),
			"memory_percent": float(metrics.get("memory_percent", -1.0)),
			"kubelet_version": status_info.get("nodeInfo", {}).get("kubeletVersion", ""),
		})
	return nodes


func _parse_pods(pods_json: Dictionary, pod_metrics: Dictionary) -> Array:
	var pods: Array = []
	for item in pods_json.get("items", []):
		var metadata: Dictionary = item.get("metadata", {})
		var spec: Dictionary = item.get("spec", {})
		var status_info: Dictionary = item.get("status", {})
		var container_statuses: Array = status_info.get("containerStatuses", [])
		var labels: Dictionary = metadata.get("labels", {})
		var ready_containers := 0
		var total_containers := container_statuses.size()
		var restart_count := 0
		for container_status in container_statuses:
			if container_status.get("ready", false):
				ready_containers += 1
			restart_count += int(container_status.get("restartCount", 0))
		var owner_refs: Array = metadata.get("ownerReferences", [])
		var owner_kind := ""
		var owner_name := ""
		if not owner_refs.is_empty():
			var owner: Dictionary = owner_refs[0]
			owner_kind = String(owner.get("kind", ""))
			owner_name = String(owner.get("name", ""))
		var namespace_name := String(metadata.get("namespace", "default"))
		var pod_name := String(metadata.get("name", "pod"))
		var metrics: Dictionary = pod_metrics.get("%s/%s" % [namespace_name, pod_name], {})
		var ports := []
		for container in spec.get("containers", []):
			for port in container.get("ports", []):
				ports.append(int(port.get("containerPort", 0)))
		ports = _unique_ints(ports)
		pods.append({
			"name": pod_name,
			"namespace": namespace_name,
			"node_name": String(spec.get("nodeName", "")),
			"phase": String(status_info.get("phase", "Unknown")),
			"pod_ip": String(status_info.get("podIP", "")),
			"labels": labels,
			"ready_containers": ready_containers,
			"total_containers": max(total_containers, spec.get("containers", []).size()),
			"restart_count": restart_count,
			"image": _first_container_image(spec),
			"owner_kind": owner_kind,
			"owner_name": owner_name,
			"cpu_mcpu": float(metrics.get("cpu_mcpu", 0.0)),
			"memory_mib": float(metrics.get("memory_mib", 0.0)),
			"ports": ports,
			"created_at": String(metadata.get("creationTimestamp", "")),
		})
	return pods


func _parse_namespaces(namespaces_json: Dictionary) -> Array:
	var namespaces: Array = []
	for item in namespaces_json.get("items", []):
		var metadata: Dictionary = item.get("metadata", {})
		namespaces.append(String(metadata.get("name", "")))
	namespaces.sort()
	return namespaces


func _parse_events(events_json: Dictionary) -> Array:
	var events: Array = []
	for item in events_json.get("items", []):
		var involved: Dictionary = item.get("involvedObject", {})
		events.append({
			"namespace": String(item.get("metadata", {}).get("namespace", "default")),
			"reason": String(item.get("reason", "")),
			"type": String(item.get("type", "Normal")),
			"message": String(item.get("message", "")),
			"object_kind": String(involved.get("kind", "")),
			"object_name": String(involved.get("name", "")),
			"time": _pick_event_time(item),
		})
	return events


func _build_workload_groups(pods: Array) -> Array:
	var groups := {}
	for pod in pods:
		var workload_name := _derive_workload_name(pod)
		var namespace_name := String(pod.get("namespace", "default"))
		var key := "%s/%s" % [namespace_name, workload_name]
		if not groups.has(key):
			groups[key] = {
				"key": key,
				"name": workload_name,
				"namespace": namespace_name,
				"pod_count": 0,
				"ready_pods": 0,
				"restart_count": 0,
				"pods": [],
				"nodes": [],
				"images": [],
				"ports": [],
				"cpu_mcpu": 0.0,
				"memory_mib": 0.0,
				"status_counts": {},
				"owner_kind": String(pod.get("owner_kind", "")),
			}
		var group: Dictionary = groups[key]
		group["pod_count"] = int(group.get("pod_count", 0)) + 1
		if int(pod.get("ready_containers", 0)) >= int(pod.get("total_containers", 1)):
			group["ready_pods"] = int(group.get("ready_pods", 0)) + 1
		group["restart_count"] = int(group.get("restart_count", 0)) + int(pod.get("restart_count", 0))
		var pod_names: Array = group.get("pods", [])
		pod_names.append(pod.get("name", ""))
		group["pods"] = pod_names
		var node_names: Array = group.get("nodes", [])
		node_names.append(pod.get("node_name", ""))
		group["nodes"] = _unique_strings(node_names)
		var images: Array = group.get("images", [])
		images.append(pod.get("image", ""))
		group["images"] = _unique_strings(images)
		var ports: Array = group.get("ports", [])
		for port in pod.get("ports", []):
			ports.append(port)
		group["ports"] = _unique_ints(ports)
		group["cpu_mcpu"] = float(group.get("cpu_mcpu", 0.0)) + float(pod.get("cpu_mcpu", 0.0))
		group["memory_mib"] = float(group.get("memory_mib", 0.0)) + float(pod.get("memory_mib", 0.0))
		var status_counts: Dictionary = group.get("status_counts", {})
		var phase := String(pod.get("phase", "Unknown"))
		status_counts[phase] = int(status_counts.get(phase, 0)) + 1
		group["status_counts"] = status_counts
		groups[key] = group
	var results: Array = groups.values()
	results.sort_custom(func(a, b): return int(a.get("pod_count", 0)) > int(b.get("pod_count", 0)))
	return results


func _derive_workload_name(pod: Dictionary) -> String:
	var labels: Dictionary = pod.get("labels", {})
	var label_candidates := [
		String(labels.get("app.kubernetes.io/name", "")),
		String(labels.get("app", "")),
		String(labels.get("k8s-app", "")),
	]
	for candidate in label_candidates:
		if not candidate.is_empty():
			return candidate
	var owner_name := String(pod.get("owner_name", ""))
	if not owner_name.is_empty():
		return _trim_workload_hash(owner_name)
	return _trim_workload_hash(String(pod.get("name", "workload")))


func _trim_workload_hash(name: String) -> String:
	var regex := RegEx.new()
	regex.compile("^(.*)-[a-f0-9]{9,10}$")
	var match_result := regex.search(name)
	if match_result:
		return match_result.get_string(1)
	regex.compile("^(.*)-[a-z0-9]{5}$")
	match_result = regex.search(name)
	if match_result:
		return match_result.get_string(1)
	return name


func _parse_node_metrics(stdout: String) -> Dictionary:
	var metrics := {}
	for line in _lines(stdout):
		var fields := _split_fields(line)
		if fields.size() < 5:
			continue
		metrics[fields[0]] = {
			"cpu_mcpu": _parse_cpu_to_millicores(fields[1]),
			"cpu_percent": _parse_percent(fields[2]),
			"memory_mib": _parse_memory_to_mib(fields[3]),
			"memory_percent": _parse_percent(fields[4]),
		}
	return metrics


func _parse_pod_metrics(stdout: String) -> Dictionary:
	var metrics := {}
	for line in _lines(stdout):
		var fields := _split_fields(line)
		if fields.size() < 4:
			continue
		var key := "%s/%s" % [fields[0], fields[1]]
		metrics[key] = {
			"cpu_mcpu": _parse_cpu_to_millicores(fields[2]),
			"memory_mib": _parse_memory_to_mib(fields[3]),
		}
	return metrics


func _parse_cpu_to_millicores(raw_value: String) -> float:
	var value := raw_value.strip_edges()
	if value.is_empty():
		return 0.0
	if value.ends_with("m"):
		return value.trim_suffix("m").to_float()
	return value.to_float() * 1000.0


func _parse_memory_to_mib(raw_value: String) -> float:
	var value := raw_value.strip_edges()
	if value.is_empty():
		return 0.0
	if value.ends_with("Ki"):
		return value.trim_suffix("Ki").to_float() / 1024.0
	if value.ends_with("Mi"):
		return value.trim_suffix("Mi").to_float()
	if value.ends_with("Gi"):
		return value.trim_suffix("Gi").to_float() * 1024.0
	if value.ends_with("Ti"):
		return value.trim_suffix("Ti").to_float() * 1024.0 * 1024.0
	return value.to_float()


func _parse_percent(raw_value: String) -> float:
	return raw_value.strip_edges().trim_suffix("%").to_float()


func _first_container_image(spec: Dictionary) -> String:
	var containers: Array = spec.get("containers", [])
	if containers.is_empty():
		return ""
	return String(containers[0].get("image", ""))


func _pick_event_time(event_item: Dictionary) -> String:
	var candidates := [
		String(event_item.get("lastTimestamp", "")),
		String(event_item.get("eventTime", "")),
		String(event_item.get("deprecatedLastTimestamp", "")),
		String(event_item.get("metadata", {}).get("creationTimestamp", "")),
	]
	for candidate in candidates:
		if not candidate.is_empty():
			return candidate
	return ""


func _extract_namespaces_from_pods(pods: Array) -> Array:
	var namespaces := []
	for pod in pods:
		namespaces.append(String(pod.get("namespace", "default")))
	return _unique_strings(namespaces)


func _parse_json_dictionary(stdout: String) -> Dictionary:
	var parsed = JSON.parse_string(stdout)
	if parsed is Dictionary:
		return parsed
	return {}


func _run_kubectl(args: PackedStringArray) -> Dictionary:
	if not _kubeconfig_path.is_empty():
		OS.set_environment("KUBECONFIG", _kubeconfig_path)
	var output: Array = []
	var exit_code := OS.execute("kubectl", args, output, true)
	var combined_output := ""
	if not output.is_empty():
		combined_output = "\n".join(output)
	return {
		"ok": exit_code == 0,
		"code": exit_code,
		"stdout": combined_output,
	}


func _with_context(args: PackedStringArray, context_name: String) -> PackedStringArray:
	var command_args := PackedStringArray()
	if not context_name.is_empty():
		command_args.append("--context")
		command_args.append(context_name)
	command_args.append_array(args)
	return command_args


func _lines(raw_text: String) -> Array:
	var cleaned := raw_text.strip_edges()
	if cleaned.is_empty():
		return []
	return cleaned.split("\n", false)


func _split_fields(line: String) -> Array:
	return line.replace("\t", " ").split(" ", false)


func _unique_strings(values: Array) -> Array:
	var seen := {}
	var results := []
	for value in values:
		var string_value := String(value)
		if string_value.is_empty() or seen.has(string_value):
			continue
		seen[string_value] = true
		results.append(string_value)
	results.sort()
	return results


func _unique_ints(values: Array) -> Array:
	var seen := {}
	var results := []
	for value in values:
		var int_value := int(value)
		if int_value <= 0 or seen.has(int_value):
			continue
		seen[int_value] = true
		results.append(int_value)
	results.sort()
	return results


func _build_demo_state(message: String) -> Dictionary:
	var wave := sin(float(Time.get_ticks_msec() % 10000) / 10000.0 * TAU)
	var cpu_base := 68.0 + wave * 4.0
	var memory_base := 63.0 + wave * 3.5
	var nodes := [
		{
			"name": "node-01",
			"roles": ["worker"],
			"status": "Ready",
			"cpu_mcpu": 840.0,
			"memory_mib": 2816.0,
			"cpu_percent": cpu_base,
			"memory_percent": memory_base,
			"kubelet_version": "v1.31.2",
		},
		{
			"name": "node-02",
			"roles": ["worker"],
			"status": "Ready",
			"cpu_mcpu": 702.0,
			"memory_mib": 2468.0,
			"cpu_percent": cpu_base - 6.0,
			"memory_percent": memory_base + 3.0,
			"kubelet_version": "v1.31.2",
		},
		{
			"name": "node-03",
			"roles": ["control-plane"],
			"status": "Ready",
			"cpu_mcpu": 512.0,
			"memory_mib": 1984.0,
			"cpu_percent": cpu_base - 10.0,
			"memory_percent": memory_base - 7.0,
			"kubelet_version": "v1.31.2",
		},
	]
	var pods := [
		_demo_pod("frontend-app-1", "default", "node-01", "Running", 3, 3, 0, "ghcr.io/kube-axis/frontend:v1.2.0", "frontend", [8080], 96.0, 256.0),
		_demo_pod("frontend-app-2", "default", "node-02", "Running", 3, 3, 1, "ghcr.io/kube-axis/frontend:v1.2.0", "frontend", [8080], 84.0, 240.0),
		_demo_pod("backend-api-1", "payments", "node-01", "Running", 2, 2, 0, "ghcr.io/kube-axis/backend:v2.4.1", "backend", [9000], 144.0, 420.0),
		_demo_pod("backend-api-2", "payments", "node-02", "Running", 2, 2, 0, "ghcr.io/kube-axis/backend:v2.4.1", "backend", [9000], 132.0, 398.0),
		_demo_pod("postgres-0", "platform", "node-02", "Running", 1, 1, 0, "postgres:16.2", "db", [5432], 92.0, 768.0),
		_demo_pod("redis-0", "platform", "node-01", "Running", 1, 1, 0, "redis:7.4", "db", [6379], 22.0, 128.0),
		_demo_pod("prometheus-0", "monitoring", "node-03", "Running", 2, 2, 0, "prom/prometheus:v2.55.1", "monitoring", [9090], 110.0, 520.0),
		_demo_pod("grafana-0", "monitoring", "node-03", "Running", 1, 1, 2, "grafana/grafana:11.3.0", "monitoring", [3000], 48.0, 222.0),
	]
	var events := [
		{
			"namespace": "default",
			"reason": "CrashLoopBackOff",
			"type": "Warning",
			"message": "frontend-app-2 restarted after readiness timeout.",
			"object_kind": "Pod",
			"object_name": "frontend-app-2",
			"time": "2026-04-07T10:13:00Z",
		},
		{
			"namespace": "default",
			"reason": "ProbeFailed",
			"type": "Warning",
			"message": "Liveness probe failed on frontend-app-1.",
			"object_kind": "Pod",
			"object_name": "frontend-app-1",
			"time": "2026-04-07T10:12:00Z",
		},
		{
			"namespace": "payments",
			"reason": "ScalingReplicaSet",
			"type": "Normal",
			"message": "Scaled backend deployment to 2 replicas.",
			"object_kind": "Deployment",
			"object_name": "backend",
			"time": "2026-04-07T10:11:00Z",
		},
		{
			"namespace": "monitoring",
			"reason": "Pulled",
			"type": "Normal",
			"message": "Container image pulled successfully for grafana-0.",
			"object_kind": "Pod",
			"object_name": "grafana-0",
			"time": "2026-04-07T10:09:00Z",
		},
	]
	return {
		"mode": "demo",
		"message": message,
		"kubeconfig_path": _kubeconfig_path,
		"contexts": DEMO_CONTEXTS,
		"current_context": "prod-cluster",
		"namespaces": DEMO_NAMESPACES,
		"nodes": nodes,
		"pods": pods,
		"events": events,
		"workload_groups": _build_workload_groups(pods),
		"summary": _build_summary(nodes, pods),
		"timestamp": Time.get_datetime_string_from_system(false, true),
	}


func _load_saved_kubeconfig() -> void:
	var settings := ConfigFile.new()
	var load_error := settings.load(SETTINGS_FILE)
	if load_error != OK:
		return
	var configured_path := String(settings.get_value(SETTINGS_SECTION, SETTINGS_KEY_KUBECONFIG, ""))
	if configured_path.is_empty():
		return
	if not FileAccess.file_exists(configured_path):
		return
	_kubeconfig_path = configured_path
	OS.set_environment("KUBECONFIG", _kubeconfig_path)


func _save_kubeconfig() -> int:
	var settings := ConfigFile.new()
	settings.set_value(SETTINGS_SECTION, SETTINGS_KEY_KUBECONFIG, _kubeconfig_path)
	return settings.save(SETTINGS_FILE)


func _demo_pod(
	name: String,
	namespace_name: String,
	node_name: String,
	phase: String,
	ready_containers: int,
	total_containers: int,
	restart_count: int,
	image: String,
	workload_name: String,
	ports: Array,
	cpu_mcpu: float,
	memory_mib: float
) -> Dictionary:
	return {
		"name": name,
		"namespace": namespace_name,
		"node_name": node_name,
		"phase": phase,
		"pod_ip": "10.42.%d.%d" % [randi_range(0, 9), randi_range(10, 240)],
		"labels": {"app.kubernetes.io/name": workload_name},
		"ready_containers": ready_containers,
		"total_containers": total_containers,
		"restart_count": restart_count,
		"image": image,
		"owner_kind": "ReplicaSet",
		"owner_name": "%s-rs-7b9d7f5c7f" % workload_name,
		"cpu_mcpu": cpu_mcpu,
		"memory_mib": memory_mib,
		"ports": ports,
		"created_at": "2026-04-07T09:58:00Z",
	}


func _build_demo_logs(namespace_name: String, pod_name: String) -> String:
	return "\n".join([
		"[%s] GET /healthz 200 3ms" % namespace_name,
		"[%s] worker connected to pod %s" % [namespace_name, pod_name],
		"[%s] cache sync completed" % namespace_name,
		"[%s] readiness probe passed" % namespace_name,
		"[%s] background reconcile loop stable" % namespace_name,
	])


func _build_demo_yaml(namespace_name: String, pod_name: String) -> String:
	return "\n".join([
		"apiVersion: v1",
		"kind: Pod",
		"metadata:",
		"  name: %s" % pod_name,
		"  namespace: %s" % namespace_name,
		"spec:",
		"  containers:",
		"  - name: app",
		"    image: ghcr.io/kube-axis/%s:demo" % _trim_workload_hash(pod_name),
		"    imagePullPolicy: IfNotPresent",
		"status:",
		"  phase: Running",
	])


func _build_demo_description(namespace_name: String, pod_name: String) -> String:
	return "\n".join([
		"Name:           %s" % pod_name,
		"Namespace:      %s" % namespace_name,
		"Node:           node-01/10.42.0.11",
		"Status:         Running",
		"Containers:     1/1 ready",
		"Events:",
		"  Normal  Pulled   2m   kubelet  Container image already present on machine",
		"  Normal  Started  2m   kubelet  Started container app",
	])
