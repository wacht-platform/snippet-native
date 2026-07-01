<div align="center">

<img src="https://raw.githubusercontent.com/wacht-platform/snippet-service/main/snippet-mascot/png/snip-mascot-256.png" alt="snippet mascot" width="132" height="132" />

# snippet — mobile & desktop

**Control your terminal coding agent from your phone or your Mac.**

The remote client for [**snippet**](https://github.com/wacht-platform/snippet-service), the open-source AI coding agent. Run `snippet serve` on your dev box and drive it from anywhere — chat with the agent, browse and edit files, review git diffs, run commands, and manage sessions, over an authenticated tunnel.

One adaptive UI, native on **Android** and **macOS**.

_Built by the team behind [Wacht](https://wacht.dev) — open-source infrastructure for AI-native apps._

</div>

---

Your coding agent runs on your machine; this app is the window into it. Start a task at your desk, then pick it up from the couch — same session, live. Nothing runs in our cloud: the app talks directly to *your* `serve` daemon over a token-authenticated [cloudflared](https://github.com/cloudflare/cloudflared) tunnel.

## Features

- **Sessions across every machine** you've connected — open, resume, rename, delete.
- **Chat** with the agent: streaming replies, inline tool activity, approvals, and steering mid-run.
- **Files** — browse, view with syntax highlighting, edit (with conflict detection), upload, download, create folders, and select/delete — with or without a session open.
- **Git** — status, per-file diffs, stage/commit, branch switch, push/pull — scoped to a folder or a session.
- **Per-chat model** — switch the model for a conversation from your phone; set reasoning effort.
- **Attachments** — send images and files (camera / photos / files, drag-and-drop on desktop).
- **Notifications** when a session needs input or finishes (Android + macOS).

## Connecting

On your dev machine, run `snippet serve` — it prints a QR code and a connection string (`{url, token}`). In the app, add an instance by pasting it. That's it; you're driving your machine's agent.

## Build & run

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```sh
flutter pub get
flutter run -d macos        # desktop
flutter run                 # a connected Android device / emulator
flutter build apk --release --split-per-abi
```

## The agent itself

This is just the remote. The engine — the durable coding agent, the `serve` daemon, model configuration — lives in the [**snippet**](https://github.com/wacht-platform/snippet-service) repo.

## From the team behind Wacht

A project from **[Wacht](https://wacht.dev)** — open-source infrastructure for AI-native apps (identity, organizations, machine auth, webhooks, and an agent runtime). Building AI-native apps? → **[wacht.dev](https://wacht.dev)**.

## License

Copyright (C) 2026 snipextt. Licensed under **AGPL-3.0-or-later** — see [LICENSE](LICENSE). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
