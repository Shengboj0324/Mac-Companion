#!/usr/bin/env bash
# Renders key screens (light + dark) offscreen with sample data into dist/snapshots.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Companion
"$(swift build --show-bin-path)/Companion" --render-snapshots "${1:-dist/snapshots}"
