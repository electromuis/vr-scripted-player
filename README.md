# Scripted VJ Video Player

A scripted, VJ-style video player built in Godot 4.4. Music video plays while a JSON script drives keyframed events on top of it — screen/projection transforms, spawning and moving objects, and shaders on cameras and objects. VR-capable via OpenXR.

See [Scripted VJ Video Player — Project Plan.md](./Scripted%20VJ%20Video%20Player%20%E2%80%94%20Project%20Plan.md) for the full plan.

## Repository layout

- `player/` — the standalone runtime (main scene, script format, evaluator, VR)
- `addons/vj_editor/` — the Godot editor plugin (timeline dock, track editors)
- `examples/` — sample scripts
- `tests/` — GUT unit tests
- `docs/` — schema reference, authoring guide, player usage

## Status

**Phase 0 — Foundation.** Project scaffold in place; minimal scene loads and parses a script. Video decoding on Windows and OpenXR sanity check still to be validated.

## Prerequisites

- Godot 4.4 stable (Windows binary at `C:\ProgramData\chocolatey\lib\godot\tools\Godot_v4.4-stable_win64.exe` in this dev environment)
- For MP4 playback: [`godot-videodecoder`](https://github.com/EIREXE/godot-videodecoder) addon — see [`docs/videodecoder_install.md`](./docs/videodecoder_install.md)
- For VR: SteamVR or another OpenXR runtime

## Installing godot-xr-tools

`godot-xr-tools` is not tracked in this repo (release binaries required). Install it manually before opening the project:

1. Download the latest release from https://github.com/GodotVR/godot-xr-tools/releases
2. Extract the `addons/godot-xr-tools/` folder into `project_engine/addons/godot-xr-tools/`
3. Open the project in Godot — the addon should be picked up automatically
