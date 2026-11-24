#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="${1:-/tmp/mac-image-transfer}"
info_plist="$script_dir/mac_image_transfer.Info.plist"

swiftc \
  -framework CoreBluetooth \
  -framework Foundation \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$info_plist" \
  "$script_dir/mac_image_transfer.swift" \
  -o "$output"

echo "$output"
