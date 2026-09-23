# Minimal smoke-test script

Just enough JSON to prove the script format loads. No tracks, no objects.

To make video playback work in Phase 0, drop a Theora file next to this README named `video.ogv`.

Any `.mp4` you have can be transcoded with FFmpeg:

```
ffmpeg -i input.mp4 -c:v libtheora -q:v 7 -c:a libvorbis video.ogv
```

Once `godot-videodecoder` is installed (see `docs/videodecoder_install.md`), the format spec will accept `.mp4` directly.
