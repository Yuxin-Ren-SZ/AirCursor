# Contributing to AirCursor

Thanks for helping! Bug reports, gesture-tuning data, and pull requests are all welcome.

## Getting set up

```bash
git clone https://github.com/m-afham/AirCursor.git
cd AirCursor
make test   # run the core unit tests
make run    # build build/AirCursor.app (arm64) and launch it
```

Requirements: macOS 15+, Xcode 16+, and AirPods with head tracking for anything motion-related.

macOS ties Accessibility permission to the app's code signature. `scripts/build-app.sh` signs with your first *Apple Development* or *Developer ID* identity if one exists. Without one it falls back to ad-hoc signing, and then you have to re-grant Accessibility after every rebuild.

## Where things live

| Path | What |
|---|---|
| `Sources/AirCursorCore` | Pure, unit-tested logic: pointer mapping, smoothing, gesture and dwell detection, settings |
| `Sources/AirCursor/Services` | macOS integrations: CoreMotion, CGEvent, IOBluetooth, MediaPlayer, CoreAudio, hot keys |
| `Sources/AirCursor/AppController.swift` | Wires motion → pointer/gestures → actions |
| `Sources/AirCursor/Views` | SwiftUI: menu bar, settings, guided tour, 3D earbuds |
| `scripts/` | App bundling, icon, release |

## Guidelines

- Put logic in `AirCursorCore` wherever possible, with tests. Gesture changes should come with a test that feeds synthetic motion (see `GestureTests`).
- Keep the app private by design: no network calls, no analytics.
- Run `make test` before opening a PR. CI runs the same tests.
- To refresh the tour screenshots in `docs/`, run `open build/AirCursor.app --env AIRCURSOR_SNAPSHOT_DIR=/tmp/shots`.

## Reporting bugs

Please include the output of **Settings › Shortcuts & General › Diagnostics › Copy diagnostics**. It shows exactly which link in the chain (permissions, Bluetooth, audio route, motion) is failing.
