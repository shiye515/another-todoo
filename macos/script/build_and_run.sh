#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TodooCardMacApp"
DERIVED_DIR="$ROOT_DIR/.derived"

while read -r pid; do
  [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
done < <(pgrep -x "$APP_NAME" || true)

cd "$ROOT_DIR"
xcodegen generate
xcodebuild \
  -project "$ROOT_DIR/TodooCardMacApp.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP_BUNDLE="$DERIVED_DIR/Build/Products/Debug/$APP_NAME.app"

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
