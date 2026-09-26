# VR Studio — Plan and handoff

Working notes for building a VR editor ("Studio") for VJ scripts: edit a piece from inside the headset with wrist tools. This records the decisions made so far, what's done, and what comes next, so work can resume in a fresh session.

Branch: `claude/sweet-bardeen-mjgzvk` (commits `8a44787`, `04f3be3` on top of `89d4579`).

## Decisions

1. **The script JSON is the master format**, not a Godot source project.
   - The VR editor runs on the player's own renderer, so what you see in the headset is what the player shows. That's the reason VR editing is worth doing at all.
   - The format is now lossless for animation (bezier handles, true cubic; see *Done*), which was the main argument against it.
   - It keeps the plan's founding goal: scripts can be edited by hand, diffed and shared as a zip, with no Godot install needed.
2. **A Godot scene is a view of the JSON, never a second master.**
   - Import only into an **empty project**; there is never any merging into an existing scene.
   - The imported scene's `output_path` points back at the JSON, so exporting writes the master.
   - Rule for artists: anything that must survive belongs in the JSON or inside a prefab. Loose scene furniture is lost on the next round trip.
3. **Studio is a separate app, but not a separate codebase.**
   - It has its own main scene and export preset in `project_engine/`, and shares the player's rendering core.
   - Dependencies go one way: `studio/` uses `player/stage/`, and nothing in `player/` references `studio/`.
   - Studio doesn't need DLNA, the playlist, Whirligig or live sync.
4. **Studio edits the JSON directly**, reusing the player's existing load, hot-reload and reconcile path. Live sync with the Godot editor isn't needed for it.

Rejected alternatives, and why:
- **Studio inside the addon, editing `.tscn` at runtime:** it would render with the addon's preview copies rather than the player, and saving a scene at runtime is risky (owners, instances, local-to-scene materials).
- **Merging a JSON into an existing scene:** it's a 3-way merge; not worth it.
- **Existing runtime-editor addons:** we checked Godot4xGizmo, 3D Gizmo Tool, DsInspector, Inspector Gadget, and the Godot editor running on Quest. None handle "change → keyframe at the current time → persist", and the Quest editor is standalone Android while gde_gozen is a Windows FFmpeg extension. Use **XR Tools** instead: `XRToolsPickable` for grabbing, `XRToolsInteractableHinge` / `Slider` / `Joystick` for knobs and faders, and `Viewport2DIn3D` for wrist panels.

## Done

### Script format v2 (`8a44787`)
- **Interpolation modes:** `interp` can be `linear` (default), `step`, `ease` (per-segment smoothstep), `cubic` or `bezier`.
  - `cubic` is Godot's time-aware Catmull-Rom (`cubic_interpolate_in_time`).
  - `bezier` keys carry `in` / `out` handles as `[dt, dv]` relative to the key, one pair per element for arrays. The player solves them exactly as Godot's `bezier_track_interpolate` does (10-step bisection).
- **v1 files still load:** their `cubic` is rewritten to `ease` on load (`ScriptFormat._upgrade`), because v1's cubic was a smoothstep. The player accepts versions 1–2; exporters write 2.
- **Exporter no longer bakes bezier tracks.** Where components have keys at different times, each curve is split exactly with de Casteljau; segments with flat handles export as `linear`.
  - Forest tunnel: 174 KB (2,080 keys) → 37 KB (175 keys), now exactly the editor's curves.
- **Previous mismatch fixed:** the player's `cubic` used to be a smoothstep while Godot's is a spline, so motion differed from the editor. They now match.
- **Tests:** `project_engine/tests/test_interpolation.gd` compares against Godot's own `Animation` interpolation (cubic within 1e-4, bezier within 1e-5).

### Importer and format gaps (`04f3be3`)
- **Importer:** `addon_vj/importer/script_importer.gd`, the exporter in reverse.
  - **Tools > VJ: Import script.json…** (or `importer/run_import.gd -- <json>` headless) writes `res://main.tscn`, makes it the main scene, and copies custom prefabs to `prefabs/` and shaders to `shaders/`.
  - It refuses a project that already has scenes outside `addons/`.
- **What converts exactly:** everything the exporter writes. Hand-written-only features are converted or dropped with a warning:
  - an `ease` track, or one mixing interpolations → Bezier tracks with equivalent handles (ease and cubic segments convert exactly)
  - `step` mixed with other modes → holds until 1 ms before the next key
  - an object respawned with a different config → keeps its first spawn's
  - cuts with different transitions → all get the first one's (the scene's viewer has one)
  - `vr_teleport`, top-level `objects` (the player ignores these too) and `media.audio` → dropped
- **Format gaps closed:**
  - Switched-off effects export as `"enabled": false`. The player skips them and doesn't count them in `effect<N>`.
  - A viewer start pose away from home (0, 2, 8) exports as a hard `vr_cut` at t=0.
- **Round-trip test:** `addon_vj/tests/run_roundtrip.gd` imports and exports every JSON in `scripts/` and `addon_vj/tests/fixtures/` twice. It fails if playback differs (every track sampled through the player's `Interpolation`) or the export changes on the second pass.
  - All pass, including a hand-written fixture that covers every conversion.
  - I broke the importer on purpose to confirm the test catches it.
  - Forest tunnel imported, saved to `.tscn`, reloaded and exported with 0 differences from the original.

## Next: step 3 — Studio

### 3a. Extract the rendering core from `project_engine/player/main.gd` (about 1,050 lines)
It mixes two jobs:
- **Core (Studio needs it):** video bridge, script runner hookup, screen settings / `_apply_screen_settings`, layers (`_rebuild_layers`, `_place_layer`, `_update_layer_anchor`), curvature, projection, XR rig, camera cuts.
- **Shell (player only):** file open and drop, DLNA, playlist, Whirligig, presets UI, media keys, thumbstick seek and volume, menus.

Move the core into `player/stage/` (a scene plus script), with no change in behaviour. `main.tscn` becomes stage + shell. Check with the 137-test suite, then **on a headset**, because the headless tests can't cover VR.

### 3b. Studio skeleton
`project_engine/studio/studio.tscn` = stage + XR rig + studio tools. It opens a script JSON (command-line argument), and writes the JSON back on save (the player's file watcher / reconcile already handles reloading).

Add a second export preset *Studio*, and give the *Player* preset an export filter that excludes `studio/`.

### 3c. First tool: grab & key
Make screens and layers `XRToolsPickable`. On release, write a transform keyframe at the playhead into the JSON (make the track if missing; replace a key at the same time). Show ghost markers where the existing keys are.

### Later wrist tools (left wrist panel, right hand acts)
- **Param knob + record:** twist a hinge or knob (or use the thumbstick) on a shader param. Record mode captures it while the music plays as a dense key stream, then thins it (to linear keys within a tolerance, or to beziers). This is probably the most valuable feature, since hand-keying timing to music is tedious.
- **Key navigator:** previous / next key, delete key, scrub dial. Needed so mistakes can be fixed.
- **Cut marker:** drop a `vr_cut` from where you're standing now.
- **Keep on the desktop, not in VR:** precise timing, easing curves and many-track editing. VR is for recording and nudging; the desktop is for cleanup (via import → edit → export).

### Prerequisites and risks
- **Phase 4b headset checklist:** the wrist HUD, and pointer clicks in every menu tab, aren't recorded as confirmed. Make the pointer UI solid before adding editing tools on top.
- **Seeking back past a cut:** the player doesn't restore the camera when seeking back past a `vr_cut` or the t=0 start-pose cut. That will matter for editing.
- **`_read_transform` in `script_runner.gd`:** it builds `Basis.from_euler(rot).scaled(scl)`. `scaled` applies scale on global axes, while Godot nodes (and the importer) use rotation × local scale. With non-uniform scale plus rotation the player may not match the editor. Verify before Studio writes transforms.

## Known issues (not caused by this work)
- `test_addon_shaders_match_player` fails: the addon's `rounded_corners.gdshader` copy differs from the player's.
- `test_forest_tunnel_scene_states` fails: the committed `scripts/forest_tunnel/video.json` export is stale (the scene now has a `screen_master` group). Re-export from the editor, which also gives it the exact bezier curves. It's still a v1 file.
- `scripts/minimal` has no objects, so the exporter refuses it (by design). The round-trip test skips it.

## Working in the cloud container
- **No Godot preinstalled.** Download the project's version (4.7.1):
  `curl -sSL -o g.zip https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip && unzip g.zip`
  Godot 4.4 silently drops parts of 4.7-saved scenes (`libraries/ =`, `unique_id=`); don't use it.
- **Player tests:** `cd project_engine && godot --headless --import && godot --headless --script res://tests/run.gd`. The XR Tools and gde_gozen errors in the output are expected (not installed here).
- **Round-trip test:** link the addon into an authoring project first (gitignored, like your Windows junctions): `ln -sfn ../../addon_vj project_script_example/addons/vj_editor`. Then `cd project_script_example && godot --headless --import && godot --headless --script res://addons/vj_editor/tests/run_roundtrip.gd`.
- **Stray `.import` edits:** headless `--import` rewrites a few `.import` files (gde_gozen icons, `effect_icon.svg.import`). Revert them with `git checkout` before committing. `.uid` files and `.godot/` are gitignored.
