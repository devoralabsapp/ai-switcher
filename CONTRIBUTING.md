# Contributing to AI Switcher

Thanks for helping improve a small, native macOS utility. The interface supports Vietnamese and English; issues and pull requests are welcome in English or Vietnamese.

## Set up

Use macOS 13+ with Swift 5.9+ and Xcode or Command Line Tools. Install the new ChatGPT app for `--desktop` checks. Install Chrome if you intend to run browser integration checks. No third-party Swift dependencies or API credentials are required.

```sh
bash scripts/test.sh
bash scripts/build.sh
"dist/AI Switcher.app/Contents/MacOS/AISwitcher" --data-dir /tmp/ai-switcher-dev
```

Keep development profiles separate from accounts you use every day. Use a disposable ChatGPT account only when a change requires manually checking real sign-in. The automated fixtures do not require any ChatGPT account.

## Report a bug

Include macOS version, CPU architecture, ChatGPT or browser name/version, the action that triggered the problem, and the expected and actual behavior. List reproduction steps and whether the issue occurs with a fresh profile.

Redact account names and email labels from screenshots. Never attach `accounts.json`, Desktop/backend/browser profile directories, cookies, tokens, credentials, or conversation content. Use the private reporting route in [SECURITY.md](SECURITY.md) for vulnerabilities.

## Propose a change

For a substantial feature, open an issue to discuss the behavior first. Small fixes can arrive as a pull request directly. Keep each PR focused on one problem and include:

- The concrete behavior before and after the change.
- Relevant tests or a manual verification description.
- The browser and macOS versions tested, and remaining coverage gaps.

Run `bash scripts/test.sh` and `bash scripts/build.sh` before submitting app changes. Changes to profile paths, process matching, session closing, or deletion should also run `bash scripts/test.sh --desktop` locally, and `--browser` when changing browser behavior. These checks open temporary windows and require a graphical login session.

For release-related changes, run `bash scripts/build.sh --universal`. CI tests the core and builds both architectures; it does not claim to validate interactive sign-in.

## Design expectations

Quota changes must preserve profile isolation and keep unavailable data distinct from zero usage. Run the protocol fixture tests with `bash scripts/test.sh`. Optionally use `bash scripts/test.sh --codex` to probe an installed CLI with a disposable, unauthenticated home; never import real credentials into test fixtures.

- Keep authentication inside ChatGPT Desktop or the selected real browser. Do not collect or copy passwords, cookies, or tokens.
- Match a dedicated profile exactly before focusing or terminating its process.
- Preserve existing metadata when reading or saving fails.
- Do not force-quit sessions or silently delete profile data.
- Keep errors visible when an operation starts from the menu bar.
- Respect normal ChatGPT account access, session expiry, and service limits.
- Avoid new dependencies unless they solve a documented need.

AI-assisted contributions are welcome. Explain the resulting behavior and verification just as you would for any other contribution; generated output is not a substitute for checking a change.

By submitting a contribution, you agree to license that contribution under the repository's MIT License. No separate contributor agreement is required.

## Language and themes

Update both `Sources/AISwitcherCore/Resources/en.lproj/Localizable.strings` and `vi.lproj/Localizable.strings` when adding user-facing text. Use `L10n.text` or `L10n.format`; preserve the same placeholders in both languages. Never translate user-entered account labels. Locale and theme choices belong to AI Switcher preferences, separately from session data.

Use the inherited `appTheme` environment, palette and font helpers for new views. Keep text readable on all surfaces; the unit suite checks palette contrast. Generate offscreen previews with fictional data for visual checks, without opening or capturing real profiles:

```sh
preview_root="$(mktemp -d /tmp/ai-switcher-preview.XXXXXX)"
.build/debug/AISwitcher --data-dir "$preview_root" --render-previews dist/previews -ui.language en
rm -rf "$preview_root"
```

The language flag uses the process's argument domain without saving a new user preference. Run with `vi` for Vietnamese previews. Package using the provided scripts so localization resources are included and verified before release.
