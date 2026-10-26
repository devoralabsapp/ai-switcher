import SwiftUI
import AISwitcherCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var appearanceTheme: AppTheme { model.preferences.theme }
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                settingsContent.padding(.trailing, 4).padding(.bottom, 4)
            }
            HStack {
                Text(L10n.text("Changes apply immediately and are saved for next time."))
                    .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 580, height: 720).foregroundColor(palette.ink).background(palette.surface)
        .appAppearance(model.preferences)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Appearance & Language")).font(appearanceTheme.font(size: 23, weight: .semibold))
                    Text(L10n.text("Make AI Switcher feel like yours."))
                        .font(appearanceTheme.font(size: 12)).foregroundColor(palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(ThemedPlainButtonStyle()).help(L10n.text("Close"))
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.text("Language"), systemImage: "globe").font(appearanceTheme.font(size: 13, weight: .semibold))
                Picker(L10n.text("Language"), selection: Binding(get: { model.preferences.language }, set: { model.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("languagePicker")
            }
            VStack(alignment: .leading, spacing: 9) {
                Picker(L10n.text("Workspace view"), selection: Binding(get: { model.preferences.workspaceLayout }, set: { model.setWorkspaceLayout($0) })) {
                    ForEach(WorkspaceLayout.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("workspaceLayout")
                Toggle(L10n.text("Quota-only mode"), isOn: Binding(get: { model.preferences.quotaOnlyMode }, set: { model.setQuotaOnlyMode($0) }))
                    .toggleStyle(.switch).font(appearanceTheme.font(size: 13, weight: .semibold))
                Text(L10n.text("Quota-only mode applies to ChatGPT Desktop profiles. Other agents keep their normal open action."))
                    .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
                Text(L10n.text("Choose startup connections and the default action for each account in Edit profile."))
                    .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
            }
            .padding(14).background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
            .retroOutline(radius: appearanceTheme.radius(10), shadow: false)
            QuotaNotificationSettingsView(model: model)
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.text("Theme"), systemImage: "paintpalette").font(appearanceTheme.font(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        Button { model.setTheme(theme) } label: { themeCard(theme) }
                            .buttonStyle(ThemedPlainButtonStyle()).accessibilityIdentifier("theme-\(theme.rawValue)")
                            .accessibilityLabel(theme.name + ". " + theme.detail)
                            .accessibilityAddTraits(appearanceTheme == theme ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func themeCard(_ theme: AppTheme) -> some View {
        let colors = ThemePalette(theme: theme)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(colors.accent).frame(width: 19, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(colors.secondary.opacity(0.4)).frame(width: 19, height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(colors.secondary.opacity(0.4)).frame(width: 19, height: 4)
                    Spacer(minLength: 0)
                }.padding(9).frame(width: 38).background(colors.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Text(theme.isTerminal ? "$ switch account" : "AI Switcher")
                        .font(theme.font(size: 10, weight: .semibold)).foregroundColor(colors.ink)
                    HStack(spacing: 5) {
                        ForEach(0..<2) { index in
                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(theme.isPlayfulRetro ? colors.yellow : colors.accent.opacity(0.3)).frame(width: 15, height: 10)
                                Capsule().fill(colors.secondary.opacity(0.5)).frame(height: 3)
                                Capsule().fill(colors.accent).frame(height: 3)
                            }.padding(7).background(theme.isPlayfulRetro ? (index == 0 ? colors.mint : colors.pink) : colors.surface).clipShape(RoundedRectangle(cornerRadius: theme.radius(5)))
                                .overlay(RoundedRectangle(cornerRadius: theme.radius(5)).strokeBorder(colors.ink, lineWidth: theme.isPlayfulRetro ? 1.5 : 0))
                                .background {
                                    if theme.isPlayfulRetro {
                                        RoundedRectangle(cornerRadius: theme.radius(5)).fill(colors.ink).offset(x: 2, y: 2)
                                    }
                                }
                        }
                    }
                }.padding(.trailing, 10)
            }.frame(height: 80).background(colors.canvas).accessibilityHidden(true)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.name).font(appearanceTheme.font(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(theme.detail).font(appearanceTheme.font(size: 9)).foregroundColor(palette.secondary)
                }
                Spacer()
                Image(systemName: theme == appearanceTheme ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : theme == appearanceTheme ? palette.accent : palette.secondary)
            }.padding(12)
        }
        .background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)).stroke(appearanceTheme.isPlayfulRetro ? palette.ink : theme == appearanceTheme ? palette.accent : palette.line, lineWidth: theme == appearanceTheme ? 2 : 1))
        .retroOutline(radius: appearanceTheme.radius(10), shadow: theme == appearanceTheme)
        .contentShape(Rectangle())
    }
}
