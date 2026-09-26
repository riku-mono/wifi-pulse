# Contributing to Wi-Fi Pulse

Thanks for your interest! Issues and pull requests are welcome in English or Japanese.
（日本語での Issue・PR も歓迎します。）

> [!NOTE]
> Contributions are licensed under the [Apache License 2.0](LICENSE), like the rest of the code (section 5 of the License).
> The name “Wi-Fi Pulse” and the app icon are not part of that — see [TRADEMARKS.md](TRADEMARKS.md).

## Before you start

- **Bugs and ideas**: open an issue with a template. Hide IP addresses, MAC addresses, SSIDs and device names.
- **Security issues**: follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
- For larger changes, discuss them in an issue first.

## Workflow

1. Branch from `main` (`feat/…`, `fix/…`, `docs/…`, `test/…`, `chore/…`). Don't commit to `main` directly.
2. Write commit messages in English, in the imperative mood (“Add …”, “Fix …”).
3. Open a pull request with the template: what changed, what you verified, and what still needs checking.
4. Add a line to [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]` for user-visible changes.

## Build and test

Requires macOS 27 and Xcode 27.

```bash
cd apps/macos
xcodebuild -project WiFiPulse.xcodeproj -scheme WiFiPulse -configuration Debug \
  -derivedDataPath build/DerivedData.noindex build
xcodebuild -project WiFiPulse.xcodeproj -scheme WiFiPulse -configuration Debug \
  -derivedDataPath build/DerivedData.noindex test
```

- `project.pbxproj` uses file-system synchronized groups: files you add under `WiFiPulse/` join the target automatically. Add new targets in Xcode.
- Unit tests use Swift Testing and cover pure functions only — no external commands, network or the records folder. Feed fixtures as strings, and replace IPs, MACs and process names from real output with synthetic ones.
- Dev builds get registered with LaunchServices; run `scripts/unregister-dev-builds.sh` afterwards.

## Rules of the codebase

### Strings and localization

- The source language is **English**; Japanese goes in `Localizable.xcstrings`.
- Use `String(localized:)` for anything not passed straight to `Text` / `Label` / `Button`. Don't compare translated strings or build sentences from fragments.
- After changing strings: sync the catalog, translate, then run
  `scripts/l10n-coverage.py --update README.md --update README.ja.md`. CI requires en/ja at 100% and up-to-date tables.
- Details: [docs/localization.md](docs/localization.md).

### Performance

Wi-Fi Pulse runs all day, so CPU use is a hard requirement.

- Build the per-second snapshot once (`Monitor.live`); always-visible UI reads properties that change only when needed.
- Split charts into `Equatable` views; avoid continuous animations and symbol effects.
- **For UI changes, measure CPU in a Release build** (each view, 30-second average) and compare with `main`.
- Details: [apps/macos/README.md](apps/macos/README.md).

### External processes and the network

- Attach `nettop` to a pseudo-terminal and keep the watchdog in place. After adding a child process, check that nothing is left behind after `kill -9`.
- Some links have no LAN (e.g. iPhone tethering, `192.0.0.2/32`). Check the interface's subnet and flags before sending anything to the LAN.
- The app only reads. Never change the user's router or Mac settings.
