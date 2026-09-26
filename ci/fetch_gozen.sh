#!/usr/bin/env bash
# Downloads prebuilt gde_gozen binaries (debug and release) from a GitHub
# release of GOZEN_REPO (built by that repo's release workflow) into
# project_engine/addons/gde_gozen/bin/.
#
#   ci/fetch_gozen.sh <platform>-<arch> ...    e.g. linux-x86_64 android-arm64
#   ci/fetch_gozen.sh all                      every platform in the release
#
# GOZEN_REPO (owner/name) and GOZEN_RELEASE (tag) come from the env. Uses the
# gh CLI: GH_TOKEN must be able to read GOZEN_REPO (for a private repo, a
# token with access to it; GitHub's own Actions token only reads this repo).
set -euo pipefail

: "${GOZEN_REPO:?set GOZEN_REPO, e.g. electromuis/gde_gozen}"
: "${GOZEN_RELEASE:?set GOZEN_RELEASE, e.g. v9.7-sp1}"
[ $# -gt 0 ] || { echo "usage: $0 <platform>-<arch>... | all" >&2; exit 2; }

BIN="$(cd "$(dirname "$0")/.." && pwd)/project_engine/addons/gde_gozen/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PATTERNS=()
if [ "$1" = all ]; then
  PATTERNS=(--pattern "gde_gozen-*-bin-*.zip")
else
  for target in "$@"; do PATTERNS+=(--pattern "gde_gozen-*-bin-$target.zip"); done
fi

gh release download "$GOZEN_RELEASE" --repo "$GOZEN_REPO" --dir "$TMP" "${PATTERNS[@]}"
if [ "$1" != all ]; then
  for target in "$@"; do
    ls "$TMP"/gde_gozen-*-bin-"$target".zip > /dev/null 2>&1 \
      || { echo "no $target binaries in $GOZEN_REPO $GOZEN_RELEASE" >&2; exit 1; }
  done
fi

mkdir -p "$BIN"
for zip in "$TMP"/*.zip; do unzip -oq "$zip" -d "$BIN"; done
ls -la "$BIN"
