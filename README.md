<p align="center"><img src="docs/assets/icon.png" width="88" alt="AI Switcher icon"></p>

# AI Switcher for macOS

**One click to the right ChatGPT Desktop session. A separate profile for each account, with Codex quota on every card.**

AI Switcher is a native SwiftUI and AppKit utility. Add your accounts, sign in once in each dedicated ChatGPT Desktop window, then switch from the dashboard or macOS menu bar. Daily switching requires no Chrome.

**macOS 13+ · Intel and Apple Silicon · Swift · MIT license**

[![macOS build](https://github.com/devoralabsapp/ai-switcher/actions/workflows/macos.yml/badge.svg)](https://github.com/devoralabsapp/ai-switcher/actions/workflows/macos.yml)

[Download preview](https://github.com/devoralabsapp/ai-switcher/releases) · [Tiếng Việt](docs/README.vi.md) · [Architecture](docs/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md) · [Roadmap](docs/ROADMAP.md)

## What it does

- Launch the installed, official ChatGPT app with separate UI data and a separate local backend for each profile.
- Bring the exact existing profile process forward when switching.
- Show Codex quota remaining, hour/week windows, reset times, and the backend's account identity.
- Refresh quota manually or every five minutes while the profile backend is running.
- Name, color, favorite, search, and revisit profiles from a Vietnamese dashboard and menu bar.
- Close a profile without deleting its login, or explicitly delete its local data after closing.
- Keep the previous Chrome/Edge/Brave mode available for browser profiles.
- Run without an API key, a hosted service, or third-party Swift packages.

This is an independent, **experimental** utility. Desktop profiles rely on internal launch settings in the new ChatGPT app with Chat, Work, and Codex (`com.openai.codex`). ChatGPT Classic is not supported. OpenAI does not document this as a supported multi-account interface; an app update can break compatibility. AI Switcher checks for the required mechanisms and reports an error if they are absent. It never silently falls back to Chrome.

## Install and use

Download a ZIP and `SHA256SUMS.txt` from [Releases](https://github.com/devoralabsapp/ai-switcher/releases), extract it, and move **AI Switcher.app** to Applications. Previews are signed ad hoc and are not notarized; source builds are also available.

1. Install the new ChatGPT Desktop app at `/Applications/ChatGPT.app` or `~/Applications/ChatGPT.app`.
2. In AI Switcher, choose **Thêm tài khoản**, enter a name, and leave **ChatGPT Desktop** selected. The email field is an optional label.
3. Sign in to the intended account inside the new ChatGPT window. Verify its account menu. Normal authentication may open your system browser once; Chrome is not required for subsequent switching.
4. Repeat for the other accounts. The first launch of each profile can take longer while its backend is installed.
5. Use **Mở ChatGPT** or choose the profile from the menu bar to bring its window forward.

Existing profiles without an explicit mode now open in Desktop mode. They require one new sign-in; previous browser sessions and their separate quota connections are retained. To use them again, close the profile using **⋯ → Đóng phiên tài khoản…**, edit it, and choose **Trình duyệt**. Modes cannot change during an active session or quota operation.

Closing the manager keeps the menu bar available. Quitting AI Switcher leaves Desktop sessions running. **Đóng phiên tài khoản…** requests a normal quit of only that profile's applications and stops its backend; it does not force-quit. Service session expiry can still require a new sign-in.

| Shortcut (while AI Switcher is active) | Action |
| --- | --- |
| ⌘1–⌘9 | Open the corresponding profile |
| ⌘N / ⌘K / ⌘0 | Add / search / show manager |
| ⌘W / ⌘Q | Close manager / quit AI Switcher |

## Codex quota

For Desktop profiles, sign in inside that Desktop window, then choose **Làm mới quota**. The reader connects to the **same local backend** as that window, using a local WebSocket bridge included in AI Switcher. It does not establish a second quota login or import your default Codex session. The returned email/plan identifies the quota account; profile names remain user-entered labels. Sign out within the relevant ChatGPT window when changing its account.

Cards and the menu bar show **remaining** quota in the windows returned by Codex, such as five hours and a week. Details include all separate limit buckets and reset timestamps. Missing windows remain unknown. Snapshots are marked stale after six minutes, reset expiry, or a failed refresh; a reset timestamp never invents a refill. Closing the profile stops live refresh and leaves the last cached snapshot.

Browser-mode profiles retain the optional **Kết nối → Đăng nhập Codex → Dùng tài khoản này** flow. Their Codex login is separate from browser ChatGPT login and requires identity confirmation. **Ngắt kết nối** removes only that browser profile's separate Codex home.

Quota uses [`account/read` and `account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server). The reader performs no model turns and redeems no reset credits.

## Privacy and storage

AI Switcher does not read passwords, cookies, token files, or conversations. ChatGPT and Codex manage their own authentication and usual network requests. AI Switcher reads identity and quota protocol responses and caches them in `accounts.json`. Child environments exclude inherited API keys and authentication/CLI overrides.

```text
~/Library/Application Support/AI Switcher/
├── accounts.json                  # Labels, selected mode, identities and cached quota
├── Desktop/<UUID>/UserData/        # ChatGPT Desktop UI and browser storage
├── Desktop/<UUID>/backend-location.txt
├── Profiles/<UUID>/               # Optional legacy browser profile
└── Codex/<UUID>/                  # Optional browser-mode quota login

~/.aisw/<profile-key>/             # Desktop backend, configuration and authentication
└── ai-switcher-profile.json       # Ownership marker: app-data root and profile UUID
```

The short `~/.aisw` location keeps Unix socket paths within macOS limits. Its stable key hashes the app-data root and profile UUID, so development and production profiles do not share a backend. An ownership marker must match before the app reuses or removes a backend. A new profile never imports your default ChatGPT or `~/.codex` data. Desktop backends use file-based credentials managed by Codex.

New app directories use `0700`, and metadata uses `0600`. These are private sessions belonging to the current macOS user, **not an encrypted vault** or protection from other software running as that user. Do not upload profile data to GitHub. Exact process arguments identify the profile before focus or termination; the app never quits every process named ChatGPT.

Close a profile before deletion. Deletion stages its Desktop, backend, browser and optional Codex directories, saves metadata, then removes them; metadata-save failure restores staged data. It does not delete service accounts or server-side conversations. OS-level deep links, notifications, permissions, and other bundle-ID integrations may be shared between instances; check the intended window when using them. See [SECURITY.md](SECURITY.md).

## Build and verify

Use macOS 13+, Xcode/Command Line Tools with Swift 5.9+, and Python 3 for icon packaging. Desktop runtime additionally needs the compatible ChatGPT app; browser mode needs Chrome, Edge, or Brave.

```sh
bash scripts/test.sh
bash scripts/build.sh --universal
bash scripts/package.sh
```

Output: `dist/AI Switcher.app`, `dist/AI-Switcher-macOS.zip`, and `dist/SHA256SUMS.txt`. Omit `--universal` for a local-architecture build. GitHub Actions runs offline tests and builds/packages both architectures.

Local integration checks require a graphical macOS login session:

```sh
bash scripts/test.sh --desktop  # Two disposable real ChatGPT instances and local backend connections
bash scripts/test.sh --browser  # Chrome windows plus loopback cookie/localStorage fixture
bash scripts/test.sh --codex    # Installed CLI handshake in a fresh unauthenticated home
```

The core/protocol suite has 46 tests covering storage, ownership, migration, exact routing, deletion/rollback, quota semantics, and JSONL lifecycle. Desktop smoke checks verify distinct processes, empty identities through each shared backend, window reuse, close/reopen persistence, and cleanup without closing existing ChatGPT instances. No real accounts or model requests are used in automated checks.

**Early preview:** local checks run on Intel with ChatGPT Desktop 26.1021.31345. Universal compilation does not establish Apple Silicon runtime coverage. Real sign-in, live quotas, minimized windows, multiple Spaces, and OS deep-link routing still require manual field testing. Edge/Brave have less integration coverage than Chrome. The interface is Vietnamese; English localization is planned.

Use a separate development profile root:

```sh
"dist/AI Switcher.app/Contents/MacOS/AISwitcher" --data-dir /tmp/ai-switcher-dev
```

## Contribute

Compatibility reports, accessibility improvements, and localization contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). The initial implementation was developed with OpenAI Codex assistance; contributors are responsible for checking changes and reporting actual validation.

Released under the [MIT License](LICENSE). The icon is original geometric drawing code in this repository. Legacy browser isolation follows Chromium's [`--user-data-dir` mechanism](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md). AI Switcher is not affiliated with or endorsed by OpenAI or browser vendors.
