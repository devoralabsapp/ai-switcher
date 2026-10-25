<p align="center">
  <img src="docs/assets/icon.png" width="88" alt="AI Switcher icon">
</p>

# AI Switcher for macOS

**Switch between your ChatGPT accounts with one click. Keep a separate browser session for each account.**

AI Switcher is a small, native macOS utility built with SwiftUI and AppKit. Add a profile for each of your accounts, sign in directly on ChatGPT, then return to the right window from the dashboard or menu bar. Closing the manager leaves the menu bar available.

**macOS 13+ · Intel and Apple Silicon · Swift · MIT license**

[![macOS build](https://github.com/devoralabsapp/ai-switcher/actions/workflows/macos.yml/badge.svg)](https://github.com/devoralabsapp/ai-switcher/actions/workflows/macos.yml)

[Download preview](https://github.com/devoralabsapp/ai-switcher/releases) ·
[Hướng dẫn tiếng Việt](docs/README.vi.md) · [Architecture](docs/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md) · [Roadmap](docs/ROADMAP.md)

## Why it exists

Moving between personal, work, and study accounts should not interrupt a conversation. AI Switcher gives each account a named, persistent browser profile and makes those profiles easy to reopen. It keeps authentication in a real browser, including the normal Google and Apple sign-in flows, instead of asking users to hand over passwords or session tokens.

This is an independent utility. It opens ChatGPT in dedicated browser windows and does not change the account in OpenAI's official desktop app. Account labels are entered by the user; the app does not verify the identity signed in to ChatGPT.

## Features

- Open a profile with one click from its card; select profiles from the macOS menu bar.
- Bring an existing profile window forward instead of opening a duplicate on each switch.
- Keep browser sessions separate with a unique data directory for every profile.
- Name profiles, add an optional email label, assign colors, and mark favorites.
- Search profiles and filter by favorites or recent use.
- Edit labels, open another window, close a profile session, or delete its local data.
- Use Google Chrome, Microsoft Edge, or Brave; each profile stays with its original browser.
- Use a Vietnamese interface, with English contributor documentation.
- Run locally without an API key, account on another service, or third-party Swift packages.

## Project status

**Early preview.** The initial implementation has 13 unit tests. Local integration checks with Google Chrome verify separate processes, correct profile selection, reuse of an existing window, and persistent, isolated cookies and localStorage on a loopback fixture.

The initial build was tested on an Intel Mac. The bundle also compiles for Apple Silicon, but it has not yet been validated on Apple Silicon hardware or on every supported macOS version. Edge and Brave are implemented but do not yet have the same integration coverage. Real ChatGPT sign-in remains a manual check; there are no credentials in tests or CI.

## Build and install

Prebuilt previews, when available, are listed under [Releases](https://github.com/devoralabsapp/ai-switcher/releases). Each includes a ZIP and `SHA256SUMS.txt`. Extract the ZIP and move the app to Applications. These previews are signed ad hoc and are not notarized; build from source if you prefer to inspect and compile the code yourself.

Requirements:

- macOS 13 or newer.
- Xcode or Command Line Tools with Swift 5.9 or newer. The universal build uses Xcode's build tools.
- At least one supported browser installed.
- Python 3 for packaging the app icon.

From the repository root:

```sh
bash scripts/build.sh
```

The app is written to `dist/AI Switcher.app`. Open it in Finder and optionally move it to Applications.

For a bundle containing both CPU architectures:

```sh
bash scripts/build.sh --universal
```

Builds are signed ad hoc for local use. They are not Developer ID signed or notarized. GitHub Actions also builds a universal bundle and saves a ZIP as a workflow artifact; the source build remains available without downloading a prebuilt app.

To create the release ZIP and checksum from an existing build:

```sh
bash scripts/package.sh
```

## First use

1. Open AI Switcher and choose **Thêm tài khoản** (Add account).
2. Choose a recognizable name, a color, and an installed browser. The email field is an optional label.
3. Sign in to the intended ChatGPT account in the new window. Check the account shown inside ChatGPT.
4. Repeat for your other accounts.
5. Choose **Mở ChatGPT** (Open ChatGPT) or select a profile from the menu bar whenever you want to switch.

Sessions are reused while the browser and ChatGPT consider them valid. If you sign out or the service expires a session, sign in again inside that profile.

### Shortcuts

These apply while AI Switcher is the active app.

| Shortcut | Action |
| --- | --- |
| ⌘1–⌘9 | Open the corresponding profile |
| ⌘N | Add a profile |
| ⌘K | Focus account search |
| ⌘0 | Show the manager |
| ⌘W | Close the manager window, keeping the menu bar available |
| ⌘Q | Quit AI Switcher |

## Privacy and session storage

The application does not inspect passwords, cookies, authentication tokens, or conversations. The browser manages sign-in in its own profile directory. AI Switcher does not add analytics, a backend, browser extensions, remote debugging ports, or credential synchronization. ChatGPT and the browser still make their usual network requests.

```text
~/Library/Application Support/AI Switcher/
├── accounts.json          # Names, optional email labels, colors, and recent-use metadata
└── Profiles/
    └── <UUID>/            # A dedicated browser data directory for one profile
```

New app directories use permissions `0700`; the metadata file uses `0600`. These profiles belong to the current macOS user. They are not a separate encrypted vault or a boundary against other software running as that user. Treat profile directories as private browser data.

The app creates its own profiles. It does not import or edit your everyday browser profile. When switching windows or closing sessions, it matches the browser's exact data-directory argument, not just the browser name.

Close a profile session before deleting it. Deleting a profile removes its app-managed local data and label; it does not delete the ChatGPT account, delete server-side conversations, or revoke every session on the service. Browser-managed caches may also exist outside the app's profile directory.

For security reports, see [SECURITY.md](SECURITY.md).

## Development and tests

Run the unit suite:

```sh
bash scripts/test.sh
```

Run local browser checks as well:

```sh
bash scripts/test.sh --browser
```

The browser checks require Google Chrome and a logged-in graphical macOS session. They open two disposable test windows, close only those dedicated sessions, then use Chrome headless with an HTTP fixture on `127.0.0.1` to check cookie and localStorage persistence. No ChatGPT account is required. The GUI checks are kept local; CI runs the unit suite and builds the app.

Use a separate development data directory:

```sh
"dist/AI Switcher.app/Contents/MacOS/AISwitcher" --data-dir /tmp/ai-switcher-dev
```

The unit tests cover metadata round trips, corrupt-file handling, permissions, validation, profile separation, exact process matching, deletion isolation, and rollback when a deletion cannot save metadata.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Sources/AISwitcherCore` | Account models, metadata persistence, and browser arguments |
| `Sources/AISwitcher` | SwiftUI dashboard, AppKit menus, and browser lifecycle |
| `Tests/AISwitcherCoreTests` | Unit tests for data and process routing |
| `scripts` | Build, original icon generation, packaging, and browser checks |
| `.github/workflows` | macOS test and universal-build workflow |
| `docs` | Vietnamese guide, architecture notes, and roadmap |

## Contributing

Bug reports, reproducible browser compatibility reports, accessibility improvements, and localization work are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and review expectations.

The initial implementation was developed with assistance from OpenAI Codex. Contributors remain responsible for understanding their changes, protecting session data, and reporting what they actually tested.

## License and acknowledgments

Released under the [MIT License](LICENSE).

Profile separation follows Chromium's documented [`--user-data-dir` mechanism](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md). The app icon is generated from original geometric drawing code in this repository. ChatGPT, browser names, and related marks belong to their respective owners. AI Switcher is not affiliated with or endorsed by OpenAI or the browser vendors.
