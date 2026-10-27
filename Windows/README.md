# AI Switcher for Windows — preview

A native .NET 10 / WPF companion to the macOS app. The two apps are maintained in the same repository; Windows has its own process, filesystem, window and notification adapters.

[Tiếng Việt](README.vi.md)

## Install

Download the standalone **win-x64 EXE** (Intel/AMD) or **win-arm64 EXE** from [Releases](https://github.com/devoralabsapp/ai-switcher/releases) and run it directly. A ZIP with documentation is also available.

For ZIP builds, download the **win-x64** ZIP for Intel/AMD PCs, or **win-arm64** for Windows on ARM, from the Windows workflow artifacts. Extract the whole ZIP to a writable folder and run **AISwitcher.exe**. No .NET installation or administrator access is required. Preview builds are unsigned. SHA-256 files accompany each ZIP. Windows 11 is the primary validation target; vendor apps and Windows AF_UNIX support must also be available. ARM64 packages are cross-built; native ARM64 runtime testing is still required.

Do not run this app as Administrator and do not copy authentication directories between operating systems. Install the official apps/browsers normally. Settings lets you choose existing executable paths when automatic detection does not find a Store/MSIX/Squirrel installation.

## Features

- ChatGPT and Claude Desktop profiles with separate user-data directories, exact executable/argument routing, focus/reopen, and normal targeted close.
- Chrome, Edge and Brave profiles for ChatGPT, Claude, Gemini, Perplexity and DeepSeek.
- Antigravity launcher with the application's existing shared sign-in; it has no per-account isolation, quota or close action.
- Agent sidebar filters, search, favorites, recents and per-profile colors.
- Seven palettes synchronized from macOS: Light, Dark, Terminal, Code, Dracula, Playful Retro Neo-Brutalism, Terminal Black. Matching English/Vietnamese catalogs are shared.
- Quota-only beside Add account; disabling always returns to cards. Layout choice remains in Settings. Default per-profile actions and opt-in startup connections are retained.
- ChatGPT/Codex quota, independent limit groups, real reset times, freshness/error labels, numeric sorting and identity verification. No model turns or reset credits are used.
- Headless ChatGPT backend connect/close/restart, explicit Desktop launch, and disabled Connect while a profile is already running.
- System-tray account menus, silent low/recovered quota notifications, persistent alert deduplication, and notification clicks opening account details. Alerts are opt-in and obey Windows notification settings.
- Session diagnostics, executable selection and private storage checks. Closing the manager hides it. Quit from the tray closes its managed quota RPC connections while leaving external Desktop windows/legacy daemons running.
- Optional shared local ChatGPT transcript storage and allowlisted project/sidebar metadata. Select the original local `.codex` workspace in Settings, then opt in on a stopped profile. Top-level `sqlite_home` is honored; Settings also offers an explicit database-folder override and an optional original Work artifact folder. Nonempty private history is preserved and blocks conversion. The source workspace is never deleted with a profile.

### Account setup

Add a profile, choose the agent, and sign in once in that profile's window. Existing app sign-ins are never imported. For browser-mode ChatGPT quota, use **Details → Connect Codex…**, sign in inside the profile browser, and explicitly confirm the email returned by Codex. Browser and Codex sign-ins are independent.

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

Preview 4 adds a separate `Runtimes\claude\<version-key>` cache for the registered official Claude package (`Claude_pzs8sxrjxfjjc`). ChatGPT's existing cache and profiles are retained. Each Claude Desktop account has its own user-data and Code config directories; browser-mode Claude is unchanged.

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
