#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input_path=""
device_id=""
rotate_right_90=false
mode="prepare"
operation_count=0

usage() {
  cat <<'EOF'
Usage:
  prepare_and_send.sh --list
  prepare_and_send.sh --pair --device-id UUID
  prepare_and_send.sh --probe --device-id UUID
  prepare_and_send.sh --input photo.jpg [--rotate-right-90]
  prepare_and_send.sh --input photo.jpg --device-id UUID --send [--rotate-right-90]

Default behavior only prepares and validates a T3 payload. --send is required
before Bluetooth writes. --device-id is always required for pair, probe, or send.
Supply an upright source image. TodooCard/T3 528x792 panel calibration is
applied internally as the fixed todoocard-correct orientation.
Generated payload artifacts are written to the same directory as --input.
EOF
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) [[ $# -ge 2 ]] || usage; input_path="$2"; shift 2 ;;
    --device-id) [[ $# -ge 2 ]] || usage; device_id="$2"; shift 2 ;;
    --screen-orientation) echo "TodooCard/T3 orientation is fixed at todoocard-correct and cannot be overridden." >&2; exit 64 ;;
    --rotate-right-90) rotate_right_90=true; shift ;;
    --list) mode="list"; operation_count=$((operation_count + 1)); shift ;;
    --pair) mode="pair"; operation_count=$((operation_count + 1)); shift ;;
    --probe) mode="probe"; operation_count=$((operation_count + 1)); shift ;;
    --send) mode="send"; operation_count=$((operation_count + 1)); shift ;;
    *) usage ;;
  esac
done

(( operation_count <= 1 )) || usage

required_commands=(swiftc)
if [[ "$mode" == "prepare" || "$mode" == "send" ]]; then
  required_commands+=(python3 /usr/bin/sips)
fi
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command unavailable: $command" >&2; exit 69; }
done

if [[ "$mode" == "pair" || "$mode" == "probe" || "$mode" == "send" ]]; then
  [[ -n "$device_id" ]] || { echo "--device-id is required before contacting a device." >&2; exit 64; }
fi
if [[ "$mode" == "prepare" || "$mode" == "send" ]]; then
  [[ -n "$input_path" && -f "$input_path" ]] || { echo "Input image not found: $input_path" >&2; exit 2; }
  image_bytes="$(stat -f %z "$input_path")"
  [[ "$image_bytes" -le 100000000 ]] || { echo "Input image exceeds the 100 MB safety limit." >&2; exit 65; }
  image_width="$(/usr/bin/sips -g pixelWidth "$input_path" | awk '/pixelWidth/ {print $2}')"
  image_height="$(/usr/bin/sips -g pixelHeight "$input_path" | awk '/pixelHeight/ {print $2}')"
  [[ "$image_width" =~ ^[0-9]+$ && "$image_height" =~ ^[0-9]+$ ]] || { echo "Unable to determine input image dimensions." >&2; exit 65; }
  (( image_width * image_height <= 50000000 )) || { echo "Input image exceeds the 50-megapixel safety limit." >&2; exit 65; }
fi

run_dir="$(mktemp -d /tmp/potatocard-transfer.XXXXXX)"
trap 'rm -rf "$run_dir"' EXIT
mkdir -p "$run_dir/module-cache"
cp -R "$script_dir" "$run_dir/scripts"
sender="$run_dir/mac-image-transfer"
CLANG_MODULE_CACHE_PATH="$run_dir/module-cache" "$run_dir/scripts/build_sender.sh" "$sender" >/dev/null

if [[ "$mode" == "list" ]]; then
  "$sender" --list
  exit 0
fi
if [[ "$mode" == "pair" ]]; then
  "$sender" --pair --id "$device_id"
  exit 0
fi
if [[ "$mode" == "probe" ]]; then
  "$sender" --probe --id "$device_id"
  exit 0
fi

converter="$run_dir/image-to-payload"
CLANG_MODULE_CACHE_PATH="$run_dir/module-cache" "$run_dir/scripts/build_converter.sh" "$converter" >/dev/null
input_copy="$run_dir/input-source"
cp "$input_path" "$input_copy"
normalized_image="$run_dir/input-normalized.png"
if [[ "$rotate_right_90" == true ]]; then
  TMPDIR="$run_dir" /usr/bin/sips -s format png -r 90 "$input_copy" --out "$normalized_image" >/dev/null
else
  TMPDIR="$run_dir" /usr/bin/sips -s format png "$input_copy" --out "$normalized_image" >/dev/null
fi

payload_prefix="$run_dir/image"
input_dir="$(cd "$(dirname "$input_path")" && pwd)"
input_name="$(basename "$input_path")"
input_stem="${input_name%.*}"
payload_prefix="$input_dir/${input_stem}.todoocard"
"$converter" --input "$normalized_image" --target t3 --orientation todoocard-correct --output-prefix "$payload_prefix"
python3 "$run_dir/scripts/quicklz_payload.py" \
  --input "$payload_prefix.controller.bin" \
  --output "$payload_prefix.protocol.qlz"
python3 "$run_dir/scripts/validate_payload.py" \
  --expected-raw "$payload_prefix.controller.bin" \
  "$payload_prefix.controller.bin" \
  "$payload_prefix.protocol.qlz" \
  "$payload_prefix.protocol.legacy.qlz"
echo "Prepared v157+ payload: $payload_prefix.protocol.qlz"
echo "Prepared legacy payload: $payload_prefix.protocol.legacy.qlz"

if [[ "$mode" == "send" ]]; then
  echo "Sending to device $device_id ..."
  "$sender" \
    --payload "$payload_prefix.protocol.qlz" \
    --legacy-payload "$payload_prefix.protocol.legacy.qlz" \
    --raw-payload "$payload_prefix.controller.bin" \
    --compressed \
    --id "$device_id"
fi
