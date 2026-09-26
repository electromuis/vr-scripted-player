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

## Using it as a VR media player

Open a video or a script from **F2 → Files**, by dropping it on the window, or with `--script <file>`. A plain video plays on the default screen; a same-name `.json` next to a video (`clip.mp4` + `clip.json`) is used as its script. A script that spawns its own `main_screen`, or sets `"meta": {"default_screen": false}`, replaces the default screen.

- **Network (DLNA):** **F2 → Network** lists DLNA/UPnP media servers on the LAN (MiniDLNA, Plex, Jellyfin, Serviio, Windows Media sharing, …); browse folders and pick a video to stream it. `http(s)://` URLs also work anywhere a video path does (`--script <url>`, a script's `media.video`).
- **Thumbnails:** Files and Network show the thumbnails the OS or server already has. On Windows these are Explorer's, via a small background PowerShell helper. On Linux they come from the freedesktop cache, and for DLNA they're the server's album art or `JPEG_TN` images. The player never generates its own. The **Tiles / List** button switches the layout for both tabs, and the choice is remembered.
- **Projection** is detected from the filename (for DLNA items, from the title) (`_180`, `_360`, `_LR`/`_SBS`, `_TB`/`_OU`, …) and can be overridden in **F2 → Camera**.
- **Movement** is locked by default (**F2 → Config**). While locked, the thumbsticks seek ±10 s (left/right) and change volume (up/down). Right stick click resets the view, right **A** plays/pauses. Desktop: ←/→ seek, ↑/↓ volume, Space/K play/pause, R reset view.
- **Presets and scripts:** your screen presets (size, distance, curvature, effects, layers) apply to plain videos. A script plays with the locked preset 0, **Script (defaults)**, so it looks the way it was authored; your previous preset comes back when you open a plain video. You can still adjust sliders or pick a preset by hand during a script.
- **Shader layers:** **F2 → Camera → Layers** sets how many sound-reactive shader layers there are (0 to start). **Adjust** picks the screen or a layer; for a layer, pick its shader from the Shader dropdown and the sliders move that layer relative to the screen (layers are attached to the screen, so moving or animating the screen carries them along), and presets save everything. Layers and the video draw back to front by depth, so **Distance** decides what's in front: a new layer sits just in front of the video (later layers slightly further forward), and pushing it back puts it behind. **Lock to screen** keeps a layer centred on the video screen, following it wherever it moves, at its own size; Distance then moves it in front of or behind the screen. To fill the whole view, set a layer's size high and use **Curvature** and **V. curvature** together, which bow it into a dome around you. Two shaders are built in. To add more, drop Shadertoy code as-is (the `mainImage` function, saved as `.glsl`) into `%APPDATA%\Godotpp_userdata\Scripted VJ Video Player\shaders\` or a `shaders` folder next to the `.exe`. `iChannel0` is the music input (Shadertoy's 512×2 spectrum and waveform texture), and `iTime` and `iResolution` work. Mouse, keyboard, texture channels and multipass buffers don't. Godot `canvas_item` shaders (`.gdshader`) work too, and can include `res://player/visualizer/shadertoy_prelude.gdshaderinc` for the same inputs plus `audio_bass` / `audio_mid` / `audio_high` / `audio_level`.
  - **Shader hints:** a comment `// @resolution 1024x1024` sets the pixel size a layer renders at, and its screen takes that shape (square, here); the default is 960×540. Every `uniform float`/`int` with a `hint_range(min, max[, step])`, and every `uniform bool`, gets a slider or checkbox under the layer's sliders, saved in presets.
  - **Video input:** a comment `// @iChannel1 video` (any of iChannel0–3) feeds that channel the playing video's frame, top row at v = 0; iChannel0 stays the audio unless tagged. The layer then takes the video's shape and stereo layout like the main screen (for stereo, the whole frame goes in and the output is split per eye; `video_stereo` is 0 mono / 1 side-by-side / 2 top-bottom, so blurs can clamp to one eye), so **Lock to screen** at size 1 lines it up with the video. `// @resolution 270` gives just a height, the width following the shape. The built-in **Video blur** does this at 270 px tall: lock it a little behind and larger than the screen, and put **Edge blur** on the screen, for a glow around the video.
- **Effects:** the screen and every layer have an effect list (**+ Effect**, then pick one; **−** removes it). Effects run in order on the output (the video, or the layer's shader) and each gets its own hint controls. Built in: **Key black** (black becomes transparent, for laying a shader over the video) and **Oval mask** (sets the alpha on one side of an oval to 0 = cut away or 1 = solid, with size, ratio and blur; a blurred mask on the screen fades the video into the layers behind it) and **Edge blur** (blurs the alpha to soften whatever edges earlier effects or the shader cut out, over a set radius; *inward* keeps the fade inside the shape, off centres it on the edge) and **Padding** (a transparent margin, *amount* × the picture's height on each side: the effects after it, and the screen, grow by it while the picture keeps its size, so an outward Edge blur or a Glow isn't cut off at the edge; flat screens only) and **Glow** (a bright, blurred reflection of the picture in its own edge as a halo, plus an inner glow along the edge; put Padding before it, the halo draws in its margin) and **Crop** (shows a sub-rectangle of the picture over the whole screen, e.g. one third for split screens; put it first) and **Rounded corners** (cuts the picture's corners round in alpha, with separate x and y radius for elliptical corners; an Edge blur after it softens them) and **Keep center** (for a scaled-up screen or layer: set *zoom* to its Size and the middle *center* part of the picture stays about its original size while the rest stretches out to the edges; *softness* blends the two, *horizontal* / *vertical* pick the axes). On stereo video effects run per eye. To write one, make a `.gdshader` that includes `res://player/visualizer/effect_prelude.gdshaderinc` and samples `input_tex` at `UV` (`display_aspect` is the screen's width / height); it goes in the same `shaders` folder and shows up in the effect picker instead of the shader list.
- **Skybox** is black by default; other options, plus any panorama images in the `skyboxes` folders listed in **F2 → Config**.
- **FPS:** **F2 → Config → FPS** shows the frame rate at the start of the desktop top bar and on the wrist HUD.
- **Fullscreen / play bar:** **F11** toggles fullscreen and **H** hides or shows the bottom play bar on the desktop window. Both are also in **F2 → Config**, and they stay set the next time you open the player.
- **Timecode:** a Whirligig-compatible server runs on `127.0.0.1:2000` for MultiFunPlayer / ScriptPlayer. `--whirligig-port N` changes it (0 = off), `--whirligig-lan` accepts other machines.

## Builds and releases (CI)

`.github/workflows/build.yml` runs on every push and pull request:

1. **gde_gozen:** builds FFmpeg + gde_gozen (debug and release) for Linux x86_64, Windows x86_64, macOS arm64 + x86_64 and Android arm64 (Quest 3). The source is `GOZEN_GIT_URL` @ `GOZEN_REF` (default: [Codeberg upstream](https://codeberg.org/gozen/gde_gozen)), plus any patches in `ci/gde_gozen/patches/` (see the README there for our audio loading fix). Builds are cached in three layers: the finished library per gde_gozen commit + patches (nothing rebuilds), FFmpeg and its libraries per dependency commit + `build.py` (a new gde_gozen commit, e.g. a push to the fork, skips the 15–30 min FFmpeg build), and SCons' object cache (only changed C++ files recompile). The binaries are never uploaded as artifacts: the other jobs restore them from that cache.
2. **Tests:** imports the project with Godot 4.7.2, checks gde_gozen loads (`tests/check_extensions.gd`), runs `tests/run.gd`.
3. **Export and package:** exports with `project_engine/export_presets.cfg` and uploads one artifact holding:
   - Windows: `-setup.exe` installer and a portable `.zip`
   - Linux: `.deb` and a portable `.tar.gz`
   - macOS: universal `.app` in a `.zip` (ad-hoc signed, not notarized: right-click → Open the first time)
   - Quest 3: `.apk` (sideload with `adb install` or SideQuest; Meta OpenXR vendors plugin)
   - `-portable-all-platforms.zip` with all of the above unpacked
   Windows and Linux builds carry no loose gde_gozen library: it is packed into the `.pck` inside the executable, and `player/runtime/gozen_loader.gd` (the first autoload) writes it to `user://gozen/` and loads it on startup. On macOS and Quest it is inside the `.app` / `.apk`, as usual.
4. **Release:** pushing a tag `v*` (`git tag v0.2.0 && git push origin v0.2.0`) creates a GitHub release with those files, and the commit messages since the previous tag as its notes. Tags with a `-` (`v0.2.0-beta`) are marked pre-release.

The Quest APK is signed with the `ANDROID_KEYSTORE_BASE64` (base64 of the `.keystore`), `ANDROID_KEYSTORE_USER` (key alias) and `ANDROID_KEYSTORE_PASSWORD` repository secrets. Without them CI signs it with a throwaway key, and each build then has to be uninstalled before the next one installs.

The helper scripts in `ci/` work locally too: `ci/setup_godot.sh --templates`, `ci/fetch_addons.sh [--android]`, `ci/build_gozen.sh <platform> <arch>`, `ci/package.sh <version>`.

## Prerequisites

- Godot 4.4 stable (Windows binary at `C:\ProgramData\chocolatey\lib\godot\tools\Godot_v4.4-stable_win64.exe` in this dev environment)
- For MP4 playback: [`godot-videodecoder`](https://github.com/EIREXE/godot-videodecoder) addon — see [`docs/videodecoder_install.md`](./docs/videodecoder_install.md)
- For VR: SteamVR or another OpenXR runtime

## Installing godot-xr-tools

`godot-xr-tools` is not tracked in this repo (release binaries required). Install it manually before opening the project:

1. Download the latest release from https://github.com/GodotVR/godot-xr-tools/releases
2. Extract the `addons/godot-xr-tools/` folder into `project_engine/addons/godot-xr-tools/`
3. Open the project in Godot — the addon should be picked up automatically
