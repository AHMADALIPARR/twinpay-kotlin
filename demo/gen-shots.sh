#!/bin/bash
# Render real demo transcript lines as terminal-style PNG "photos".
# Usage: gen-shots.sh <transcript> <outdir>
set -e
TRANSCRIPT="$1"
OUTDIR="$2"
CHROME="$HOME/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome"
mkdir -p "$OUTDIR"

scene() { # name, first_line, last_line, title
  local name="$1" from="$2" to="$3" title="$4"
  local html="/tmp/scene-$name.html"
  {
    echo '<!DOCTYPE html><html><head><meta charset="utf-8"><style>'
    echo 'body{margin:0;background:#0d1117;font-family:ui-monospace,Menlo,Consolas,monospace;}'
    echo '.bar{background:#161b22;color:#8b949e;padding:10px 16px;font-size:14px;border-bottom:1px solid #30363d;}'
    echo '.term{padding:18px 20px;color:#c9d1d9;font-size:15px;line-height:1.65;white-space:pre-wrap;word-break:break-all;}'
    echo '.h{color:#58a6ff;font-weight:bold;} .ok{color:#7ee787;} .dim{color:#6e7681;}'
    echo '</style></head><body>'
    echo "<div class=\"bar\">twinpay — $title</div>"
    echo '<div class="term">'
    sed -n "${from},${to}p" "$TRANSCRIPT" | sed \
      -e 's/^== /<span class="h">== /' \
      -e 's/^\({"ok":true.*\)$/<span class="ok">\1<\/span>/' \
      -e 's/^\({"ok":false.*\)$/<span class="h">\1<\/span>/' \
      -e 's/^$/<span class="dim"> <\/span>/'
    echo '</div></body></html>'
  } > "$html"
  "$CHROME" --headless --disable-gpu --no-sandbox \
    --window-size=1180,560 --hide-scrollbars \
    --screenshot="$OUTDIR/$name.png" "file://$html" 2>/dev/null
  echo "shot: $OUTDIR/$name.png"
}

scene demo-01-gift 1 7 "treasury gift"
scene demo-02-send 8 17 "send + idempotent resend + balances"
scene demo-03-reverse 18 29 "reversal + conservation"
