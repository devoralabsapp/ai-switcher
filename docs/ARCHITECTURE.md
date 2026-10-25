# Architecture

AI Switcher is a native macOS executable with a small, independently testable core. It has no server component or third-party Swift package dependency.

## Data flow

```mermaid
flowchart LR
    UI[Dashboard or menu bar] --> Model[AppModel]
    Model --> Metadata[ProfileRepository: labels and UUIDs]
    Model --> Browser[BrowserService]
    Browser --> A[Browser process with profile A]
    Browser --> B[Browser process with profile B]
    A --> ChatGPT[chatgpt.com]
    B --> ChatGPT
```

Browser authentication happens directly with the service. Optional Codex authentication is owned by a separate CLI home per profile. The app receives authorization URLs, completion status, identity, and quota responses, but does not read token files.

## Core

`AISwitcherCore` defines accounts, colors, supported browser identifiers, snapshot validation, and browser launch arguments. An account's UUID is its stable storage identity. Labels are editable; renaming an account cannot select a different directory.

`ProfileRepository` reads and atomically writes versioned JSON metadata. It rejects corrupt data, duplicate IDs, unsupported versions, and invalid selections. A failed load is surfaced instead of replacing the file with an empty list.

Each account's browser data directory is derived from its UUID. For deletion, the repository stages the directory, saves updated metadata, then removes the staged data. If saving metadata fails, it attempts to restore the directory. A cleanup failure is surfaced; the caller reloads saved metadata so the interface reflects the durable result.

## Native application

`AppModel` coordinates editing, filtering, opening, closing, and deletion. `AppDelegate` owns the AppKit window and menu bar; the dashboard and dialogs use SwiftUI.

`BrowserService` locates an installed browser by bundle identifier. It starts the browser executable with a dedicated `--user-data-dir` and ChatGPT in app-window mode. Arguments are passed directly to `Process`, without a shell.

To reuse a session, the service enumerates running applications with the matching browser bundle ID, reads their process argument vectors, and matches the complete profile argument. Helpers with a `--type=` argument do not qualify as the main browser process. CoreGraphics supplies window metadata to decide whether there is a window to activate; the app does not capture screen pixels.

Closing a session requests termination only of the matched dedicated browser process and waits for it to exit. It does not force-kill a process. Deletion is refused while the matching profile is running.

## Codex quota

`CodexRPCClient` is an actor using JSONL over a child process's stdio. It initializes first, exposes only account operations, and handles fragmented messages, early login events, cancellation, deadlines, and EOF. Raw error messages are replaced with fixed user-facing text. No model threads or reset-credit operations are exposed.

`CodexQuotaService` uses `Codex/<UUID>` for the child's `CODEX_HOME`, sanitizes inherited environment variables, and leaves regular Codex sessions untouched. Login opens a validated official HTTPS URL in the profile's browser. Users confirm identity before saving. Backend account IDs are checked on later reads when available, with email fallback for older responses. Helpers stop after each operation; abandoned logins are cleaned up.

Polling runs sequentially every five minutes. Multiple quota buckets stay separate, and nonempty multi-bucket responses take precedence over the legacy view. Remaining percentages are `100 - usedPercent`, clamped to 0–100. Missing windows stay unknown and reset expiry does not imply a refill. Snapshots retain the read timestamp; stale/error states remain visible. Browser and Codex directories share staged deletion/rollback.

Protocol reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server).

## Tests and limits

The core unit suite verifies persistence, validation, storage separation, exact argument matching, permissions, targeted deletion, and deletion rollback.

Local GUI smoke checks create two throwaway profiles, verify distinct browser processes, switch back to a process without creating another window, then terminate only those test sessions. A separate headless loopback fixture verifies isolated and persistent cookies and localStorage.

CI runs unit tests and a universal app build. Manual ChatGPT authentication, minimized-window behavior across macOS versions, and vendor-managed browser policies need further field testing. The current interface supports Vietnamese; internationalization is planned.
