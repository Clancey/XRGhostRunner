# XRGhostRunner

A Godot tool project for full XR input capture and deterministic replay.

## Addon distribution

- Release/source archives are configured to include only `addons/`.
- Install by extracting the archive into your project root so you get:
  - `res://addons/xr_ghost_runner/...`
- Enable plugin: `Project > Project Settings > Plugins > XRGhostRunner`.
- Enabling the plugin auto-registers the `XRInputTape` autoload singleton.

## What it does

- Records every `InputEvent` from game start.
- Records per-physics-frame XR tracker snapshots from `XRServer`.
- Replays both event stream and tracker state back into Godot so gameplay can be re-run deterministically.
- Streams capture data to disk asynchronously (writer thread), so long sessions do not accumulate in-memory arrays.
- Streams replay data from disk asynchronously (reader prefetch thread), reducing IO work on frame callbacks.
- Uses bounded async queues with lightweight counters to avoid unbounded memory growth.
- Uses adaptive frame sampling under sustained writer pressure (e.g., every 2nd/4th frame) to preserve overall session continuity.
- Disables `_input`, `_process`, and `_physics_process` callbacks while idle (not recording/replaying) to minimize overhead.

Captured XR tracker data includes:

- positional tracker poses (`default`, `aim`, `grip`, etc. + custom probe names)
- controller input values
- hand tracking joints (transform, flags, velocities, radius)
- body tracking joints (transform, flags)
- face tracking blend shapes

## Runtime singleton

- Autoload name: `XRInputTape`
- Script: `res://addons/xr_ghost_runner/xr_input_tape.gd`

## Godot version

Validated against Godot `4.6.2.rc` locally.

## CLI usage

`XRInputTape` accepts `--xrg-*` args either directly or after `--`.

```bash
# Record from startup
# if path is omitted, auto-generates:
# user://captures/run_YYYYMMDD_HHMMSS_UUUUUU.xrtape
godot --path . --xrg-record

# record to a specific path
godot --path . --xrg-record user://captures/run_01.xrtape

# Replay from startup
godot --path . --xrg-replay user://captures/run_01.xrtape

# Replay then quit automatically (useful for CI)
godot --path . --xrg-replay user://captures/run_01.xrtape --xrg-auto-quit

# Equivalent style, also supported:
godot --path . -- --xrg-record
```

Useful options:

- `--xrg-frame-step N` capture tracker snapshots every `N` physics ticks
- `--xrg-no-frame-capture` disable tracker snapshots (events-only)
- `--xrg-no-adaptive-sampling` disable dynamic frame thinning
- `--xrg-adaptive-max-step N` cap adaptive frame step multiplier (default `8`)
- `--xrg-pose-name NAME` add extra pose probe name(s)
- `--xrg-input-name NAME` add extra controller input probe name(s)

## Smoke tests

Run from project root:

```bash
# 1) Parse check (no run)
godot --headless --path . -s res://addons/xr_ghost_runner/xr_input_tape.gd --check-only

# 2) Record smoke capture
godot --headless --path . --quit --xrg-record user://captures/smoke.xrtape

# 3) Replay smoke capture
godot --headless --path . --xrg-replay user://captures/smoke.xrtape --xrg-auto-quit

# 4) Replay fixture capture in repo (if present)
godot --headless --path . --xrg-replay res://test_data/run_20260220_214516_579040.xrtape --xrg-auto-quit
```

Expected success signals in logs:

- `Loaded stream tape: ...`
- `Replaying XR input from ...`
- `Replay finished (N events, M frames).`

## Output location (`user://`)

- Default recordings are written under `user://captures/`.
- `user://` is a per-project user-data directory, not your project source folder.

Desktop `user://` base paths (from the official docs):

| Type | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Default | `%APPDATA%\Godot\app_userdata\[project_name]` | `~/Library/Application Support/Godot/app_userdata/[project_name]` | `~/.local/share/godot/app_userdata/[project_name]` |
| Custom dir | `%APPDATA%\[project_name]` | `~/Library/Application Support/[project_name]` | `~/.local/share/[project_name]` |
| Custom dir and name | `%APPDATA%\[custom_user_dir_name]` | `~/Library/Application Support/[custom_user_dir_name]` | `~/.local/share/[custom_user_dir_name]` |

- On mobile, `user://` is unique to the project sandbox.
- On HTML5 exports, `user://` is a virtual filesystem backed by IndexedDB.
- To print the exact resolved path in your environment:

```gdscript
print(ProjectSettings.globalize_path("user://"))
```

- Platform-specific details: [Godot data paths](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)

## API usage (from game code)

```gdscript
# Start/stop recording manually
XRInputTape.start_recording() # auto run_YYYYMMDD_HHMMSS_UUUUUU.xrtape under user://captures/
XRInputTape.start_recording("user://captures/run_02.xrtape")
XRInputTape.stop_recording()

# Start replay manually
XRInputTape.start_replay("user://captures/run_02.xrtape")

# Optional runtime metrics (queue depth, drops, waits, peaks)
var metrics := XRInputTape.get_stream_metrics()
```

## Tape format

Recordings are streamed in 3 binary files:

- `run_01.xrtape` (metadata + format/version)
- `run_01.xrtape.events` (input event stream)
- `run_01.xrtape.frames` (tracker frame stream)

All records use `FileAccess.store_var(..., true)` for full-fidelity Godot variant/object serialization.

Full schema/reference:

- `docs/CAPTURE_FORMAT.md`
