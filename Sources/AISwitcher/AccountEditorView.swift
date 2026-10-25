import SwiftUI
import AISwitcherCore

struct AccountEditorView: View {
    @ObservedObject var model: AppModel
    let editor: AccountEditor
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var email: String
    @State private var browser: BrowserKind
    @State private var launchMode: LaunchMode
    @State private var color: AccountColor
    @State private var openAfterSave = true
    @FocusState private var nameFocused: Bool

    init(model: AppModel, editor: AccountEditor) {
        self.model = model
        self.editor = editor
        _name = State(initialValue: editor.account?.name ?? "")
        _email = State(initialValue: editor.account?.emailHint ?? "")
        _browser = State(initialValue: editor.account?.browser ?? editor.defaultBrowser)
        _launchMode = State(initialValue: editor.account?.effectiveLaunchMode ?? .desktop)
        _color = State(initialValue: editor.account?.color ?? editor.defaultColor)
    }

    private var isNew: Bool { editor.account == nil }
    private var modeLocked: Bool {
        editor.account.map { model.hasRunningSession($0) || model.launchingIDs.contains($0.id) || model.quotaBusyIDs.contains($0.id) || model.pendingConnections[$0.id] != nil } ?? false
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 48 && email.count <= 160
            && (launchMode == .desktop || !isNew || model.browserService.applicationURL(for: browser) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(isNew ? "Một tài khoản nữa.\nMọi thứ vẫn liền mạch." : "Chỉnh sửa hồ sơ")
                        .font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text(isNew ? "Tạo không gian riêng cho tài khoản ChatGPT của bạn." : "Tên và email chỉ là nhãn để bạn dễ nhận biết.")
                        .font(.system(size: 12)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).foregroundColor(Palette.secondary).help("Đóng")
            }

            VStack(alignment: .leading, spacing: 18) {
                field("Tên tài khoản", detail: "Ví dụ: Cá nhân, Công việc, Học tập") {
                    TextField("Đặt tên cho tài khoản", text: $name).focused($nameFocused)
                        .accessibilityIdentifier("accountName")
                }
                field("Email hoặc ghi chú", detail: "Không bắt buộc · chỉ dùng làm nhãn") {
                    TextField("ban@example.com", text: $email).accessibilityIdentifier("accountEmail")
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Màu nhận diện").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 11) {
                        ForEach(AccountColor.allCases) { item in
                            Button { color = item } label: {
                                Circle().fill(item.tint).frame(width: 27, height: 27)
                                    .overlay { if item == color { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) } }
                                    .padding(3).overlay(Circle().stroke(item == color ? item.tint.opacity(0.5) : Color.clear, lineWidth: 1))
                            }.buttonStyle(.plain).help(item.name).accessibilityLabel(item.name)
                                .accessibilityAddTraits(item == color ? .isSelected : [])
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Mở tài khoản bằng").font(.system(size: 12, weight: .medium))
                    Picker("Chế độ", selection: $launchMode) {
                        ForEach(LaunchMode.allCases) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                        .disabled(modeLocked)
                    if modeLocked {
                        Text("Đóng phiên từ menu ⋯ và chờ thao tác quota xong trước khi đổi chế độ.")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary)
                    }
                    if launchMode == .desktop {
                        Text("Mỗi tài khoản có một phiên ChatGPT Desktop và backend riêng. Đăng nhập một lần trong cửa sổ vừa mở. Cần ChatGPT mới có Chat, Work và Codex; chế độ thử nghiệm có thể bị ảnh hưởng khi ChatGPT cập nhật.")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Chế độ trình duyệt giữ phiên cũ riêng. Đóng phiên từ menu ⋯ trước khi đổi chế độ.")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary)
                    }
                }

                if launchMode == .browser {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Trình duyệt giữ phiên đăng nhập").font(.system(size: 12, weight: .medium))
                    if isNew {
                        Picker("Trình duyệt", selection: $browser) {
                            ForEach(BrowserKind.allCases) { item in
                                Text(item.name + (model.browserService.applicationURL(for: item) == nil ? " · chưa cài" : "")).tag(item)
                            }
                        }.labelsHidden().frame(maxWidth: .infinity).controlSize(.large)
                    } else {
                        Label(browser.name, systemImage: "globe").font(.system(size: 12)).foregroundColor(Palette.secondary)
                        Text("Hồ sơ luôn dùng trình duyệt ban đầu để giữ đúng phiên đăng nhập.")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary)
                    }
                    if isNew && model.browserService.applicationURL(for: browser) == nil {
                        HStack {
                            Text("Cần cài \(browser.name) trước khi thêm hồ sơ.").font(.system(size: 11)).foregroundColor(.orange)
                            Button("Tải trình duyệt") { openBrowserDownload() }.font(.system(size: 11))
                        }
                    }
                }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").foregroundColor(Palette.accent)
                Text("Bạn đăng nhập trực tiếp trong ChatGPT. AI Switcher không đọc mật khẩu, cookie hay nội dung trò chuyện. Quota được đọc qua backend Codex của phiên này.")
                    .font(.system(size: 11)).lineSpacing(4).foregroundColor(Palette.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 9))

            if isNew {
                Toggle("Mở ChatGPT để đăng nhập sau khi thêm", isOn: $openAfterSave)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }

            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { save() } label: { Text(isNew ? "Thêm tài khoản" : "Lưu thay đổi") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                    .disabled(!valid).opacity(valid ? 1 : 0.5).accessibilityIdentifier("saveAccount")
            }
        }
        .textFieldStyle(.roundedBorder).foregroundColor(Palette.ink)
        .padding(30).frame(width: 500).background(Color.white)
        .preferredColorScheme(.light)
        .onAppear { nameFocused = true }
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(detail).font(.system(size: 9)).foregroundColor(Palette.secondary)
            }
            content().font(.system(size: 13)).controlSize(.large)
        }
    }

    private func save() {
        var account = editor.account ?? Account(name: name, browser: browser, color: color)
        account.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.emailHint = email.trimmingCharacters(in: .whitespacesAndNewlines)
        account.color = color
        account.launchMode = launchMode
        guard model.saveAccount(account) else { return }
        dismiss()
        if isNew && openAfterSave { model.open(account) }
    }

    private func openBrowserDownload() {
        let address: String
        switch browser {
        case .chrome: address = "https://www.google.com/chrome/"
        case .edge: address = "https://www.microsoft.com/edge/download"
        case .brave: address = "https://brave.com/download/"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
