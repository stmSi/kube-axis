# KubeAxis

Godot 4 desktop prototype for a futuristic Kubernetes command surface.

## What it does

- Recreates the `concept.png` layout with a left navigation rail, central topology map, right-side inspector, and bottom event/metrics/terminal panes.
- Reads live cluster data through `kubectl` when a local kube context is available.
- Falls back to a built-in demo cluster when `kubectl` is missing or the cluster cannot be queried.
- Supports workload inspection, pod logs, YAML view, shell command generation, and `kubectl port-forward`.

## Requirements

- Godot `4.6.x`
- `kubectl` in `PATH` for live mode
- A valid local kubeconfig for cluster access

## Run

```bash
godot --path .
```

## Notes

- `Exec Shell` opens an external terminal when one of `x-terminal-emulator`, `gnome-terminal`, `konsole`, or `xterm` is available.
- `Port Forward` starts a background `kubectl port-forward` process and the button toggles into a stop action.
- `Import Config` lets you select a kubeconfig file from disk; the selected path is persisted in `user://kube_axis.cfg` and applied as `KUBECONFIG`.
- The dashboard auto-refreshes every 8 seconds.
