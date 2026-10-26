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
- [x] Add session diagnostics, Desktop compatibility checks, and targeted background recovery without collecting private profile contents.
- [ ] Clarify local profile/cache cleanup and recovery after interrupted operations.

## Quota workspace

- [x] Add opt-in quota-only mode and per-profile default actions.
- [x] Connect selected Desktop sessions in the background at startup.
- [x] Distinguish background backends, Desktop windows, disconnected sessions, and sign-in needs.
- [x] Add a sortable quota overview with freshness and reset information.

- [x] Add per-account menu-bar quota summaries and quick actions.
- [x] Add opt-in low/recovered quota notifications with persistent transition deduplication.

## Multiple AI agents

- [x] Add Claude, Gemini, Perplexity, and DeepSeek with separate browser profiles.
- [x] Add separate Claude Desktop profiles with exact process routing and isolated storage.
- [x] Add Terminal Black as an additional theme.
- [ ] Verify two real Claude account sign-ins, OAuth callbacks, Claude Code, and Cowork across isolated windows.
- [x] Add an Antigravity launcher with explicit shared application sign-in semantics.
- [x] Add persistent sidebar agent filters combined with search and workspace filters.
- [ ] Evaluate documented per-agent quota APIs and independent native session support before expanding capabilities.

## Make releases easier to trust

- [ ] Evaluate Developer ID signing and notarization when signing credentials are available.
- [ ] Automate release archives and checksums from tagged source.
- [ ] Expand CI coverage based on maintainers' available macOS runners.

The scope stays focused on local profile switching. Credential extraction, sharing credentials between profiles, and automatic rotation to evade service limits are outside that scope.
