# Security policy

AI Switcher manages dedicated ChatGPT Desktop UI/backend profiles, browser profiles, and optional browser-mode Codex OAuth sessions. Both can contain live login credentials even though the app does not inspect token files or browser session contents.

## Reporting a vulnerability

Use **GitHub → Security → Advisories → Report a vulnerability** when private vulnerability reporting is available for this repository. If that option is unavailable, open an issue titled **Private security contact requested** with no technical details or sensitive data; a maintainer can arrange a private route.

Do not publish exploit details or upload browser profiles, cookies, tokens, passwords, account metadata, or private conversations in public issues. A useful private report describes affected versions, prerequisites, reproduction steps using disposable profiles, and the possible impact.

There is currently no guaranteed response time or funded security support. This is an early project. Security fixes will target the current source version; no older release series has a separate support commitment.

## Scope and boundaries

- The application does not collect account credentials or inspect ChatGPT conversations.
- Quota uses a child app-server with a UUID-specific `CODEX_HOME` and file-based credentials managed by Codex CLI. Host API keys and authentication environment overrides are not inherited.
- Desktop quota first uses the profile's local Unix WebSocket bridge. If that daemon has no session, the bundled CLI reads the persisted session from the same profile home. The returned account identity is displayed. Desktop launch settings are experimental.
- Opted-in Desktop profiles share local projects, history/transcripts and Work artifact storage on this Mac. They can access the same local work while authentication and browser storage remain separate. Cloud account data is not transferred. Deleting a shared profile retains the shared work; metadata and transcript paths are preserved before its private directories are removed.
- For browser quota, users confirm the returned Codex identity. Backend account IDs are pinned when available; mismatching accounts are refused on refresh.
- OAuth URLs require an allowed official HTTPS origin. Raw RPC errors and authentication URLs are not written to app logs.
- The client exposes only initialization and account/login/logout/quota methods; it starts no model turns and consumes no reset credits.
- Each profile is selected through its UUID-based directory and exact application process arguments.
- Local filesystem permissions restrict newly created app data to the current macOS user.
- Profiles are not encrypted by AI Switcher. Other software running as the same user may access them.
- Desktop, browser and service authentication, session expiry, and server-side data are controlled by their vendors.
- The shipped build is signed ad hoc, without Developer ID signing or notarization.

See [the architecture notes](docs/ARCHITECTURE.md) for data flow and lifecycle behavior.
