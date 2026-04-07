extends RefCounted

const DEMO_CONTEXTS := ["prod-cluster", "dev-cluster", "test-cluster"]
const DEMO_NAMESPACES := ["default", "payments", "platform", "monitoring"]
const SETTINGS_FILE := "user://kube_axis.cfg"
const SETTINGS_SECTION := "kube"
const SETTINGS_KEY_KUBECONFIG := "kubeconfig_path"
const SETTINGS_KEY_FORCE_DEMO := "force_demo_mode"
const METRICS_CACHE_MSEC := 20000
const KUBECTL_REQUEST_TIMEOUT := "8s"

var _kubeconfig_path := ""
var _force_demo_mode := false
var _kubectl_checked := false
var _kubectl_available := false
var _cached_node_metrics: Dictionary = {}
var _cached_pod_metrics: Dictionary = {}
var _cached_metrics_context := ""
var _last_metrics_refresh_msec := 0


func _init() -> void:
	_load_saved_kubeconfig()


func import_kubeconfig(kubeconfig_path: String) -> Dictionary:
	var normalized_path := _normalize_kubeconfig_path(kubeconfig_path)
	if normalized_path.is_empty():
		return {
			"ok": false,
			"message": "No kubeconfig file selected.",
		}
	if not FileAccess.file_exists(normalized_path):
		return {
			"ok": false,
			"message": "Selected kubeconfig file does not exist.",
		}
	var previous_path := _kubeconfig_path
	var previous_force_demo := _force_demo_mode
	_apply_kubeconfig_path(normalized_path)
	_force_demo_mode = false
	var contexts_result := _run_kubectl(PackedStringArray(["config", "get-contexts", "-o", "name"]))
	var contexts := _lines(String(contexts_result.get("stdout", "")))
	if not bool(contexts_result.get("ok", false)):
		_apply_kubeconfig_path(previous_path)
		_force_demo_mode = previous_force_demo
		return {
			"ok": false,
			"message": _build_kubeconfig_import_error(normalized_path, String(contexts_result.get("stdout", ""))),
		}
	if contexts.is_empty():
		_apply_kubeconfig_path(previous_path)
		_force_demo_mode = previous_force_demo
		return {
			"ok": false,
			"message": "Selected kubeconfig contains no contexts.",
		}
	_reset_live_caches()
	var save_error := _save_settings()
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


func make_snapshot() -> Dictionary:
	return {
		"kubeconfig_path": _kubeconfig_path,
		"force_demo_mode": _force_demo_mode,
	}


func apply_snapshot(snapshot: Dictionary) -> void:
	_force_demo_mode = bool(snapshot.get("force_demo_mode", false))
	var snapshot_path := _normalize_kubeconfig_path(String(snapshot.get("kubeconfig_path", "")))
	if _force_demo_mode:
		snapshot_path = ""
	_apply_kubeconfig_path(snapshot_path)
	_reset_live_caches()


func use_demo_cluster() -> Dictionary:
	_force_demo_mode = true
	_apply_kubeconfig_path("")
	_reset_live_caches()
	var save_error := _save_settings()
	if save_error != OK:
		return {
			"ok": true,
			"message": "Demo cluster enabled for this session, but persistence failed.",
		}
	return {
		"ok": true,
		"message": "Demo cluster enabled. Import a kubeconfig to reconnect.",
	}


func refresh(context_name: String = "", focus_domain: String = "Workloads", metrics_enabled: bool = false) -> Dictionary:
	if _force_demo_mode:
		return _build_demo_state("Demo cluster active. Import a kubeconfig to reconnect.", metrics_enabled)
	if not _ensure_kubectl_available():
		return _build_demo_state("kubectl is unavailable. Running in demo mode.", metrics_enabled)

	var contexts_result := _run_kubectl(PackedStringArray(["config", "get-contexts", "-o", "name"]))
	if not contexts_result.ok:
		return _build_demo_state(_format_kubeconfig_error("Unable to read kube contexts. Running in demo mode.", contexts_result.stdout), metrics_enabled)
	var contexts := _lines(contexts_result.stdout)
	if contexts.is_empty():
		var no_contexts_message := "Selected kubeconfig has no contexts. Running in demo mode."
		if _kubeconfig_path.is_empty():
			no_contexts_message = "No kube contexts found. Running in demo mode."
		return _build_demo_state(no_contexts_message, metrics_enabled)

	var current_context_result := _run_kubectl(PackedStringArray(["config", "current-context"]))
	var effective_context := context_name
	if effective_context.is_empty():
		effective_context = current_context_result.stdout.strip_edges()
	if effective_context.is_empty():
		effective_context = contexts[0]

	var nodes_result := _run_kubectl(_with_context(PackedStringArray(["get", "nodes", "-o", "json"]), effective_context))
	if not nodes_result.ok:
		var failure_message := "Unable to query cluster state. Running in demo mode."
		if not nodes_result.stdout.strip_edges().is_empty():
			failure_message = nodes_result.stdout.strip_edges()
		return _build_demo_state(failure_message, metrics_enabled)
	var pods_result := _run_kubectl(_with_context(PackedStringArray(["get", "pods", "-A", "-o", "json"]), effective_context))
	if not pods_result.ok:
		var pod_failure_message := "Unable to query cluster state. Running in demo mode."
		if not pods_result.stdout.strip_edges().is_empty():
			pod_failure_message = pods_result.stdout.strip_edges()
		return _build_demo_state(pod_failure_message, metrics_enabled)
	var namespaces_result := _run_kubectl(_with_context(PackedStringArray(["get", "namespaces", "-o", "json"]), effective_context))
	var events_result := _run_kubectl(_with_context(PackedStringArray(["get", "events", "-A", "-o", "json", "--sort-by=.lastTimestamp"]), effective_context))

	var nodes_json := _parse_json_dictionary(nodes_result.stdout)
	var pods_json := _parse_json_dictionary(pods_result.stdout)
	var namespaces_json := _parse_json_dictionary(namespaces_result.stdout) if namespaces_result.ok else {}
	var events_json := _parse_json_dictionary(events_result.stdout) if events_result.ok else {}
	var node_metrics := _get_node_metrics(effective_context) if metrics_enabled else {}
	var pod_metrics := _get_pod_metrics(effective_context) if metrics_enabled else {}

	var nodes := _parse_nodes(nodes_json, node_metrics)
	var pods := _parse_pods(pods_json, pod_metrics)
	var namespaces := _parse_namespaces(namespaces_json)
	if namespaces.is_empty():
		namespaces = _extract_namespaces_from_pods(pods)
	var events := _parse_events(events_json)
	var groups := _build_workload_groups(pods)
	var summary := _build_summary(nodes, pods)
	var resource_catalog := _build_resource_catalog(focus_domain, effective_context, groups, nodes, pods)
	return {
		"mode": "live",
		"message": "Live cluster data via kubectl.",
		"kubeconfig_path": _kubeconfig_path,
		"focus_domain": focus_domain,
		"metrics_enabled": metrics_enabled,
		"contexts": contexts,
		"current_context": effective_context,
		"namespaces": namespaces,
		"nodes": nodes,
		"pods": pods,
		"events": events,
		"workload_groups": groups,
		"resource_catalog": resource_catalog,
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


func fetch_resource_yaml(context_name: String, resource_type: String, namespace_name: String, resource_name: String, scope: String = "Namespaced") -> String:
	if resource_name.is_empty() or resource_type.is_empty():
		return "Select a resource to inspect YAML."
	var args := PackedStringArray(["get", resource_type, resource_name])
	if scope != "Cluster" and not namespace_name.is_empty():
		args.append("-n")
		args.append(namespace_name)
	args.append("-o")
	args.append("yaml")
	var result := _run_kubectl(_with_context(args, context_name))
	if result.ok and not result.stdout.strip_edges().is_empty():
		return result.stdout.strip_edges()
	return "Unable to load YAML for %s %s." % [resource_type, resource_name]


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


func build_port_forward_args(context_name: String, namespace_name: String, resource_ref: String, local_port: int, remote_port: int) -> PackedStringArray:
	var target_ref := resource_ref
	if not target_ref.contains("/"):
		target_ref = "pod/%s" % resource_ref
	return _with_context(
		PackedStringArray([
			"port-forward",
			"-n",
			namespace_name,
			target_ref,
			"%d:%d" % [local_port, remote_port],
		]),
		context_name
	)


func _build_resource_catalog(focus_domain: String, context_name: String, workload_groups: Array, nodes: Array, pods: Array) -> Dictionary:
	var catalog := {
		"Applications": _build_workload_resource_items(workload_groups),
		"Workloads": _build_workload_resource_items(workload_groups),
		"Pods": _build_pod_resource_items(pods),
		"Nodes": _build_node_resource_items(nodes),
	}
	match focus_domain:
		"Deployments":
			catalog["Deployments"] = _build_deployment_resource_items(context_name)
		"ConfigMaps":
			catalog["ConfigMaps"] = _build_configmap_resource_items(context_name)
		"Network":
			catalog["Network"] = _build_network_resource_items(context_name)
		"Storage":
			catalog["Storage"] = _build_storage_resource_items(context_name)
		"Helm":
			catalog["Helm"] = _build_helm_resource_items(context_name)
		"Access":
			catalog["Access"] = _build_access_resource_items(context_name)
	return catalog


func _build_workload_resource_items(workload_groups: Array) -> Array:
	var items := []
	for group in workload_groups:
		var ready_pods := int(group.get("ready_pods", 0))
		var pod_count := int(group.get("pod_count", 0))
		var namespace_name := String(group.get("namespace", "default"))
		var workload_name := String(group.get("name", "workload"))
		var ports: Array = group.get("ports", [])
		items.append(_make_resource_item(
			"Application",
			"pod",
			workload_name,
			namespace_name,
			"Namespaced",
			"%s | %d/%d READY" % [namespace_name.to_upper(), ready_pods, pod_count],
			"\n".join([
				"Application: %s" % workload_name,
				"Owner kind: %s" % String(group.get("owner_kind", "Workload")),
				"Namespace: %s" % namespace_name,
				"Pods: %d ready / %d total" % [ready_pods, pod_count],
				"Restarts: %d" % int(group.get("restart_count", 0)),
				"Ports: %s" % _join_ints(ports),
				"Nodes: %s" % ", ".join(group.get("nodes", [])),
				"Images: %s" % ", ".join(group.get("images", [])),
			]),
			"\n".join([
				"CPU usage: %.0f mCPU" % float(group.get("cpu_mcpu", 0.0)),
				"Memory usage: %.0f Mi" % float(group.get("memory_mib", 0.0)),
				"Restart count: %d" % int(group.get("restart_count", 0)),
				"Status spread: %s" % _format_status_counts(group.get("status_counts", {})),
			]),
			"Ports: %s | Nodes: %s" % [_join_ints(ports), ", ".join(group.get("nodes", []))],
			_warning_level(ready_pods, pod_count),
			ready_pods,
				max(pod_count, 1),
				ports,
				true,
				true,
				true,
				not ports.is_empty(),
				group.get("nodes", []),
				{
					"pod_names": group.get("pods", []),
					"owner_kind": String(group.get("owner_kind", "Workload")),
					"requires_metrics_poll": true,
				}
			))
	return items


func _build_pod_resource_items(pods: Array) -> Array:
	var items := []
	for pod in pods:
		var namespace_name := String(pod.get("namespace", "default"))
		var pod_name := String(pod.get("name", "pod"))
		var ready_count := int(pod.get("ready_containers", 0))
		var total_count := int(pod.get("total_containers", 1))
		var phase := String(pod.get("phase", "Unknown"))
		var ports: Array = pod.get("ports", [])
		var status_level := _warning_level(ready_count, total_count)
		if phase != "Running" and phase != "Succeeded":
			status_level = "warning"
		items.append(_make_resource_item(
			"Pod",
			"pod",
			pod_name,
			namespace_name,
			"Namespaced",
			"POD | %s | %s" % [namespace_name.to_upper(), phase.to_upper()],
			"\n".join([
				"Kind: Pod",
				"Name: %s" % pod_name,
				"Namespace: %s" % namespace_name,
				"Phase: %s" % phase,
				"Ready containers: %d/%d" % [ready_count, total_count],
				"Restarts: %d" % int(pod.get("restart_count", 0)),
				"Node: %s" % String(pod.get("node_name", "")),
				"Image: %s" % String(pod.get("image", "")),
				"Pod IP: %s" % String(pod.get("pod_ip", "")),
				"Ports: %s" % _join_ints(ports),
			]),
			"\n".join([
				"CPU usage: %.0f mCPU" % float(pod.get("cpu_mcpu", 0.0)),
				"Memory usage: %.0f Mi" % float(pod.get("memory_mib", 0.0)),
				"Ready containers: %d/%d" % [ready_count, total_count],
				"Restarts: %d" % int(pod.get("restart_count", 0)),
			]),
			"Node: %s | Owner: %s/%s" % [
				String(pod.get("node_name", "")),
				String(pod.get("owner_kind", "Pod")),
				String(pod.get("owner_name", pod_name)),
			],
			status_level,
			ready_count,
			total_count,
			ports,
			true,
			true,
			true,
			not ports.is_empty(),
			[String(pod.get("node_name", ""))],
			{
				"pod_names": [pod_name],
				"owner_kind": String(pod.get("owner_kind", "Pod")),
				"requires_metrics_poll": true,
			}
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_node_resource_items(nodes: Array) -> Array:
	var items := []
	for node in nodes:
		var roles: Array = node.get("roles", []) as Array
		var is_ready := String(node.get("status", "")) == "Ready"
		items.append(_make_resource_item(
			"Node",
			"node",
			String(node.get("name", "node")),
			"",
			"Cluster",
			"%s | %s" % [String(node.get("status", "Unknown")).to_upper(), ", ".join(roles).to_upper()],
			"\n".join([
				"Node: %s" % String(node.get("name", "")),
				"Roles: %s" % ", ".join(roles),
				"Status: %s" % String(node.get("status", "Unknown")),
				"CPU: %.0f mCPU (%.0f%%)" % [float(node.get("cpu_mcpu", 0.0)), float(node.get("cpu_percent", 0.0))],
				"Memory: %.0f Mi (%.0f%%)" % [float(node.get("memory_mib", 0.0)), float(node.get("memory_percent", 0.0))],
				"Kubelet: %s" % String(node.get("kubelet_version", "unknown")),
			]),
			"\n".join([
				"CPU percent: %.0f%%" % float(node.get("cpu_percent", 0.0)),
				"Memory percent: %.0f%%" % float(node.get("memory_percent", 0.0)),
				"Roles: %s" % ", ".join(roles),
			]),
			"Kubelet: %s" % String(node.get("kubelet_version", "unknown")),
			"healthy" if is_ready else "danger",
			1 if is_ready else 0,
			1,
			[],
			true,
			false,
			false,
			false,
			[],
			{
				"requires_metrics_poll": true,
			}
		))
	return items


func _build_deployment_resource_items(context_name: String) -> Array:
	var items := []
	var deployments_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "deployments", "-A", "-o", "json"]))
	for entry in deployments_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var spec: Dictionary = entry.get("spec", {})
		var status: Dictionary = entry.get("status", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var desired := int(spec.get("replicas", 1))
		var ready := int(status.get("readyReplicas", 0))
		var updated := int(status.get("updatedReplicas", 0))
		var available := int(status.get("availableReplicas", 0))
		var unavailable := int(status.get("unavailableReplicas", max(desired - available, 0)))
		var pod_spec: Dictionary = spec.get("template", {}).get("spec", {})
		var ports := _template_ports(pod_spec)
		items.append(_make_resource_item(
			"Deployment",
			"deployment",
			String(metadata.get("name", "deployment")),
			namespace_name,
			"Namespaced",
			"DEPLOYMENT | %s | %d/%d READY" % [namespace_name.to_upper(), ready, desired],
			"\n".join([
				"Kind: Deployment",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Desired replicas: %d" % desired,
				"Ready replicas: %d" % ready,
				"Updated replicas: %d" % updated,
				"Available replicas: %d" % available,
				"Selector: %s" % _format_label_dictionary(spec.get("selector", {}).get("matchLabels", {})),
				"Ports: %s" % _join_ints(ports),
			]),
			"\n".join([
				"Ready replicas: %d/%d" % [ready, max(desired, 1)],
				"Updated replicas: %d" % updated,
				"Available replicas: %d" % available,
				"Unavailable replicas: %d" % unavailable,
			]),
			"Strategy: %s | Ports: %s" % [
				String(spec.get("strategy", {}).get("type", "RollingUpdate")),
				_join_ints(ports),
			],
			_warning_level(ready, desired),
			ready,
			max(desired, 1),
			ports,
			true,
			false,
			false,
			false
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_configmap_resource_items(context_name: String) -> Array:
	var items := []
	var configmaps_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "configmaps", "-A", "-o", "json"]))
	for entry in configmaps_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var data: Dictionary = entry.get("data", {})
		items.append(_make_resource_item(
			"ConfigMap",
			"configmap",
			String(metadata.get("name", "configmap")),
			namespace_name,
			"Namespaced",
			"CONFIGMAP | %s | %d KEYS" % [namespace_name.to_upper(), data.size()],
			"\n".join([
				"Kind: ConfigMap",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Data keys: %d" % data.size(),
				"Created: %s" % String(metadata.get("creationTimestamp", "")),
			]),
			"\n".join([
				"Data keys: %d" % data.size(),
				"Labels: %s" % _format_label_dictionary(metadata.get("labels", {})),
			]),
			"Scope: %s" % namespace_name,
			"healthy"
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_config_resource_items(context_name: String) -> Array:
	var items := []
	var configmaps_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "configmaps", "-A", "-o", "json"]))
	for entry in configmaps_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var data: Dictionary = entry.get("data", {})
		items.append(_make_resource_item(
			"ConfigMap",
			"configmap",
			String(metadata.get("name", "configmap")),
			namespace_name,
			"Namespaced",
			"CONFIGMAP | %s | %d KEYS" % [namespace_name.to_upper(), data.size()],
			"\n".join([
				"Kind: ConfigMap",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Keys: %d" % data.size(),
				"Created: %s" % String(metadata.get("creationTimestamp", "")),
			]),
			"Data keys: %d" % data.size(),
			"Scope: %s" % namespace_name,
			"healthy"
		))
	for entry in _filter_display_secrets(_get_optional_resource_json(context_name, PackedStringArray(["get", "secrets", "-A", "-o", "json"])).get("items", [])):
		var metadata: Dictionary = entry.get("metadata", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var data: Dictionary = entry.get("data", {})
		var secret_type := String(entry.get("type", "Opaque"))
		items.append(_make_resource_item(
			"Secret",
			"secret",
			String(metadata.get("name", "secret")),
			namespace_name,
			"Namespaced",
			"SECRET | %s | %s" % [namespace_name.to_upper(), secret_type.to_upper()],
			"\n".join([
				"Kind: Secret",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Type: %s" % secret_type,
				"Data entries: %d" % data.size(),
				"Created: %s" % String(metadata.get("creationTimestamp", "")),
			]),
			"Data entries: %d" % data.size(),
			"Type: %s" % secret_type,
			"warning"
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_network_resource_items(context_name: String) -> Array:
	var items := []
	var services_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "services", "-A", "-o", "json"]))
	for entry in services_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var spec: Dictionary = entry.get("spec", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var ports := _service_ports(spec)
		var cluster_ip := String(spec.get("clusterIP", ""))
		items.append(_make_resource_item(
			"Service",
			"service",
			String(metadata.get("name", "service")),
			namespace_name,
			"Namespaced",
			"SERVICE | %s | %s" % [namespace_name.to_upper(), String(spec.get("type", "ClusterIP")).to_upper()],
			"\n".join([
				"Kind: Service",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Type: %s" % String(spec.get("type", "ClusterIP")),
				"Cluster IP: %s" % cluster_ip,
				"Ports: %s" % _join_ints(ports),
				"Selector: %s" % _format_label_dictionary(spec.get("selector", {})),
			]),
			"Ports: %s" % _join_ints(ports),
			"Cluster IP: %s" % cluster_ip,
			"healthy" if not ports.is_empty() else "warning",
			1 if not ports.is_empty() else 0,
			1,
			ports,
			true,
			false,
			false,
			not ports.is_empty(),
			[],
			{
				"port_forward_ref": "service/%s" % String(metadata.get("name", "")),
			}
		))
	var ingress_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "ingresses", "-A", "-o", "json"]))
	for entry in ingress_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var spec: Dictionary = entry.get("spec", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var hosts := _ingress_hosts(spec)
		items.append(_make_resource_item(
			"Ingress",
			"ingress",
			String(metadata.get("name", "ingress")),
			namespace_name,
			"Namespaced",
			"INGRESS | %s | %d HOSTS" % [namespace_name.to_upper(), hosts.size()],
			"\n".join([
				"Kind: Ingress",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Ingress class: %s" % String(spec.get("ingressClassName", "default")),
				"Hosts: %s" % _join_strings(hosts),
				"TLS blocks: %d" % int((spec.get("tls", []) as Array).size()),
			]),
			"Hosts: %d" % hosts.size(),
			"Hosts: %s" % _join_strings(hosts),
			"healthy" if not hosts.is_empty() else "warning"
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_storage_resource_items(context_name: String) -> Array:
	var items := []
	var pvc_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "pvc", "-A", "-o", "json"]))
	for entry in pvc_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var spec: Dictionary = entry.get("spec", {})
		var status: Dictionary = entry.get("status", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var phase := String(status.get("phase", "Unknown"))
		var request := String(spec.get("resources", {}).get("requests", {}).get("storage", "n/a"))
		items.append(_make_resource_item(
			"PersistentVolumeClaim",
			"pvc",
			String(metadata.get("name", "pvc")),
			namespace_name,
			"Namespaced",
			"PVC | %s | %s" % [namespace_name.to_upper(), phase.to_upper()],
			"\n".join([
				"Kind: PersistentVolumeClaim",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Phase: %s" % phase,
				"Storage class: %s" % String(spec.get("storageClassName", "default")),
				"Requested: %s" % request,
				"Volume: %s" % String(spec.get("volumeName", "")),
			]),
			"Requested: %s" % request,
			"Class: %s" % String(spec.get("storageClassName", "default")),
			"healthy" if phase == "Bound" else "warning",
			1 if phase == "Bound" else 0,
			1
		))
	var pv_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "pv", "-o", "json"]))
	for entry in pv_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var spec: Dictionary = entry.get("spec", {})
		var status: Dictionary = entry.get("status", {})
		var phase := String(status.get("phase", "Unknown"))
		var capacity := String(spec.get("capacity", {}).get("storage", "n/a"))
		var claim_ref: Dictionary = spec.get("claimRef", {})
		items.append(_make_resource_item(
			"PersistentVolume",
			"pv",
			String(metadata.get("name", "pv")),
			"",
			"Cluster",
			"PV | %s | %s" % [phase.to_upper(), capacity.to_upper()],
			"\n".join([
				"Kind: PersistentVolume",
				"Name: %s" % String(metadata.get("name", "")),
				"Phase: %s" % phase,
				"Capacity: %s" % capacity,
				"Storage class: %s" % String(spec.get("storageClassName", "default")),
				"Claim: %s/%s" % [String(claim_ref.get("namespace", "")), String(claim_ref.get("name", ""))],
			]),
			"Capacity: %s" % capacity,
			"Class: %s" % String(spec.get("storageClassName", "default")),
			"healthy" if phase == "Bound" else "warning",
			1 if phase == "Bound" else 0,
			1
		))
	var storage_class_json := _get_optional_resource_json(context_name, PackedStringArray(["get", "storageclasses", "-o", "json"]))
	for entry in storage_class_json.get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var provisioner := String(entry.get("provisioner", "unknown"))
		items.append(_make_resource_item(
			"StorageClass",
			"storageclass",
			String(metadata.get("name", "storageclass")),
			"",
			"Cluster",
			"STORAGECLASS | %s" % provisioner.to_upper(),
			"\n".join([
				"Kind: StorageClass",
				"Name: %s" % String(metadata.get("name", "")),
				"Provisioner: %s" % provisioner,
				"Reclaim policy: %s" % String(entry.get("reclaimPolicy", "Delete")),
				"Volume binding mode: %s" % String(entry.get("volumeBindingMode", "Immediate")),
			]),
			"Provisioner: %s" % provisioner,
			"Binding: %s" % String(entry.get("volumeBindingMode", "Immediate")),
			"healthy"
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_access_resource_items(context_name: String) -> Array:
	var items := []
	for entry in _get_optional_resource_json(context_name, PackedStringArray(["get", "serviceaccounts", "-A", "-o", "json"])).get("items", []):
		var metadata: Dictionary = entry.get("metadata", {})
		var namespace_name := String(metadata.get("namespace", "default"))
		var pull_secrets := entry.get("imagePullSecrets", []) as Array
		items.append(_make_resource_item(
			"ServiceAccount",
			"serviceaccount",
			String(metadata.get("name", "serviceaccount")),
			namespace_name,
			"Namespaced",
			"SERVICEACCOUNT | %s" % namespace_name.to_upper(),
			"\n".join([
				"Kind: ServiceAccount",
				"Name: %s" % String(metadata.get("name", "")),
				"Namespace: %s" % namespace_name,
				"Image pull secrets: %d" % pull_secrets.size(),
				"Created: %s" % String(metadata.get("creationTimestamp", "")),
			]),
			"Image pull secrets: %d" % pull_secrets.size(),
			"Scope: %s" % namespace_name,
			"healthy"
		))
	for entry in _get_optional_resource_json(context_name, PackedStringArray(["get", "roles", "-A", "-o", "json"])).get("items", []):
		items.append(_build_rbac_item(entry, "Role", "role", true))
	for entry in _get_optional_resource_json(context_name, PackedStringArray(["get", "rolebindings", "-A", "-o", "json"])).get("items", []):
		items.append(_build_binding_item(entry, "RoleBinding", "rolebinding", true))
	for entry in _get_optional_resource_json(context_name, PackedStringArray(["get", "clusterroles", "-o", "json"])).get("items", []):
		items.append(_build_rbac_item(entry, "ClusterRole", "clusterrole", false))
	for entry in _get_optional_resource_json(context_name, PackedStringArray(["get", "clusterrolebindings", "-o", "json"])).get("items", []):
		items.append(_build_binding_item(entry, "ClusterRoleBinding", "clusterrolebinding", false))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _build_helm_resource_items(context_name: String) -> Array:
	var items := []
	var result := _run_helm(PackedStringArray(["list", "-A", "-o", "json", "--kube-context", context_name] if not context_name.is_empty() else ["list", "-A", "-o", "json"]))
	if not bool(result.get("ok", false)):
		return items
	var parsed: Variant = JSON.parse_string(String(result.get("stdout", "")))
	if parsed is not Array:
		return items
	for entry in parsed:
		if entry is not Dictionary:
			continue
		var release := entry as Dictionary
		var namespace_name := String(release.get("namespace", "default"))
		var release_name := String(release.get("name", "release"))
		var status := String(release.get("status", "unknown"))
		items.append(_make_resource_item(
			"HelmRelease",
			"helmrelease",
			release_name,
			namespace_name,
			"Namespaced",
			"HELM | %s | REV %s" % [namespace_name.to_upper(), String(release.get("revision", "1"))],
			"\n".join([
				"Kind: Helm Release",
				"Name: %s" % release_name,
				"Namespace: %s" % namespace_name,
				"Status: %s" % status,
				"Chart: %s" % String(release.get("chart", "")),
				"App version: %s" % String(release.get("app_version", "")),
				"Updated: %s" % String(release.get("updated", "")),
			]),
			"Chart: %s" % String(release.get("chart", "")),
			"Status: %s" % status,
			"healthy" if status.to_lower() == "deployed" else "warning",
			1 if status.to_lower() == "deployed" else 0,
			1,
			[],
			false,
			false,
			false,
			false
		))
	items.sort_custom(func(a, b): return String(a.get("map_title", "")) < String(b.get("map_title", "")))
	return items


func _make_resource_item(kind: String, resource_type: String, name: String, namespace_name: String, scope: String, subtitle: String, overview_text: String, metrics_text: String, detail_footer: String, status_level: String, ready_count: int = 1, total_count: int = 1, ports: Array = [], supports_yaml: bool = true, supports_logs: bool = false, supports_exec: bool = false, supports_port_forward: bool = false, node_names: Array = [], extra: Dictionary = {}) -> Dictionary:
	var item := {
		"key": _resource_key(kind, namespace_name, name, scope),
		"kind": kind,
		"resource_type": resource_type,
		"name": name,
		"namespace": namespace_name,
		"scope": scope,
		"map_title": name.to_upper(),
		"map_subtitle": subtitle,
		"overview_text": overview_text,
		"metrics_text": metrics_text,
		"detail_footer": detail_footer,
		"status_level": status_level,
		"ready_pods": ready_count,
		"pod_count": max(total_count, 1),
		"ports": ports,
		"nodes": node_names,
		"supports_yaml": supports_yaml,
		"supports_logs": supports_logs,
		"supports_exec": supports_exec,
		"supports_port_forward": supports_port_forward,
	}
	for extra_key in extra.keys():
		item[extra_key] = extra[extra_key]
	return item


func _resource_key(kind: String, namespace_name: String, name: String, scope: String) -> String:
	if scope == "Cluster" or namespace_name.is_empty():
		return "%s/%s" % [kind, name]
	return "%s/%s/%s" % [kind, namespace_name, name]


func _warning_level(ready_count: int, total_count: int) -> String:
	if total_count <= 0:
		return "warning"
	if ready_count >= total_count:
		return "healthy"
	if ready_count <= 0:
		return "danger"
	return "warning"


func _get_optional_resource_json(context_name: String, args: PackedStringArray) -> Dictionary:
	var result := _run_kubectl(_with_context(args, context_name))
	if not bool(result.get("ok", false)):
		return {}
	return _parse_json_dictionary(String(result.get("stdout", "")))


func _run_helm(args: PackedStringArray) -> Dictionary:
	_apply_kubeconfig_path(_kubeconfig_path)
	var output: Array = []
	var exit_code := OS.execute("helm", args, output, true)
	var combined_output := ""
	if not output.is_empty():
		combined_output = "\n".join(output)
	return {
		"ok": exit_code == 0,
		"code": exit_code,
		"stdout": combined_output,
	}


func _service_ports(spec: Dictionary) -> Array:
	var ports := []
	for port_entry in spec.get("ports", []):
		ports.append(int(port_entry.get("port", 0)))
	return _unique_ints(ports)


func _template_ports(pod_spec: Dictionary) -> Array:
	var ports := []
	for container in pod_spec.get("containers", []):
		for port_entry in container.get("ports", []):
			ports.append(int(port_entry.get("containerPort", 0)))
	return _unique_ints(ports)


func _ingress_hosts(spec: Dictionary) -> Array:
	var hosts := []
	for rule in spec.get("rules", []):
		var host := String(rule.get("host", ""))
		if not host.is_empty():
			hosts.append(host)
	return _unique_strings(hosts)


func _filter_display_secrets(secret_items: Array) -> Array:
	var items := []
	for entry in secret_items:
		if entry is not Dictionary:
			continue
		var secret := entry as Dictionary
		var secret_type := String(secret.get("type", "Opaque"))
		var metadata: Dictionary = secret.get("metadata", {})
		var secret_name := String(metadata.get("name", ""))
		if secret_type == "kubernetes.io/service-account-token":
			continue
		if secret_name.begins_with("sh.helm.release.v1."):
			continue
		items.append(secret)
	return items


func _build_rbac_item(entry: Dictionary, kind_name: String, resource_type: String, namespaced: bool) -> Dictionary:
	var metadata: Dictionary = entry.get("metadata", {})
	var rules := entry.get("rules", []) as Array
	var namespace_name := String(metadata.get("namespace", ""))
	return _make_resource_item(
		kind_name,
		resource_type,
		String(metadata.get("name", resource_type)),
		namespace_name,
		"Namespaced" if namespaced else "Cluster",
		"%s | %d RULES" % [kind_name.to_upper(), rules.size()],
		"\n".join([
			"Kind: %s" % kind_name,
			"Name: %s" % String(metadata.get("name", "")),
			"Namespace: %s" % (namespace_name if namespaced else "cluster"),
			"Rules: %d" % rules.size(),
			"Created: %s" % String(metadata.get("creationTimestamp", "")),
		]),
		"Rules: %d" % rules.size(),
		"Scope: %s" % (namespace_name if namespaced else "cluster"),
		"healthy"
	)


func _build_binding_item(entry: Dictionary, kind_name: String, resource_type: String, namespaced: bool) -> Dictionary:
	var metadata: Dictionary = entry.get("metadata", {})
	var subjects := entry.get("subjects", []) as Array
	var role_ref: Dictionary = entry.get("roleRef", {})
	var namespace_name := String(metadata.get("namespace", ""))
	return _make_resource_item(
		kind_name,
		resource_type,
		String(metadata.get("name", resource_type)),
		namespace_name,
		"Namespaced" if namespaced else "Cluster",
		"%s | %d SUBJECTS" % [kind_name.to_upper(), subjects.size()],
		"\n".join([
			"Kind: %s" % kind_name,
			"Name: %s" % String(metadata.get("name", "")),
			"Namespace: %s" % (namespace_name if namespaced else "cluster"),
			"Role Ref: %s/%s" % [String(role_ref.get("kind", "")), String(role_ref.get("name", ""))],
			"Subjects: %d" % subjects.size(),
		]),
		"Subjects: %d" % subjects.size(),
		"Role Ref: %s" % String(role_ref.get("name", "")),
		"warning"
	)


func _format_label_dictionary(labels: Dictionary) -> String:
	if labels.is_empty():
		return "n/a"
	var parts := []
	for key in labels.keys():
		parts.append("%s=%s" % [String(key), String(labels[key])])
	return ", ".join(parts)


func _join_strings(values: Array) -> String:
	return ", ".join(values) if not values.is_empty() else "n/a"


func _join_ints(values: Array) -> String:
	if values.is_empty():
		return "n/a"
	var parts := []
	for value in values:
		parts.append(str(value))
	return ", ".join(parts)


func _format_status_counts(status_counts: Dictionary) -> String:
	var parts := []
	for key in status_counts.keys():
		parts.append("%s:%d" % [String(key), int(status_counts[key])])
	return ", ".join(parts) if not parts.is_empty() else "n/a"


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
		"cpu_percent": cpu_total / float(cpu_samples) if cpu_samples > 0 else -1.0,
		"memory_percent": memory_total / float(memory_samples) if memory_samples > 0 else -1.0,
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
	var metadata: Dictionary = event_item.get("metadata", {})
	var candidates := [
		_variant_to_string(event_item.get("lastTimestamp", null)),
		_variant_to_string(event_item.get("eventTime", null)),
		_variant_to_string(event_item.get("deprecatedLastTimestamp", null)),
		_variant_to_string(metadata.get("creationTimestamp", null)),
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
	_apply_kubeconfig_path(_kubeconfig_path)
	var command_args := PackedStringArray(["--request-timeout=%s" % KUBECTL_REQUEST_TIMEOUT])
	command_args.append_array(args)
	var output: Array = []
	var exit_code := OS.execute("kubectl", command_args, output, true)
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


func _build_demo_state(message: String, metrics_enabled: bool = false) -> Dictionary:
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
		"metrics_enabled": metrics_enabled,
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


func _ensure_kubectl_available() -> bool:
	if _kubectl_checked:
		return _kubectl_available
	var version_result := _run_kubectl(PackedStringArray(["version", "--client", "--output=json"]))
	_kubectl_checked = true
	_kubectl_available = bool(version_result.get("ok", false))
	return _kubectl_available


func _get_node_metrics(context_name: String) -> Dictionary:
	if _should_refresh_metrics(context_name):
		var result := _run_kubectl(_with_context(PackedStringArray(["top", "nodes", "--no-headers"]), context_name))
		_cached_node_metrics = _parse_node_metrics(String(result.get("stdout", "")))
	return _cached_node_metrics


func _get_pod_metrics(context_name: String) -> Dictionary:
	if _should_refresh_metrics(context_name):
		var result := _run_kubectl(_with_context(PackedStringArray(["top", "pods", "-A", "--no-headers"]), context_name))
		_cached_pod_metrics = _parse_pod_metrics(String(result.get("stdout", "")))
		_cached_metrics_context = context_name
		_last_metrics_refresh_msec = Time.get_ticks_msec()
	return _cached_pod_metrics


func _should_refresh_metrics(context_name: String) -> bool:
	if context_name != _cached_metrics_context:
		return true
	if _last_metrics_refresh_msec <= 0:
		return true
	return Time.get_ticks_msec() - _last_metrics_refresh_msec >= METRICS_CACHE_MSEC


func _normalize_kubeconfig_path(kubeconfig_path: String) -> String:
	var normalized_path := kubeconfig_path.strip_edges()
	if normalized_path.begins_with("file://"):
		normalized_path = normalized_path.trim_prefix("file://")
	if normalized_path.begins_with("~/"):
		var home_dir := OS.get_environment("HOME")
		if home_dir.is_empty():
			home_dir = OS.get_environment("USERPROFILE")
		if not home_dir.is_empty():
			normalized_path = home_dir.path_join(normalized_path.trim_prefix("~/"))
	if normalized_path.begins_with("res://") or normalized_path.begins_with("user://"):
		return ProjectSettings.globalize_path(normalized_path)
	return normalized_path


func _format_kubeconfig_error(prefix: String, command_output: String) -> String:
	var cleaned_output := command_output.strip_edges().replace("\n", " ")
	if cleaned_output.is_empty():
		return prefix
	return "%s %s" % [prefix, cleaned_output]


func _build_kubeconfig_import_error(kubeconfig_path: String, command_output: String) -> String:
	var file_name := kubeconfig_path.get_file()
	var config_hint := _detect_kubeconfig_mismatch(kubeconfig_path, command_output)
	if not config_hint.is_empty():
		var raw_detail := _format_kubeconfig_error("kubectl details:", command_output)
		return "%s\n\nFile: %s\n\n%s" % [
			"Selected file is not a valid Kubernetes kubeconfig.",
			file_name,
			"%s\n\n%s" % [config_hint, raw_detail],
		]
	return _format_kubeconfig_error(
		"Unable to read contexts from selected kubeconfig.",
		command_output
	)


func _detect_kubeconfig_mismatch(kubeconfig_path: String, command_output: String) -> String:
	var sample := _read_text_sample(kubeconfig_path, 4096)
	var lower_sample := sample.to_lower()
	var lower_output := command_output.to_lower()
	if lower_sample.contains("[interface]") or lower_sample.contains("[peer]") or kubeconfig_path.get_file().to_lower().begins_with("wg-"):
		return "\n".join([
			"It appears to be a WireGuard VPN config, not a kubeconfig.",
			"Import a Kubernetes kubeconfig YAML instead.",
			"Expected markers include: apiVersion: v1, kind: Config, clusters:, users:, contexts:.",
		])
	if lower_output.contains("couldn't get version/kind") or lower_output.contains("cannot unmarshal array") or lower_output.contains("json parse"):
		if not _looks_like_kubeconfig_text(sample):
			return "\n".join([
				"It does not match kubeconfig structure.",
				"Import a Kubernetes kubeconfig YAML instead.",
				"Expected markers include: apiVersion: v1, kind: Config, clusters:, users:, contexts:.",
			])
	return ""


func _looks_like_kubeconfig_text(sample: String) -> bool:
	if sample.is_empty():
		return false
	var lower_sample := sample.to_lower()
	var has_api_version := lower_sample.contains("apiversion:")
	var has_kind := lower_sample.contains("kind: config")
	var has_clusters := lower_sample.contains("clusters:")
	var has_contexts := lower_sample.contains("contexts:")
	return (has_api_version and has_kind) or (has_clusters and has_contexts)


func _read_text_sample(file_path: String, max_chars: int) -> String:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	if max_chars > 0 and text.length() > max_chars:
		return text.left(max_chars)
	return text


func _variant_to_string(value: Variant) -> String:
	if value == null:
		return ""
	return str(value).strip_edges()


func _apply_kubeconfig_path(kubeconfig_path: String) -> void:
	_kubeconfig_path = kubeconfig_path
	OS.set_environment("KUBECONFIG", _kubeconfig_path)


func _reset_live_caches() -> void:
	_cached_node_metrics.clear()
	_cached_pod_metrics.clear()
	_cached_metrics_context = ""
	_last_metrics_refresh_msec = 0


func _load_saved_kubeconfig() -> void:
	var settings := ConfigFile.new()
	var load_error := settings.load(SETTINGS_FILE)
	if load_error != OK:
		return
	_force_demo_mode = bool(settings.get_value(SETTINGS_SECTION, SETTINGS_KEY_FORCE_DEMO, false))
	var configured_path := _normalize_kubeconfig_path(String(settings.get_value(SETTINGS_SECTION, SETTINGS_KEY_KUBECONFIG, "")))
	if _force_demo_mode:
		_apply_kubeconfig_path("")
		return
	if configured_path.is_empty():
		return
	if not FileAccess.file_exists(configured_path):
		return
	_apply_kubeconfig_path(configured_path)


func _save_settings() -> int:
	var settings := ConfigFile.new()
	settings.set_value(SETTINGS_SECTION, SETTINGS_KEY_KUBECONFIG, _kubeconfig_path)
	settings.set_value(SETTINGS_SECTION, SETTINGS_KEY_FORCE_DEMO, _force_demo_mode)
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
