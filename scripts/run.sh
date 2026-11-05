#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/hopappDiagnostic.app"
if [[ ! -x "$APP/Contents/MacOS/hopappDiagnostic" ]]; then
    bash "$ROOT/scripts/build.sh"
fi
cd "$ROOT"
exec "$APP/Contents/MacOS/hopappDiagnostic" "$@"
