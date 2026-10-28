import SwiftUI
import AISwitcherCore

struct GuideView: View {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { guideContent.padding(30) }
            HStack { Spacer(); Button(L10n.text("Got it")) { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .frame(width: 530, height: 740).background(appearanceTheme.isPlayfulRetro ? palette.canvas : palette.surface).foregroundColor(palette.ink)
    }

    private var guideContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text(L10n.text("Your AI accounts.\nOne workspace."))
                .font(appearanceTheme.font(size: 25, weight: .semibold)).tracking(-0.5)
            row("1", L10n.text("Choose an AI agent"), L10n.text("Choose an agent when adding a profile. Claude, Gemini, Perplexity, and DeepSeek use separate browser profiles; sign in directly on their websites."))
            row("2", L10n.text("Check agent capabilities"), L10n.text("ChatGPT reads Codex quota from its Desktop session. Claude reads subscription limits through a separate Claude Code sign-in per profile. Antigravity reads quota through its official CLI with shared application sign-in. Connect reads quota without opening Desktop or sending a model prompt."))
            row("3", L10n.text("Filter and return"), L10n.text("Use the AI AGENTS section in the left sidebar. Agent filters combine with Favorites, Recent, and search. Open a profile from its card or the menu bar."))
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("ChatGPT Desktop notes")).font(appearanceTheme.font(size: 12, weight: .semibold))
                Text(L10n.text("• Desktop mode opens the official ChatGPT app with separate data and a backend. Requires the new ChatGPT with Chat, Work, and Codex; ChatGPT Classic is not supported.\n• This experimental feature uses internal ChatGPT mechanisms and may need compatibility updates.\n• After signing in, quota appears automatically from the same Desktop session and refreshes every 5 minutes while it is running. No separate Codex sign-in is needed.\n• Existing profiles need one new Desktop sign-in; their previous browser data is kept.\n• Closing the manager keeps the menu bar available.\n• ChatGPT/Codex may ask you to sign in again when sessions expire.\n• Profile data belongs to the current macOS user; it is not a separately encrypted vault.\n• Deleting a profile removes local data only, not the service account."))
                    .font(appearanceTheme.font(size: 11)).lineSpacing(6).foregroundColor(palette.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(appearanceTheme.isPlayfulRetro ? palette.mint : palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
                .retroOutline(radius: appearanceTheme.radius(10))
        }
    }

    private func row(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(appearanceTheme.font(size: 13, weight: .semibold)).foregroundColor(palette.accent)
                .frame(width: 30, height: 30).background(appearanceTheme.isPlayfulRetro ? palette.yellow : palette.accent.opacity(0.08)).clipShape(Circle())
                .retroOutline(radius: 100)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(appearanceTheme.font(size: 13, weight: .semibold))
                Text(detail).font(appearanceTheme.font(size: 12)).lineSpacing(4).foregroundColor(palette.secondary)
            }
        }
    }
}
