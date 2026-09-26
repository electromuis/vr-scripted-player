#!/usr/bin/env bash
# Downloads the Godot editor (Linux x86_64) and, with --templates, the export
# templates this project exports with. Prints nothing else of note; the editor
# ends up at $GODOT_DIR/godot and the templates where Godot looks for them.
#
#   ci/setup_godot.sh [--templates]
#
# GODOT_VERSION (e.g. 4.7.2) and GODOT_DIR (default ~/godot) come from the env.
set -euo pipefail

: "${GODOT_VERSION:?set GODOT_VERSION, e.g. 4.7.2}"
GODOT_DIR="${GODOT_DIR:-$HOME/godot}"
BASE="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"
mkdir -p "$GODOT_DIR"

if [ ! -x "$GODOT_DIR/godot" ]; then
  curl -fsSL --retry 4 -o /tmp/godot.zip "$BASE/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  unzip -oq /tmp/godot.zip -d "$GODOT_DIR"
  mv "$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_linux.x86_64" "$GODOT_DIR/godot"
  chmod +x "$GODOT_DIR/godot"
  rm /tmp/godot.zip
fi

if [ "${1:-}" = "--templates" ]; then
  TPL_DIR="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
  if [ ! -f "$TPL_DIR/version.txt" ]; then
    mkdir -p "$TPL_DIR"
    curl -fsSL --retry 4 -o /tmp/templates.tpz "$BASE/Godot_v${GODOT_VERSION}-stable_export_templates.tpz"
    # Only the templates we export with; the full set is ~1.3 GB.
    unzip -oqj /tmp/templates.tpz -d "$TPL_DIR" \
      templates/version.txt \
      templates/windows_release_x86_64.exe templates/windows_release_x86_64_console.exe \
      templates/linux_release.x86_64 \
      templates/macos.zip \
      templates/android_release.apk templates/android_source.zip
    rm /tmp/templates.tpz
  fi
fi

echo "GODOT=$GODOT_DIR/godot"
