#!/bin/bash
# Model-free synthetic profiling. Outputs JSON; never opens or changes the app's real index.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || {
  echo "Run native Accelerate profiling on an Apple Silicon Mac." >&2
  exit 1
}
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift run -c release digup-benchmark "$@"
