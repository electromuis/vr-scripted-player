#!/usr/bin/env bash
# Installs the third-party addons that aren't tracked in git into
# project_engine/addons/.
#
#   ci/fetch_addons.sh            godot-xr-tools
#   ci/fetch_addons.sh --android  also the OpenXR vendors plugin (Meta Quest)
set -euo pipefail

XR_TOOLS_VERSION="${XR_TOOLS_VERSION:-4.5.1}"
OPENXR_VENDORS_VERSION="${OPENXR_VENDORS_VERSION:-5.1.0-stable}"
ADDONS="$(cd "$(dirname "$0")/../project_engine/addons" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$ADDONS/godot-xr-tools" ]; then
  curl -fsSL --retry 4 -o "$TMP/xrt.zip" \
    "https://github.com/GodotVR/godot-xr-tools/releases/download/${XR_TOOLS_VERSION}/godot-xr-tools.zip"
  unzip -q "$TMP/xrt.zip" -d "$TMP/xrt"
  cp -r "$TMP/xrt/godot-xr-tools/addons/godot-xr-tools" "$ADDONS/"
fi

if [ "${1:-}" = "--android" ] && [ ! -d "$ADDONS/godotopenxrvendors" ]; then
  curl -fsSL --retry 4 -o "$TMP/vendors.zip" \
    "https://github.com/GodotVR/godot_openxr_vendors/releases/download/${OPENXR_VENDORS_VERSION}/godotopenxrvendorsaddon.zip"
  unzip -q "$TMP/vendors.zip" -d "$TMP/vendors"
  cp -r "$TMP/vendors/asset/addons/godotopenxrvendors" "$ADDONS/"
fi
