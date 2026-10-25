# Roadmap

These are proposed next steps, not promised release dates or shipped features. Contributions and concrete compatibility reports can help set priorities.

## Make the first release easier to validate

- [ ] Add manual compatibility results for Apple Silicon and the oldest supported macOS version.
- [ ] Verify Desktop compatibility across ChatGPT updates and improve version diagnostics.
- [ ] Verify OAuth callbacks, deep links, notifications, and OS permissions across Desktop instances.
- [ ] Exercise Edge and Brave with the same profile lifecycle checks as Chrome.
- [ ] Document real ChatGPT sign-in, session expiry, and sign-out behavior with disposable accounts.
- [ ] Verify minimized windows, multiple windows, and multiple macOS Spaces.
- [x] Add screenshots using clearly labeled fictional profiles (1.3 preview).

## Improve everyday use

- [x] Add English/Vietnamese localization resources and persistent appearance preferences (1.3 preview).
- [ ] Review keyboard navigation, VoiceOver labels, and text scaling.
- [ ] Improve diagnostics for browser startup failures without collecting private profile contents.
- [ ] Clarify local profile/cache cleanup and recovery after interrupted operations.

## Make releases easier to trust

- [ ] Evaluate Developer ID signing and notarization when signing credentials are available.
- [ ] Automate release archives and checksums from tagged source.
- [ ] Expand CI coverage based on maintainers' available macOS runners.

The scope stays focused on local profile switching. Credential extraction, shared login sessions, and automatic rotation to evade service limits are outside that scope.
