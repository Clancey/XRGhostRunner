# XRGhostRunner Capture Format

This document specifies how captures are written and read by `XRInputTape`.

## Serialization

- All stream files are binary and use Godot Variant serialization via:
  - `FileAccess.store_var(value, true)` for writing
  - `FileAccess.get_var(true)` for reading
- Object serialization is enabled (`full_objects=true`).

## Current format (stream, version 3)

Base capture path example:

- `user://captures/run_20260220_120000_123456.xrtape`

Files written:

- `*.xrtape` (metadata header dictionary)
- `*.xrtape.events` (append-only stream of event records)
- `*.xrtape.frames` (append-only stream of frame records)

### 1) Metadata file (`*.xrtape`)

Single dictionary written at file start:

```gdscript
{
  "format": "xrg_stream",
  "version": 3,
  "complete": bool,
  "created_unix": int, # unix seconds
  "event_count": int,  # accepted records
  "frame_count": int,  # accepted records
  "meta": {
    "pose_names": Array[String],
    "controller_input_names": Array[String],
  },
  "files": {
    "events": String, # path to .events file
    "frames": String, # path to .frames file
  },
  "stats": {
    "events_dropped": int,
    "frames_dropped": int,
    "peak_queue_events": int,
    "peak_queue_frames": int,
    "adaptive_sampling_enabled": bool,
    "adaptive_frame_step": int,
    "effective_frame_interval": int,
  },
}
```

Notes:

- `complete=false` is written when recording starts.
- On clean stop, metadata is rewritten with `complete=true`.
- If writer failure occurs, metadata remains/inverts to `complete=false`.

### 2) Event stream file (`*.xrtape.events`)

Sequence of dictionaries. Each valid record must include:

```gdscript
{
  "t_usec": int,      # microseconds since recording start
  "event": InputEvent # serialized Godot InputEvent object
}
```

Replay reader behavior:

- Skips non-dictionary records.
- Skips dictionaries missing `t_usec` or `event`.
- Replays via `Input.parse_input_event(event)` when `t_usec <= elapsed_usec`.

### 3) Frame stream file (`*.xrtape.frames`)

Sequence of dictionaries. Each valid record must include:

```gdscript
{
  "t_usec": int,        # microseconds since recording start
  "trackers": Array[Dictionary]
}
```

Each tracker dictionary contains:

```gdscript
{
  "name": String,
  "type": int,   # XRServer tracker type
  "desc": String,
  "class": String, # e.g. XRPositionalTracker, XRControllerTracker, ...

  # optional blocks, present by tracker capabilities:
  "positional": {
    "tracker_profile": String,
    "tracker_hand": int,
    "poses": {
      pose_name: {
        "has_tracking_data": bool,
        "transform": Transform3D,
        "linear_velocity": Vector3,
        "angular_velocity": Vector3,
        "tracking_confidence": int,
      }
    }
  },
  "controller": {
    "inputs": { input_name: Variant }
  },
  "hand": {
    "has_tracking_data": bool,
    "hand_tracking_source": int,
    "joints": Array[{
      "flags": int,
      "transform": Transform3D,
      "radius": float,
      "linear_velocity": Vector3,
      "angular_velocity": Vector3,
    }]
  },
  "body": {
    "has_tracking_data": bool,
    "body_flags": int,
    "joints": Array[{
      "flags": int,
      "transform": Transform3D,
    }]
  },
  "face": {
    "blend_shapes": Dictionary
  },
}
```

Replay reader behavior:

- Skips non-dictionary records.
- Skips dictionaries missing `t_usec` or `trackers`.
- Applies frames when `t_usec <= elapsed_usec`.
- Trackers are resolved by `name`; missing trackers are created on demand.

## Path resolution on replay

Replay loads `*.xrtape` first and verifies:

- `format == "xrg_stream"`
- `version == 3`

Then sidecar paths are resolved from:

- `header["files"]["events"]` and `header["files"]["frames"]` when present
- otherwise defaulting to `path + ".events"` and `path + ".frames"`

## Replay compatibility policy

- Replay is stream-only.
- Valid captures must provide `format == "xrg_stream"` and `version == 3`.
- Non-stream/legacy files are not loaded.

## Timing model

- `t_usec` values are relative to recording start time.
- Replay is real-time gated using elapsed microseconds from replay start.
- Event and frame streams are consumed independently but synchronized by timestamps.
