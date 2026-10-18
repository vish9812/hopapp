# hopapp

A macOS menu bar app for switching between apps and windows on the currently visible Spaces across connected monitors. Minimized windows on those visible Spaces are included and restored when selected. If their Space membership cannot be determined, they are excluded. Hidden apps are excluded.

- **Option+Tab:** cycle apps.
- **Option+`** (grave/tilde key): cycle windows of the focused app.
- Hold Option and repeat to advance; add Shift to reverse.
- Release Option to select, or press Escape to cancel.

## Install

Requires macOS 13+, the Swift toolchain, and [just](https://github.com/casey/just).

Quit hopapp before installing or updating:

```sh
just install
open "$HOME/Applications/hopapp.app"
```

If upgrading from SwitchApps, quit it and turn off its **Launch at Login** before installing. Remove the old `SwitchApps.app` after installing hopapp, then enable **Launch at Login** in hopapp if desired. The macOS bundle identifier is preserved across the rename.

Use the menu to grant Accessibility access and enable hopapp in System Settings. Grant Input Monitoring if prompted. **Launch at Login** is optional.

For development, run `just build` followed by `just run`. Without just, run `bash scripts/install-app.sh` to install.

Builds are signed ad hoc; rebuilding may require granting Accessibility access again. Window matching uses an undocumented macOS API and may break after OS updates.
