#!/bin/bash
# Local validation; no publishing and no signing/notarization credentials required.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || {
  echo "Run these native app checks on an Apple Silicon Mac." >&2
  exit 1
}
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
scripts/build-llama.sh
swift test
./build.sh
codesign --verify --deep --strict --verbose=2 build.noindex/DigUp.app
echo "Tests, release build and bundle signature passed."
