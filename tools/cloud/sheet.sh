#!/usr/bin/env bash
# Tiles screenshots into one labelled contact sheet (two columns), via the
# preinstalled headless Chromium. Labels come from the file names.
#
#   tools/cloud/sheet.sh out.png a.png b.png c.png ...
set -euo pipefail
OUT="$1"; shift
HTML="$(mktemp --suffix=.html)"
{
	echo '<html><body style="margin:0;background:#0c0d12;font:600 16px sans-serif;color:#e8ebf2">'
	echo '<div style="display:grid;grid-template-columns:440px 440px;gap:14px;padding:14px">'
	for f in "$@"; do
		label="$(basename "$f" .png | tr '_' ' ')"
		echo "<div>$label<br><img src=\"file://$(realpath "$f")\" width=\"440\"></div>"
	done
	echo '</div></body></html>'
} > "$HTML"
ROWS=$(( ($# + 1) / 2 ))
HEIGHT=$(( ROWS * 290 + 40 ))
/opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell --no-sandbox --disable-gpu --hide-scrollbars \
	--allow-file-access-from-files --screenshot="$OUT" --window-size=922,$HEIGHT "file://$HTML" >/dev/null 2>&1
rm -f "$HTML"
echo "$OUT"
