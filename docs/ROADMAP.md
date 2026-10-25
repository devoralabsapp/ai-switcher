# Roadmap

These are proposed next steps, not promised release dates or shipped features. Contributions and concrete compatibility reports can help set priorities.

## Make the first release easier to validate

- [ ] Add manual compatibility results for Apple Silicon and the oldest supported macOS version.
- [ ] Exercise Edge and Brave with the same profile lifecycle checks as Chrome.
- [ ] Document real ChatGPT sign-in, session expiry, and sign-out behavior with disposable accounts.
- [ ] Verify minimized windows, multiple windows, and multiple macOS Spaces.
- [ ] Add screenshots or a short demo using clearly labeled sample profiles.

## Improve everyday use

- [ ] Add English UI localization and extract Vietnamese strings into localization resources.
- [ ] Review keyboard navigation, VoiceOver labels, and text scaling.
- [ ] Improve diagnostics for browser startup failures without collecting private profile contents.
- [ ] Clarify local profile/cache cleanup and recovery after interrupted operations.

## Make releases easier to trust

- [ ] Evaluate Developer ID signing and notarization when signing credentials are available.
- [ ] Automate release archives and checksums from tagged source.
- [ ] Expand CI coverage based on maintainers' available macOS runners.

The scope stays focused on local profile switching. Credential extraction, shared login sessions, and automatic rotation to evade service limits are outside that scope.
