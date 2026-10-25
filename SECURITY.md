# Security policy

AI Switcher manages the paths and lifecycle of dedicated browser profiles. Those profiles can contain live login sessions even though the app does not inspect their contents.

## Reporting a vulnerability

Use **GitHub → Security → Advisories → Report a vulnerability** when private vulnerability reporting is available for this repository. If that option is unavailable, open an issue titled **Private security contact requested** with no technical details or sensitive data; a maintainer can arrange a private route.

Do not publish exploit details or upload browser profiles, cookies, tokens, passwords, account metadata, or private conversations in public issues. A useful private report describes affected versions, prerequisites, reproduction steps using disposable profiles, and the possible impact.

There is currently no guaranteed response time or funded security support. This is an early project. Security fixes will target the current source version; no older release series has a separate support commitment.

## Scope and boundaries

- The application does not collect account credentials or inspect ChatGPT conversations.
- Each profile is selected through its UUID-based directory and exact browser process arguments.
- Local filesystem permissions restrict newly created app data to the current macOS user.
- Profiles are not encrypted by AI Switcher. Other software running as the same user may access them.
- Browser and service authentication, session expiry, and server-side data are controlled by their vendors.
- The shipped build is signed ad hoc, without Developer ID signing or notarization.

See [the architecture notes](docs/ARCHITECTURE.md) for data flow and lifecycle behavior.
