#!/usr/bin/env bash
# Sets up a cloud container (Linux, no headset, no GPU) to test and *see*
# the player: Godot 4.7.1, XR Tools, Mesa's software Vulkan (for Forward+ /
# compositor effects), and a copy of project_engine that runs without the
# gde_gozen video decoder (no Linux binary). Everything goes in $WORK
# (default /tmp/vj_cloud); the repo only gets the gitignored XR Tools.
#
#   tools/cloud/setup.sh            # once per container
#   tools/cloud/run.sh checks/shot_fx.gd      # re-sync the copy and run a check
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/vj_cloud}"
mkdir -p "$WORK"
cd "$WORK"

# Godot (the projects target 4.7; 4.4 silently drops parts of 4.7 scenes).
if [ ! -x godot/Godot_v4.7.1-stable_linux.x86_64 ]; then
	mkdir -p godot
	curl -sSL -o godot/g.zip https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip
	(cd godot && unzip -oq g.zip)
fi

# XR Tools into the real project (gitignored), patched for Godot 4.7.
XRT="$REPO/project_engine/addons/godot-xr-tools"
if [ ! -d "$XRT" ]; then
	curl -sSL -o xrt.zip https://github.com/GodotVR/godot-xr-tools/releases/download/4.5.1/godot-xr-tools.zip
	unzip -oq xrt.zip -d xrt
	cp -r xrt/godot-xr-tools/addons/godot-xr-tools "$REPO/project_engine/addons/"
fi
python3 - "$XRT/objects/viewport_2d_in_3d.gd" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''		"filter":
			return true


# When the scene_node changes'''
if old in s:
	s = s.replace(old, '''		"filter":
			return true
	return null


# When the scene_node changes''')
	open(p, "w").write(s)
PY

# Software Vulkan (lavapipe), unpacked locally.
if [ ! -f vk/lvp.json ]; then
	mkdir -p vk
	(cd vk && (apt-get update >/dev/null 2>&1 || true) && apt-get download mesa-vulkan-drivers >/dev/null 2>&1 && dpkg-deb -x mesa-vulkan-drivers_*.deb root)
	sed "s#\"libvulkan_lvp.so\"#\"$WORK/vk/root/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so\"#" \
		vk/root/usr/share/vulkan/icd.d/lvp_icd.json > vk/lvp.json
fi

# The engine copy is (re)made by run.sh on every run.
echo "Ready. Godot: $WORK/godot/Godot_v4.7.1-stable_linux.x86_64"
echo "Player tests: cd project_engine && \$GODOT --headless --import && \$GODOT --headless --script res://tests/run.gd"
