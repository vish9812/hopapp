# Repository Guidelines

## Project Structure & Module Organization

hopapp is a Swift Package Manager project for a macOS 13+ menu bar app that switches between apps and windows on visible Spaces.

- `Sources/hopapp/`: menu bar lifecycle, keyboard events, window discovery, switcher overlay, and login item support.
- `Sources/DiagnosticCore/`: shared switching logic and eligibility policies.
- `Sources/hopappDiagnostic/`: inventory and focus diagnostic executable.
- `Tests/hopappTests/`: XCTest coverage for login items and overlay behavior.
- `scripts/`: build, bundle, install, launch, and window fixture utilities.
- `.build/`: generated binaries and app bundles; excluded from Git.

## Build, Test, and Development Commands

Use macOS with a Swift 5.9-compatible toolchain. Install `just` to use the repository shortcuts.

- `swift build`: compile the package for development.
- `swift test`: run the XCTest suite.
- `swift test --filter LoginItemTests`: run a focused test class.
- `just build`: build the release app bundle at `.build/hopapp.app` and verify its signature.
- `just run`: launch the development app; builds it if missing. Rebuild explicitly after source changes.
- `just install`: build and install into `~/Applications`; quit hopapp first.
- `bash scripts/build.sh`: build the diagnostic app bundle.
- `bash scripts/run.sh --help`: inspect diagnostic options.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` methods and properties. Name files after their principal type or responsibility, such as `WindowCatalog.swift`. Keep shared policy logic in `DiagnosticCore` and AppKit integration in executable targets. Use `@MainActor` for tests that manipulate AppKit UI. No formatter or linter configuration is checked in.

## Testing Guidelines

Use XCTest classes named `*Tests` and descriptive `test...` methods. Prefer injected system access and offscreen UI fixtures, following existing tests. Reproduce bugs before fixing them and rerun the relevant tests afterward. No coverage threshold is configured. Manually verify shortcut or window-discovery changes across Spaces, monitors, hidden apps, and minimized windows.

## Commit & Pull Request Guidelines

History uses free-form summaries without a consistent prefix. Write imperative subjects describing the change. Pull requests should explain behavior, validation commands and results, and relevant issues. Include screenshots for overlay changes and manual reproduction steps for macOS integration changes.

## macOS Permissions & Configuration

Grant Accessibility access and Input Monitoring if prompted. Ad hoc rebuilds may require renewed Accessibility approval. Preserve the `local.switchapps` bundle identifier across renames. Window matching depends on an undocumented macOS API; verify related changes on the target OS. Keep diagnostic evidence out of Git.
