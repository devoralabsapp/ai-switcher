import SwiftUI
import AISwitcherCore

struct GuideView: View {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text(L10n.text("Sign in once.\nSwitch accounts every day."))
                .font(appearanceTheme.font(size: 25, weight: .semibold)).tracking(-0.5)
            row("1", L10n.text("Add a profile for each account"), L10n.text("Choose a name and color to tell accounts apart. The email in AI Switcher is a label; it does not select the signed-in account."))
            row("2", L10n.text("Sign in directly in ChatGPT"), L10n.text("Sign in to the intended account in the new window using email, Google, or Apple as usual. Each profile keeps a separate ChatGPT Desktop session. Authentication may open the system browser the first time."))
            row("3", L10n.text("One click to return"), L10n.text("Choose Open ChatGPT in the app or pick an account from the AI Switcher menu bar icon. Its existing window comes to the front."))
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("A few things to know")).font(appearanceTheme.font(size: 12, weight: .semibold))
                Text(L10n.text("• Desktop mode opens the official ChatGPT app with separate data and a backend. Requires the new ChatGPT with Chat, Work, and Codex; ChatGPT Classic is not supported.\n• This experimental feature uses internal ChatGPT mechanisms and may need compatibility updates.\n• After signing in, choose Refresh quota. Quota comes from the same Desktop session and refreshes every 5 minutes while it is running.\n• Existing profiles need one new Desktop sign-in; their previous browser data is kept.\n• Closing the manager keeps the menu bar available.\n• ChatGPT/Codex may ask you to sign in again when sessions expire.\n• Profile data belongs to the current macOS user; it is not a separately encrypted vault.\n• Deleting a profile removes local data only, not the service account."))
                    .font(appearanceTheme.font(size: 11)).lineSpacing(6).foregroundColor(palette.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
            HStack { Spacer(); Button(L10n.text("Got it")) { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction) }
        }
        .padding(30).frame(width: 530).background(palette.surface).foregroundColor(palette.ink)
    }

    private func row(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(appearanceTheme.font(size: 13, weight: .semibold)).foregroundColor(palette.accent)
                .frame(width: 30, height: 30).background(palette.accent.opacity(0.08)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(appearanceTheme.font(size: 13, weight: .semibold))
                Text(detail).font(appearanceTheme.font(size: 12)).lineSpacing(4).foregroundColor(palette.secondary)
            }
        }
    }
}
