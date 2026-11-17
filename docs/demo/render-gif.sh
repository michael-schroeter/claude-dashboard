#!/bin/sh
# Renders the animated README demo docs/demo.gif from flow.html: each frame
# with headless Chrome, then gif.swift packs them. Needs Google Chrome and the
# Swift compiler that comes with Xcode, nothing else.
# Usage: sh docs/demo/render-gif.sh
set -eu
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The frames as "<time in s> <delay in 1/100 s>". A pause is one frame with a
# long delay; movement runs at about 14 frames per second. The times follow
# the timeline T in flow.html.
move() { # <from> <to> <frames>
  awk -v a="$1" -v b="$2" -v n="$3" 'BEGIN { for (i = 1; i <= n; i++) printf "%.3f 7\n", a + (b - a) * i / n }'
}
{
  echo "0 180"                                  # all sessions in one tab
  echo "1.8 90"                                 # one of them starts waiting
  move 2.7 3.5 12                               # the mouse goes to its card
  echo "3.55 5"
  echo "3.6 6"; echo "3.66 6"; echo "3.72 6"    # click
  echo "3.78 7"; echo "3.85 7"; echo "3.92 7"; echo "3.99 16"   # its window comes to the front
  echo "4.15 35"                                # with the session open
  move 4.5 5.2 10                               # the mouse goes to the reply box
  echo "5.27 7"; echo "5.34 7"; echo "5.41 7"; echo "5.48 7"; echo "5.58 17"
  echo "5.75 50"; echo "6.25 50"; echo "6.75 50"; echo "7.25 50"; echo "7.75 50"; echo "8.25 80"
} > "$TMP/plan.txt"

shot() { # <time>
  "$CHROME" --headless=new --hide-scrollbars --allow-file-access-from-files \
    --user-data-dir="$TMP/profile-$1" --force-device-scale-factor=2 --window-size=1100,720 \
    --virtual-time-budget=3000 --screenshot="$TMP/frame-$1.png" "file://$PWD/flow.html#t=$1" 2>/dev/null
  rm -rf "$TMP/profile-$1"
}
n=0
while read -r t _delay; do
  shot "$t" &
  n=$((n + 1))
  if [ $((n % 6)) -eq 0 ]; then wait; fi
done < "$TMP/plan.txt"
wait

awk -v dir="$TMP" '{ printf "%s/frame-%s.png %s\n", dir, $1, $2 }' "$TMP/plan.txt" > "$TMP/frames.txt"
swiftc -O gif.swift -o "$TMP/gif"
"$TMP/gif" "$TMP/frames.txt" ../demo.gif
if [ -n "${KEEP_FRAMES:-}" ]; then mkdir -p "$KEEP_FRAMES" && cp "$TMP"/frame-*.png "$KEEP_FRAMES"/; fi
