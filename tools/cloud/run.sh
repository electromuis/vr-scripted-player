#!/usr/bin/env bash
# Copies project_engine to $WORK/engine_copy with the gde_gozen classes made
# dynamic (so main.gd compiles without the decoder), then runs a check
# script from tools/cloud/checks in it: rendered with Forward+ on software
# Vulkan under Xvfb. Screenshots land in $WORK/shots (OUT_DIR).
#
#   tools/cloud/run.sh checks/shot_fx.gd          # rendered
#   HEADLESS=1 tools/cloud/run.sh checks/drive.gd # no rendering needed
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/vj_cloud}"
export REPO WORK
GODOT="$WORK/godot/Godot_v4.7.1-stable_linux.x86_64"
COPY="$WORK/engine_copy"
CHECK="$1"

rm -rf "$COPY"
mkdir -p "$COPY" "$WORK/shots"
(cd "$REPO/project_engine" && tar --exclude=.godot -cf - .) | (cd "$COPY" && tar -xf -)
sed -i 's/var video := GoZenVideo.new()/var video = ClassDB.instantiate("GoZenVideo")/; s/var stream := AudioStreamFFmpeg.new()/var stream = ClassDB.instantiate("AudioStreamFFmpeg")/' "$COPY/player/video_bridge.gd"
sed -i 's/^var video: GoZenVideo = null/var video = null/; s/	video = GoZenVideo.new()/	video = ClassDB.instantiate("GoZenVideo")/; s/func update_video(video_instance: GoZenVideo,/func update_video(video_instance,/; s/func _update_video(new_video: GoZenVideo)/func _update_video(new_video)/; s/var stream: AudioStreamFFmpeg = AudioStreamFFmpeg.new()/var stream = ClassDB.instantiate("AudioStreamFFmpeg")/' "$COPY/addons/gde_gozen/video_playback.gd"
cp "$REPO/tools/cloud/$CHECK" "$COPY/"
cd "$COPY"
timeout 200 "$GODOT" --headless --import >/dev/null 2>&1 || true
NAME="$(basename "$CHECK")"
if [ "${HEADLESS:-}" = "1" ]; then
	timeout 300 "$GODOT" --headless --script "res://$NAME"
else
	OUT_DIR="$WORK/shots" VK_ICD_FILENAMES="$WORK/vk/lvp.json" timeout 600 xvfb-run -a -s "-screen 0 1280x800x24" \
		"$GODOT" --rendering-method forward_plus --rendering-driver vulkan --resolution 1280x720 --script "res://$NAME"
fi
