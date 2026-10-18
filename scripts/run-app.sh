#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/hopapp.app"
if [[ ! -x "$APP/Contents/MacOS/hopapp" ]]; then
    bash "$ROOT/scripts/build-app.sh"
fi
open -g "$APP"
