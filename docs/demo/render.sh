#!/bin/sh
# Renders the README pictures from the demo pages with headless Chrome.
# Usage: sh docs/demo/render.sh
set -eu
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
shot() { # <name> <width,height> <page>
  "$CHROME" --headless=new --hide-scrollbars --allow-file-access-from-files \
    --user-data-dir="$TMP/profile" --force-device-scale-factor=2 --window-size="$2" \
    --virtual-time-budget=5000 --screenshot="$TMP/$1.png" "file://$PWD/$3" 2>/dev/null
  sips -s format jpeg -s formatOptions 88 "$TMP/$1.png" --out "../$1.jpg" >/dev/null
  echo "docs/$1.jpg"
}
shot menubar 1440,860 menubar.html
shot menubar-edit 1440,860 "menubar.html#edit"
shot vscode 1280,800 vscode.html
rm -rf "$TMP"
