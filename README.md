<div align="center">

<img src="https://raw.githubusercontent.com/wacht-platform/snippet-service/main/snippet-mascot/png/snip-mascot-256.png" alt="snippet mascot" width="132" height="132" />

# snippet — mobile

**Control your terminal coding agent from your phone.**

The remote client for [**snippet**](https://github.com/wacht-platform/snippet-service), the open-source AI coding agent. Run `snippet serve` on your dev box and drive it from anywhere — chat with the agent, browse and edit files, review git diffs, run commands, and manage sessions, over an authenticated tunnel.

[![download APK](https://img.shields.io/badge/download-snippet.apk-3ddc84.svg)](https://github.com/wacht-platform/snippet-mobile/releases/download/apk-latest/snippet.apk)
[![platform: Android](https://img.shields.io/badge/platform-Android-3ddc84.svg)](#platforms)
[![built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B.svg)](https://flutter.dev)
[![license: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

A native **Android** app — one adaptive UI that also scales up on tablets.

_Built by the team behind [Wacht](https://wacht.dev) — open-source infrastructure for AI-native apps._

</div>

---

Your coding agent runs on your machine; this app is the window into it. Start a task at your desk, then pick it up from the couch — same session, live. Nothing runs in our cloud: the app talks directly to *your* `serve` daemon over a token-authenticated [cloudflared](https://github.com/cloudflare/cloudflared) tunnel.

## Download & install

**Android — no toolchain needed:**

### → [**Download snippet.apk**](https://github.com/wacht-platform/snippet-mobile/releases/download/apk-latest/snippet.apk)

Open the link on your phone and tap the file to install (allow *"install unknown apps"* if prompted). This is a **rolling build**: every push to `main` refreshes that same URL with a fresh arm64 APK (~25 MB), built for free on GitHub's runners. It's debug-signed, so if an older install refuses to update over it, uninstall the old one first.

## Platforms

| Platform            | Status                        |
| ------------------- | ----------------------------- |
| **Android** (arm64) | ✅ Primary target — polished  |

> Looking for a desktop client? It's a separate native app — see [snippet-desktop](https://github.com/wacht-platform/snippet-desktop).

## Features

- **Sessions across every machine** you've connected — open, resume, rename, delete; switch machines from a dropdown in the header.
- **Tabs** — keep multiple sessions and files open at once; a strip under the toolbar switches between them, or swipe.
- **Chat** with the agent: streaming replies, inline tool activity, approvals, and steering mid-run. Markdown is fully **selectable** for copy-out.
- **Files** — browse, view with syntax highlighting, edit (with conflict detection), upload, download, create folders, select/delete — with or without a session open.
- **Media** — preview **images** inline and **stream videos** straight from the daemon over HTTP range requests, without downloading first.
- **Downloads that land where you expect** — saved to your device's **Downloads** folder with a native notification and **Open** / **Share** actions.
- **Git** — status, per-file diffs, stage/commit, branch switch, push/pull — scoped to a folder or a session.
- **Per-chat model** — switch the model for a single conversation from your phone, and set reasoning effort.
- **Add a machine by QR** — scan the code from `snippet serve`, or paste the connection URL — a dedicated add-instance screen.
- **Attachments** — send images and files (camera / photos / files).
- **Notifications** when a session needs input or finishes.

## Connecting

On your dev machine, run `snippet serve` — it prints a QR code and a connection string (`{url, token}`). In the app, tap **add machine**, then **scan the QR** or paste the URL. That's it; you're driving your machine's agent. Add as many machines as you like and switch between them from the header.

## Build & run

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```sh
flutter pub get
flutter run                                      # a connected Android device / emulator

flutter build apk --release --target-platform android-arm64   # slim arm64 APK (what CI ships)
flutter build apk --release                                   # universal APK (all ABIs, larger)
```

## The agent itself

This is just the remote. The engine — the durable coding agent, the `serve` daemon, model configuration — lives in the [**snippet**](https://github.com/wacht-platform/snippet-service) repo.

## From the team behind Wacht

A project from **[Wacht](https://wacht.dev)** — open-source infrastructure for AI-native apps (identity, organizations, machine auth, webhooks, and an agent runtime). Building AI-native apps? → **[wacht.dev](https://wacht.dev)**.

## License

Copyright (C) 2026 snipextt. Licensed under **AGPL-3.0-or-later** — see [LICENSE](LICENSE). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
