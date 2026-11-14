# AI Switcher for Windows — preview

A native .NET 10 / WPF companion to the macOS app. The two apps are maintained in the same repository; Windows has its own process, filesystem, window and notification adapters.

[Tiếng Việt](README.vi.md)

## Install

Download the standalone **win-x64 EXE** (Intel/AMD) or **win-arm64 EXE** from [Releases](https://github.com/devoralabsapp/ai-switcher/releases) and run it directly. A ZIP with documentation is also available.

For ZIP builds, download the **win-x64** ZIP for Intel/AMD PCs, or **win-arm64** for Windows on ARM, from the Windows workflow artifacts. Extract the whole ZIP to a writable folder and run **AISwitcher.exe**. No .NET installation or administrator access is required. Preview builds are unsigned. SHA-256 files accompany each ZIP. Windows 11 is the primary validation target; vendor apps and Windows AF_UNIX support must also be available. ARM64 packages are cross-built; native ARM64 runtime testing is still required.

Do not run this app as Administrator and do not copy authentication directories between operating systems. Install the official apps/browsers normally. Settings lets you choose existing executable paths when automatic detection does not find a Store/MSIX/Squirrel installation.

## Features

- ChatGPT and Claude Desktop profiles with separate user-data directories, exact executable/argument routing, focus/reopen, and normal targeted close.
- Chrome, Edge and Brave profiles for Gemini, Perplexity and DeepSeek. ChatGPT and Claude use Desktop with a separate sign-in-method choice.
- Multiple private Antigravity profiles with Google browser or official CLI sign-in, email/plan and separate model quota groups. Existing shared entries keep their original behavior.
- Claude Code CLI subscription quota with a separate sign-in per profile. Connect reads quota in the background without a model prompt. See [provider setup](../README.md#claude-and-antigravity-quota).
- Agent sidebar filters, search, favorites, recents and per-profile colors.
- Eleven palettes synchronized from macOS: Light, Dark, Terminal, Code, Dracula, Playful Retro Neo-Brutalism, Terminal Black, Halloween, Christmas, Tet Holiday, Black Friday. Matching English/Vietnamese catalogs are shared.
- Quota-only beside Add account; disabling always returns to cards. Layout choice remains in Settings. Default per-profile actions and opt-in startup connections are retained.
- ChatGPT/Codex quota, independent limit groups, real reset times, freshness/error labels, numeric sorting and identity verification. No model turns or reset credits are used.
- Headless ChatGPT backend connect/close/restart, explicit Desktop launch, and disabled Connect while a profile is already running. Closing a session now also waits for and stops verified headless Desktop/Codex descendants after the main app agrees to quit. An orphaned backend keeps the profile marked running and Connect disabled until it is closed; another account and separately opened apps are preserved.
- System-tray account menus, silent low/recovered quota notifications, persistent alert deduplication, and notification clicks opening account details. Alerts are opt-in and obey Windows notification settings.
- Session diagnostics, executable selection and private storage checks. Closing the manager hides it. Quit from the tray closes its managed quota RPC connections while leaving external Desktop windows/legacy daemons running.
- Optional shared local ChatGPT transcript storage and allowlisted project/sidebar metadata. Select the original local `.codex` workspace in Settings, then opt in on a stopped profile. Top-level `sqlite_home` is honored; Settings also offers an explicit database-folder override and an optional original Work artifact folder. Nonempty private history is preserved and blocks conversion. The source workspace is never deleted with a profile.
- Shared native local projects are account-neutral. On opening or connecting a shared profile, AI Switcher removes account-specific ChatGPT project links from the projected sidebar state and native local project metadata. Close account 1, open account 2, then continue the existing local conversation normally: no selector, branch or new conversation ID. Project folders, thread/project membership, historical creator information and authentication stay intact. Cloud project mirrors and managed `.chatgpt-projects` folders retain ownership. Original associations are saved under `SharedWorkspaceAccountLinks/` before transactional updates; the source UI state file is preserved. This applies only to profiles explicitly opted into the same shared local workspace. Real cross-account service behavior still requires field validation.

### Account setup

For ChatGPT or Claude, choose **Sign-in Method → Browser / Desktop app / CLI** when adding or editing. **Open** always opens that account's Desktop app. ChatGPT Browser opens personal Chrome for official OAuth and stores the returned login in its own Desktop backend home; CLI runs official `codex login` against that same private home. Claude Browser opens its own Desktop authorization flow, which uses the system default browser: set Chrome as default to confirm through personal Chrome. The app checks this without changing browser defaults. Claude CLI signs in to Claude Code for quota and opens Desktop; **Desktop still requires a separate first sign-in**, and Free may not support Code. Use **⋯ → Sign in…** to repeat the chosen method on a stopped account. Legacy web sessions must be closed first; their files and cached web quota are preserved when moving to Desktop.

ChatGPT Desktop requires the newer compatible Electron app with Codex, its bundled/installed native Windows `codex.exe`, and internal isolation switches. Classic ChatGPT is not supported. Claude uses the installed, unmodified app's `--user-data-dir` mechanism. No bundle patches, debug ports, credential extraction, API keys, WSL or browser automation permissions are used.

**Desktop integrations are experimental.** Windows runtime checks use process/UI fixtures and signed-out native Codex RPC; live Windows ChatGPT/Claude sign-in, Store update behavior, OAuth/deep links, live quota, Claude Code/Cowork, and multi-profile shared Work artifacts still need field testing on machines with those apps. Local transcript/database sharing, allowlisted metadata projection, retained sidebar archives and an optional explicitly selected Work artifact folder are implemented. Vendor-specific Work UI behavior still needs field validation. A refused close reports an error and does not force-kill an app. Some apps keep running in their own tray after the last window closes; use that app's Quit action when requested. There is no promise of full vendor compatibility from an offline test run.

## Microsoft Store troubleshooting

Windows can refuse to execute the Store app's protected `WindowsApps` executable (error 5), even when the official app opens from Start and a native Codex CLI is installed. Preview 3 prepares a private program runtime from the registered official `OpenAI.Codex` installation before starting a Desktop profile. It streams the app's program files into `Runtimes\chatgpt\<version-key>` beneath the AI Switcher data root, preserving file contents without copying Store encryption/ACL attributes. The runtime is reused across profiles; each profile still has its own UI and Codex home. No sign-in data is copied from the original app.

The first open requires additional disk space approximately equal to the app's program directory and can take a few minutes. The UI shows preparation status. Source files and WindowsApps permissions stay unchanged. Store version changes get a new cache key; existing runtime versions are retained so already-running profiles are not removed. Critical executable/archive hashes are checked before reusing the cache. The runtime is an unmodified program copy; live Store-dependent features and vendor updates still need field testing.

Codex CLI discovery validates console binaries and `codex-cli --version`, rejecting GUI binaries and protected Store aliases. Diagnostics shows both the installed ChatGPT path and the prepared runtime path. Reset a stale manually selected `codex` path in Settings if needed. There is no fallback to the default shared sign-in.

Preview 5 fixes reuse of existing runtime metadata when installed filenames differ in letter case. Windows filename matching now remains case-insensitive after restarting AI Switcher. Existing runtimes and account profiles are reused without recreating accounts. Automated Windows checks reopen both official Desktop apps through their registered Store paths and launch a fresh AI Switcher process with the saved profile and preferences.

## Session status, scrollbars and emergency stop

Preview 6 reports a Desktop process whose window has closed into its tray as **Running in background**. Once the process and live backend exit, **Close account session** is disabled and **Connect account session** becomes available. Menus refresh when action availability changes, even if a quota error label stays the same.

**Force stop all…** is available in the left navigation, tray and diagnostics. It cancels pending account actions, closes managed quota RPC connections and force-stops verified account processes and descendants tracked while their parent was alive. PID creation times are checked again before termination. It keeps account files and sign-ins. Applications opened separately, other manager roots and the shared Antigravity launcher are excluded; processes that cannot be safely attributed are not terminated. Unsaved work in stopped sessions can be lost. Failed stops are reported rather than treated as success.

Scrollbars use theme colors, a rounded thumb and accent hover/drag states in both orientations. Keyboard, paging and line scrolling are preserved.

## Claude Store and closing Desktop sessions

Preview 4 adds a separate `Runtimes\claude\<version-key>` cache for the registered official Claude package (`Claude_pzs8sxrjxfjjc`). ChatGPT's existing cache and profiles are retained. Each Claude Desktop account has its own user-data and Code config directories; legacy browser-mode Claude data is preserved when moving to Desktop.

Close account session now requests a normal Windows application shutdown for exactly the profile PID and creation time through Restart Manager. This also reaches a Desktop app whose window is hidden in its tray. No force-shutdown flag is used. A refusing application stays running and the manager asks you to finish its confirmation or Quit from its own tray menu. Other profiles are not registered for shutdown. Cached sign-in data is retained.

## Data

Metadata and preferences: `%LOCALAPPDATA%\AISwitcher` by default. `--data-dir` selects a separate manager root. The root uses a current-user-only DACL, and a file lease prevents simultaneous managers writing the same root. Profile storage carries a root/UUID ownership marker; reuse, close and deletion reject mismatched ownership/reparse points.

- `Profiles\<UUID>` — Chromium profile.
- `Claude\<UUID>\UserData` and `CodeConfig` — Claude UI and configuration.
- `Desktop\<UUID>\UserData` — ChatGPT UI.
- `Codex\<UUID>` — browser-mode Codex sign-in.
- `%USERPROFILE%\.aisw\win-<hash>` — short, root-specific ChatGPT backend home.

New background connections use a native stdio RPC process owned by AI Switcher, with one private Codex home per account. They do not require a local daemon, Task Scheduler or Unix socket. An existing legacy daemon is adopted only after a successful live handshake; leftover socket files never count as a running session. Shared transcripts and explicitly selected artifacts use targeted junctions on opted-in profiles only; authentication and cookies are never linked. Original private artifact caches are backed up and restored when sharing is disabled. SQLite rollout paths are canonicalized inside a transaction through Windows’ SQLite library before closing/deleting a shared profile; live databases/WAL files are never copied. Legacy daemon discovery still respects Windows Unix-socket limits.

Storage is private to the current Windows user, not an encrypted vault. Never upload account data. Deletion stages only owned profile directories; failed metadata saves roll them back. Last cached quota remains visibly stale after reset, six minutes, or an error; reset timers never fabricate refill or recovery alerts.

## Build and verify

Install the official .NET 10 SDK. In `Windows/`:

```powershell
dotnet run --project AISwitcher.Tests/AISwitcher.Tests.csproj -c Release
../scripts/build-windows.ps1 -Runtime win-x64
../scripts/build-windows.ps1 -Runtime win-arm64
```

The output is `Windows/artifacts/AI-Switcher-Windows-<runtime>.zip` and `.sha256`. The app is self-contained; it includes the .NET runtime. Rebuild previews to receive runtime security updates.

The Windows workflow checks shared resources, runs portable core/RPC tests, publishes both architectures, then launches the x64 WPF app to verify all themes/languages, key controls, cards/table transitions, dialogs, native process routing, and targeted close using disposable process fixtures. The released standalone EXE also verifies initialize/account-read against official native Windows Codex in a fresh signed-out home. Managed background connect/stop/reconnect and cancellation are exercised with real native Codex RPC. The old daemon-launch restriction on hosted runners no longer blocks new connections. PNG previews and test results are uploaded with the build. It never signs into vendor accounts or reads their existing credentials.

The core suite also runs on macOS/Linux with .NET 10. The WPF app can be cross-compiled with `EnableWindowsTargeting`, but only Windows can execute/render it. Use `python3 scripts/sync-windows-assets.py` from the repository root after editing Swift palettes or localization; Windows-specific translations are in `Windows/Strings.vi.json`.

### Seasonal themes

Halloween, Christmas, Tet Holiday and Black Friday each have a distinct palette, original vector artwork in the dashboard banner and theme picker, sidebar identity and matching account-card ribbons. The shared artwork and palettes render on macOS and Windows. Decorations are static, ignore pointer input and keep all existing account actions and data unchanged. Select a theme in Appearance & Language; selections persist after relaunch.

### Install missing Claude / Antigravity CLI

Click **Install & connect** on the provider card or in Details. AI Switcher opens PowerShell and runs the official native installer with ordinary user permissions, then checks the CLI version and attempts to connect. The action is hidden when a CLI is already detected. No npm or app restart is needed. Install failures remain visible in PowerShell and the app. Background refresh never installs software; quitting the manager leaves the visible installer running. Installation and provider sign-in are separate steps.

Switching ChatGPT accounts through AI Switcher in a shared local workspace renews the selected account’s existing Desktop/backend before opening it. Reopening the current account keeps its window. A refused ordinary quit aborts the switch. Sign-in, projects and conversation history are preserved; taskbar-only switches do not trigger this handoff. Account cards use independent responsive columns.

New Antigravity profiles now match macOS features: separate Desktop/user-data and home directories, browser Google OAuth or official CLI sign-in, per-profile email/plan, independent Gemini and Claude/GPT quota buckets, refresh/details and scoped session close. Existing shared Antigravity entries retain their sign-in; add a new entry for a private profile. Browser mode needs the current Antigravity App (Hub), not the standalone IDE, and does not require CLI installation.

Windows uses the vendor's file-storage compatibility adapter (`WSL_INTEROP`) to opt out of its otherwise shared Credential Manager entry, with a private `USERPROFILE`, `HOME`, `APPDATA` and `LOCALAPPDATA`. It does not create Windows users, change global credentials, patch vendor binaries or launch WSL. This is a version-specific vendor integration, not an OS security boundary. The native integration fixture tests the official Hub/CLI with a synthetic global Credential Manager item and checks that private sessions remain signed out and leave it unchanged. Unsupported native versions are rejected. [Google documents unified authentication](https://antigravity.google/docs/install?tab=cli); a private user-data directory alone does not separate that shared sign-in.

Antigravity browser sign-in and the explicit Codex quota sign-in open the installed Chrome using the user's ordinary browser session. Google confirmation returns to the selected private backend through its local callback. Older private OAuth browser windows can still be closed through the profile menu using the existing ownership checks. Website-only agent sessions authenticate in their own browser store unless the provider supports returning authorization to that separate session.

### Share all Antigravity Desktop projects and conversations

**Share local project** in Add/Edit account uses the original Desktop catalog and local conversation store for every opted-in private account. It requires no folder picker. Profiles with separate workspaces can open concurrently. Shared profiles open one at a time, and opening another profile closes a managed session with fresh, exhausted quota in every reported group. After browser sign-in, use **Open Antigravity** in AI Switcher to open that profile. A supported Google sign-in from the CLI can seed the first Desktop launch in the same private profile. Existing private histories are imported and indexed under their original IDs, with conflicts reported before replacing private directories. Originals are archived under `SharedProjectsBackup`; disabling sharing restores them on the next Open/Connect. Deleting a profile leaves the shared source intact. Preview 23/24 folder selections migrate to this all-project setting.

## Claude quota for Desktop and Free

All three sign-in methods read account/plan/usage from the same owned Desktop profile. Free is queried too; actual numbers are displayed only when Claude returns them. The reader opens SQLite read-only, decrypts only the scoped session cookie with that profile's DPAPI/AES-GCM key, and makes allowlisted HTTPS GET requests with redirects disabled. It reads no conversations and copies no credentials into account metadata or logs. App-bound/unknown encryption fails closed without changing sign-in. No Claude Code installation or additional CLI login is needed for Desktop quota. Numeric usage is not guaranteed for Free accounts.
