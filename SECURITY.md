# Security Policy

## Reporting a vulnerability

Please **don't open a public issue**.

Use GitHub's [private vulnerability reporting](https://github.com/riku-mono/wifi-pulse/security/advisories/new) (**Security** tab → **Report a vulnerability**).

English or Japanese is fine. We'll acknowledge your report and keep you updated on the fix.

## What the app handles

- **Network measurements**: pings to your router and to public hosts (default `1.1.1.1` and `2001:4860:4860::8888`), and speed / load tests against Apple (`networkQuality`) and Cloudflare (`speed.cloudflare.com`). Nothing is sent to the developer.
- **Local records**: measurements, device lists and network identifiers (router MAC addresses) are stored only on your Mac, in `~/Library/Application Support/WiFiPulse/`.
- **System tools**: the app runs macOS commands such as `nettop`, `ping`, `log` and `networkQuality` without the App Sandbox (see [docs/distribution.md](docs/distribution.md)). It reads only and never changes system or router settings.
- **Permissions**: Location (Wi-Fi network names and BSSIDs) and Local Network (LAN device discovery).

## Supported versions

Only the latest `main` branch is supported until the first release.
