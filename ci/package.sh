#!/usr/bin/env bash
# Turns the exported builds in build/<platform>/ into release files in dist/:
#   ShaderPlayerVR-<ver>-windows-x86_64-setup.exe      installer
#   ShaderPlayerVR-<ver>-windows-x86_64-portable.zip
#   ShaderPlayerVR-<ver>-linux-x86_64.deb               installer
#   ShaderPlayerVR-<ver>-linux-x86_64-portable.tar.gz
#   ShaderPlayerVR-<ver>-macos-universal.zip            the .app
#   ShaderPlayerVR-<ver>-quest3.apk                     sideload with adb / SideQuest
#   ShaderPlayerVR-<ver>-portable-all-platforms.zip     everything above, unpacked
# Platforms missing from build/ are skipped.
#
#   ci/package.sh <version>
set -euo pipefail

VERSION="$1"
NAME="ShaderPlayerVR"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
ALL="$BUILD/all/$NAME-$VERSION"
rm -rf "$DIST" "$BUILD/all"
mkdir -p "$DIST" "$ALL"

extras() {  # README and third-party licences next to the binaries
  cp "$ROOT/README.md" "$1/"
  cp "$ROOT/project_engine/addons/gde_gozen/LICENSE" "$1/LICENSE-gde_gozen-FFmpeg-LGPL.txt"
}

if [ -d "$BUILD/windows" ]; then
  extras "$BUILD/windows"
  (cd "$BUILD/windows" && zip -qr9 "$DIST/$NAME-$VERSION-windows-x86_64-portable.zip" .)
  makensis -V2 -DVERSION="$VERSION" -DSRCDIR="$BUILD/windows" \
    -DOUTFILE="$DIST/$NAME-$VERSION-windows-x86_64-setup.exe" "$ROOT/ci/installer/windows.nsi"
  cp -r "$BUILD/windows" "$ALL/windows"
fi

if [ -d "$BUILD/linux" ]; then
  extras "$BUILD/linux"
  tar -C "$BUILD" --transform "s|^linux|$NAME-$VERSION|" -czf "$DIST/$NAME-$VERSION-linux-x86_64-portable.tar.gz" linux
  cp -r "$BUILD/linux" "$ALL/linux"

  PKG="$BUILD/deb"
  rm -rf "$PKG"
  mkdir -p "$PKG/DEBIAN" "$PKG/opt/shader-player-vr" "$PKG/usr/bin" "$PKG/usr/share/applications"
  cp -r "$BUILD/linux/." "$PKG/opt/shader-player-vr/"
  ln -s /opt/shader-player-vr/$NAME.x86_64 "$PKG/usr/bin/shader-player-vr"
  cat > "$PKG/usr/share/applications/shader-player-vr.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Shader Player VR
Comment=Scripted VJ video player
Exec=/opt/shader-player-vr/$NAME.x86_64 %f
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;
DESKTOP
  # Debian versions must start with a digit.
  DEB_VERSION="$(echo "$VERSION" | sed 's/^[^0-9]*//; s/-/~/g')"
  cat > "$PKG/DEBIAN/control" <<CONTROL
Package: shader-player-vr
Version: ${DEB_VERSION:-0.0.0}
Architecture: amd64
Maintainer: Electromuis <noreply@github.com>
Section: video
Priority: optional
Depends: libc6, libgl1, libvulkan1
Description: Scripted VJ video player with VR support (OpenXR)
CONTROL
  dpkg-deb --root-owner-group --build "$PKG" "$DIST/$NAME-$VERSION-linux-x86_64.deb"
fi

if [ -f "$BUILD/macos/$NAME.zip" ]; then
  cp "$BUILD/macos/$NAME.zip" "$DIST/$NAME-$VERSION-macos-universal.zip"
  mkdir -p "$ALL/macos"
  unzip -q "$BUILD/macos/$NAME.zip" -d "$ALL/macos"
  extras "$ALL/macos"
fi

if [ -f "$BUILD/quest/$NAME.apk" ]; then
  cp "$BUILD/quest/$NAME.apk" "$DIST/$NAME-$VERSION-quest3.apk"
  mkdir -p "$ALL/quest3"
  cp "$BUILD/quest/$NAME.apk" "$ALL/quest3/$NAME.apk"
fi

(cd "$BUILD/all" && zip -qr9 -y "$DIST/$NAME-$VERSION-portable-all-platforms.zip" "$NAME-$VERSION")
ls -la "$DIST"
