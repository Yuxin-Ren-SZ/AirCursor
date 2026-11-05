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

## How PRs are reviewed and released

- **PRs get an automated review** by Claude against [CLAUDE.md](CLAUDE.md), the project's rulebook (what AirCursor must stay: hands-free, private, minimal permissions, safe input, compatible settings). The review is posted as a comment and labeled `ai-approved`, `ai-changes-requested` or `needs-owner-review`. Maintainer and collaborator PRs are reviewed automatically. Other PRs are reviewed once a maintainer adds the `ai-review` label, which is removed after each review, so new commits need it added again.
- **PRs from the maintainer and collaborators** merge automatically once the review approves, CI passes, and no sensitive files (workflows, build scripts, Info.plist, entitlements, dependencies, CLAUDE.md) changed. **PRs from everyone else** get the same review, and a maintainer merges them by hand.
- **Releases are automatic.** Merging a change to the app publishes the next patch version. Add the `release:minor` or `release:major` label for a bigger bump, or `skip-release` to hold it back. Documentation-only changes never release.

## Reporting bugs

Please include the output of **Settings › Shortcuts & General › Diagnostics › Copy diagnostics**. It shows exactly which link in the chain (permissions, Bluetooth, audio route, motion) is failing.
