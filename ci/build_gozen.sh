#!/usr/bin/env bash
# Builds gde_gozen for one platform, in steps so CI can cache between them.
# Run from the repo root; the source is cloned into ./gde_gozen.
#
#   ci/build_gozen.sh checkout                  clone GOZEN_GIT_URL @ GOZEN_SHA, apply patches
#   ci/build_gozen.sh deps-key <platform> <arch> print the cache key of the FFmpeg step
#   ci/build_gozen.sh ffmpeg <platform> <arch>   FFmpeg + libvpx/libaom/LibreSSL -> gde_gozen/ffmpeg/bin
#   ci/build_gozen.sh extension <platform> <arch> the GDExtension, debug and release -> gozen-bin/<platform>-<arch>
#   ci/build_gozen.sh all <platform> <arch>      checkout + ffmpeg + extension
#
# platform: linux | windows | macos | android, arch: x86_64 | arm64.
# Every ci/gde_gozen/patches/*.patch is applied on top, in name order.
# SCONS_CACHE_DIR, if set, is used as SCons' build cache (godot-cpp and the
# extension's objects), so unchanged files aren't recompiled.
set -euo pipefail

STEP="$1"
PLATFORM="${2:-}"
ARCH="${3:-}"
ROOT="$(pwd)"
SRC="$ROOT/gde_gozen"

checkout() {
  : "${GOZEN_GIT_URL:?}" "${GOZEN_SHA:?}"
  rm -rf "$SRC"
  git init -q "$SRC"
  cd "$SRC"
  git remote add origin "$GOZEN_GIT_URL"
  git fetch -q --depth 1 origin "$GOZEN_SHA"
  git checkout -q FETCH_HEAD
  # emsdk is only for web builds.
  local submodules=(ffmpeg godot_cpp libvpx libaom)
  git submodule update --init --depth 1 "${submodules[@]}" \
    || git submodule update --init "${submodules[@]}"

  shopt -s nullglob
  for p in "$ROOT"/ci/gde_gozen/patches/*.patch; do
    echo "Applying $(basename "$p")"
    git apply --whitespace=nowarn "$p"
  done
  cd "$ROOT"
}

# Everything the FFmpeg step's output depends on: the dependency commits and
# build.py (configure flags, LibreSSL version). Bump FFMPEG_STEP_VERSION when
# ffmpeg() below changes in a way that changes its output.
FFMPEG_STEP_VERSION=1
deps_key() {
  cd "$SRC"
  {
    echo "$PLATFORM-$ARCH-v$FFMPEG_STEP_VERSION"
    git submodule status ffmpeg libvpx libaom | cut -c2-41
    cat build.py
  } | sha256sum | cut -c1-24
  cd "$ROOT"
}

ffmpeg() {
  local ffmpeg_arch="$ARCH"
  [ "$PLATFORM" = android ] && [ "$ARCH" = arm32 ] && ffmpeg_arch=armv7a
  cd "$SRC"
  PYTHONPATH="${PYTHONPATH:-}:." python3 -c "import build; build.compile_ffmpeg_${PLATFORM}('${ffmpeg_arch}')"
  cd "$ROOT"
}

extension() {
  local jobs cache=()
  jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  if [ -n "${SCONS_CACHE_DIR:-}" ]; then
    mkdir -p "$SCONS_CACHE_DIR"
    cache=("--cache-dir=$SCONS_CACHE_DIR")
  fi
  cd "$SRC"
  scons -j"$jobs" "${cache[@]}" target=template_debug platform="$PLATFORM" arch="$ARCH"
  scons -j"$jobs" "${cache[@]}" target=template_release platform="$PLATFORM" arch="$ARCH"

  local out="$ROOT/gozen-bin/$PLATFORM-$ARCH"
  mkdir -p "$out"
  cp -r test_room/addons/gde_gozen/bin/. "$out/"
  ls -la "$out"
  cd "$ROOT"
}

case "$STEP" in
  checkout) checkout ;;
  deps-key) deps_key ;;
  ffmpeg) ffmpeg ;;
  extension) extension ;;
  all) checkout; ffmpeg; extension ;;
  *) echo "unknown step: $STEP" >&2; exit 2 ;;
esac
