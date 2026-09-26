#!/usr/bin/env bash
# Builds gde_gozen (FFmpeg + the GDExtension, debug and release) for one
# platform. Run from the repo root; the source is cloned into ./gde_gozen.
#
#   ci/build_gozen.sh <linux|windows|macos|android> <x86_64|arm64>
#
# GOZEN_GIT_URL and GOZEN_SHA pick the source (see .github/workflows/build.yml).
# Every ci/gde_gozen/patches/*.patch is applied on top, in name order.
# Binaries end up in ./gozen-bin/<platform>-<arch>.
set -euo pipefail

PLATFORM="$1"
ARCH="$2"
: "${GOZEN_GIT_URL:?}" "${GOZEN_SHA:?}"
ROOT="$(pwd)"

rm -rf gde_gozen
git init -q gde_gozen
cd gde_gozen
git remote add origin "$GOZEN_GIT_URL"
git fetch -q --depth 1 origin "$GOZEN_SHA"
git checkout -q FETCH_HEAD
# emsdk is only for web builds.
SUBMODULES=(ffmpeg godot_cpp libvpx libaom)
git submodule update --init --depth 1 "${SUBMODULES[@]}" \
  || git submodule update --init "${SUBMODULES[@]}"

shopt -s nullglob
for p in "$ROOT"/ci/gde_gozen/patches/*.patch; do
  echo "Applying $(basename "$p")"
  git apply --whitespace=nowarn "$p"
done

FFMPEG_ARCH="$ARCH"
[ "$PLATFORM" = android ] && [ "$ARCH" = arm32 ] && FFMPEG_ARCH=armv7a

export PYTHONPATH="${PYTHONPATH:-}:."
python3 -c "import build; build.compile_ffmpeg_${PLATFORM}('${FFMPEG_ARCH}')"

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
scons -j"$JOBS" target=template_debug platform="$PLATFORM" arch="$ARCH"
scons -j"$JOBS" target=template_release platform="$PLATFORM" arch="$ARCH"

OUT="$ROOT/gozen-bin/$PLATFORM-$ARCH"
mkdir -p "$OUT"
cp -r test_room/addons/gde_gozen/bin/. "$OUT/"
ls -la "$OUT"
