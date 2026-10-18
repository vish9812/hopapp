#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${HOPAPP_INSTALL_DIR:-${SWITCHAPPS_INSTALL_DIR:-$HOME/Applications}}"
APP="$DESTINATION/hopapp.app"

if pgrep -x 'hopapp|SwitchApps' >/dev/null; then
    printf 'Quit hopapp (or SwitchApps) from its menu before installing, then run just install again.\n' >&2
    exit 1
else
    PROCESS_STATUS=$?
    if [[ "$PROCESS_STATUS" -ne 1 ]]; then
        printf 'Could not check whether hopapp is running; installation stopped.\n' >&2
        exit 1
    fi
fi

bash "$ROOT/scripts/build-app.sh"
mkdir -p "$DESTINATION"
if [[ -e "$APP" || -L "$APP" ]]; then
    if [[ -L "$APP" || ! -d "$APP" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != 'local.switchapps' ]]; then
        printf 'Refusing to replace an unrelated app at %s\n' "$APP" >&2
        exit 1
    fi
fi

STAGING="$(mktemp -d "$DESTINATION/.hopapp-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$ROOT/.build/hopapp.app" "$STAGING/hopapp.app"
codesign --verify --strict "$STAGING/hopapp.app"
if [[ -d "$APP" ]]; then
    mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$STAGING/hopapp.app" "$APP"; then
    if [[ -d "$STAGING/previous.app" ]]; then
        if ! mv "$STAGING/previous.app" "$APP"; then
            trap - EXIT
            printf 'Could not restore the previous app; it is saved at %s\n' "$STAGING/previous.app" >&2
        fi
    fi
    exit 1
fi
printf '\nInstalled %s\nOpen it with: open "%s"\n' "$APP" "$APP"
