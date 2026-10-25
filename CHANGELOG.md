# Changelog

## 1.3.0 Preview 1 — 2026-10-25

- Added a complete English UI alongside Vietnamese, including native menus, errors, quota units and date/number formatting.
- Added persistent language/theme settings, available in the sidebar, menu bar and with ⌘,.
- Added Light, Dark, Terminal, Code (VS Code inspired), and Dracula themes across the dashboard, cards and sheets.
- Added monospace typography and compact corners for Terminal/Code, plus readable dark-mode account colors.
- Added offscreen previews using fictional profiles and packaging checks for both language resources.
- Expanded to 53 tests covering preferences, localization completeness/placeholders and text/button contrast.

## 1.2.0 Preview 1 — 2026-10-25

- Added experimental real ChatGPT Desktop profiles, each with separate UI data and a local Codex backend; Chrome is no longer required for daily switching.
- Reuse and focus the exact profile process; close only its applications and daemon.
- Read Desktop quota through the same backend as its window, without a second quota login.
- Retain browser mode and its separate quota cache; older profiles default to Desktop without deleting browser sessions.
- Add short, ownership-checked backend paths and staged deletion/rollback across all profile storage.
- Expand the offline suite to 46 tests and add disposable real-Desktop lifecycle checks.

Targets the new ChatGPT app with Chat, Work and Codex, not ChatGPT Classic. Internal launch settings may change with updates. Real login, live quota, Apple Silicon runtime behavior and macOS bundle-ID integrations still need manual validation.

## 1.1.0 Preview 1 — 2026-10-25

- Added optional per-profile Codex quota connections, remaining percentages, reset times, and account identity confirmation.
- Added five-minute refresh, manual refresh, stale/error indicators, and multiple-bucket details.
- Isolated Codex homes and sanitized helper environments; regular Codex sessions are not imported.
- Added quota to account cards and the menu bar, plus safe connection cancellation and local disconnect.
- Preserved old account metadata compatibility and extended staged deletion/rollback to Codex data.
- Expanded the offline suite to 32 tests and added an installed-CLI probe with no inherited account or model request.

Real OAuth sign-in and live account quota still require manual validation. A compatible installed Codex CLI is required for quota; browser switching remains independent.

## 1.0.0 Preview 1 — 2026-10-25

- Initial public preview with native macOS profile switching, a Vietnamese dashboard and menu bar, persistent browser profiles, and 13 core tests.
