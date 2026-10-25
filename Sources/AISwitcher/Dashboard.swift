import SwiftUI
import AISwitcherCore

struct Dashboard: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Palette.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 27) {
                        hero
                        if model.loadFailed { recoveryBanner }
                        accountSection
                        if model.accounts.isEmpty { setupSteps }
                    }
                    .padding(32)
                }
                footer
            }
            .background(Palette.canvas)
        }
        .foregroundColor(Palette.ink)
        .background(Color.white)
        .frame(minWidth: 900, minHeight: 640)
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "vi_VN"))
        .sheet(item: $model.editor) { editor in AccountEditorView(model: model, editor: editor) }
        .sheet(isPresented: $model.showGuide) { GuideView() }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("Đã hiểu")))
        }
        .alert("Xóa hồ sơ trên máy này?", isPresented: Binding(
            get: { model.accountToDelete != nil },
            set: { if !$0 { model.accountToDelete = nil } }
        ), presenting: model.accountToDelete) { account in
            Button("Hủy", role: .cancel) { model.accountToDelete = nil }
            Button("Xóa hồ sơ", role: .destructive) { model.delete(account); model.accountToDelete = nil }
        } message: { account in
            Text("Hồ sơ “\(account.name)” và phiên đăng nhập cục bộ sẽ bị xóa. Tài khoản ChatGPT và lịch sử trên ChatGPT vẫn được giữ.")
        }
        .alert("Đóng phiên trình duyệt?", isPresented: Binding(
            get: { model.accountToClose != nil },
            set: { if !$0 { model.accountToClose = nil } }
        ), presenting: model.accountToClose) { account in
            Button("Hủy", role: .cancel) { model.accountToClose = nil }
            Button("Đóng phiên") { model.closeSession(account); model.accountToClose = nil }
        } message: { account in
            Text("Các cửa sổ thuộc hồ sơ “\(account.name)” sẽ đóng. Hãy gửi hoặc sao chép nội dung đang soạn trước. Phiên đăng nhập vẫn được lưu để mở lại.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAccountSearch)) { _ in searchFocused = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 35, height: 35)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Switcher").font(.system(size: 16, weight: .bold))
                    Text("Một chạm, đổi tài khoản").font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 38)

            Text("KHÔNG GIAN CỦA BẠN")
                .font(.system(size: 9, weight: .semibold)).tracking(1.4)
                .foregroundColor(Palette.secondary).padding(.bottom, 12).padding(.leading, 10)
            ForEach(AccountFilter.allCases, id: \.self) { filter in
                Button {
                    model.filter = filter
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: filter.symbol).font(.system(size: 14)).frame(width: 18)
                        Text(filter.rawValue).font(.system(size: 12, weight: model.filter == filter ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if filter == .all {
                            Text("\(model.accounts.count)").font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(model.filter == filter ? Color.white.opacity(0.85) : Palette.canvas)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .foregroundColor(model.filter == filter ? Palette.accent : Palette.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 12)
                    .background(model.filter == filter ? Palette.accent.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            if let account = model.lastOpened {
                VStack(alignment: .leading, spacing: 13) {
                    Text("MỞ LẠI GẦN NHẤT").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundColor(Palette.secondary)
                    Button { model.open(account) } label: {
                        HStack(spacing: 10) {
                            AccountAvatar(account: account, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("Mở ChatGPT ↗").font(.system(size: 10)).foregroundColor(Palette.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.top, 30)
            }

            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 20) {
                Button { model.showGuide = true } label: {
                    Label("Cách hoạt động", systemImage: "questionmark.circle").font(.system(size: 12))
                }.buttonStyle(.plain)
                Button { model.revealData() } label: {
                    Label("Dữ liệu trên máy", systemImage: "externaldrive").font(.system(size: 12))
                }.buttonStyle(.plain)
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 13)).foregroundColor(Palette.accent)
                    Text("Phiên đăng nhập được lưu\ntrong hồ sơ trình duyệt riêng.")
                        .font(.system(size: 10)).lineSpacing(4).foregroundColor(Palette.secondary)
                }
            }
            .foregroundColor(Palette.secondary)
            .padding(.horizontal, 10).padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Text("Không gian làm việc").foregroundColor(Palette.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(Palette.secondary.opacity(0.6))
                Text("ChatGPT").fontWeight(.medium)
            }.font(.system(size: 11))
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.secondary)
                TextField("Tìm tài khoản", text: $model.search)
                    .textFieldStyle(.plain).focused($searchFocused).font(.system(size: 11))
                    .accessibilityIdentifier("accountSearch")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(Palette.secondary).help("Xóa tìm kiếm")
                } else { Text("⌘ K").font(.system(size: 10)).foregroundColor(Palette.secondary) }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(width: 212).background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
        }
        .padding(.horizontal, 30).frame(height: 66)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 5, height: 5)
                    Text("ÍT THAO TÁC HƠN. LIỀN MẠCH HƠN.")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                }.foregroundColor(Palette.accent)
                Text("Nhiều tài khoản.\nMột cú bấm.")
                    .font(.system(size: 32, weight: .semibold)).tracking(-1.2).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Đăng nhập mỗi tài khoản một lần.\nChuyển qua lại, giữ nguyên mạch trò chuyện.")
                    .font(.system(size: 12)).lineSpacing(5).foregroundColor(Palette.secondary)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(Palette.accent.opacity(0.08), lineWidth: 1).frame(width: 154, height: 154)
                Circle().stroke(Palette.accent.opacity(0.05), lineWidth: 1).frame(width: 188, height: 188)
                RoundedRectangle(cornerRadius: 16).fill(Color.white).frame(width: 63, height: 63)
                    .rotationEffect(.degrees(-13)).offset(x: -37, y: -26)
                    .shadow(color: Palette.ink.opacity(0.04), radius: 10, y: 5)
                Image(systemName: "person.fill").font(.system(size: 23)).foregroundColor(AccountColor.violet.tint)
                    .offset(x: -37, y: -26)
                RoundedRectangle(cornerRadius: 16).fill(Palette.accent).frame(width: 63, height: 63)
                    .rotationEffect(.degrees(10)).offset(x: 30, y: 23)
                    .shadow(color: Palette.accent.opacity(0.15), radius: 10, y: 5)
                Image(systemName: "person.fill").font(.system(size: 23)).foregroundColor(.white).offset(x: 30, y: 23)
                Image(systemName: "arrow.triangle.swap").font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Palette.accent).offset(x: 33, y: -38)
            }
            .frame(width: 190, height: 180).accessibilityHidden(true)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(model.filter.rawValue).font(.system(size: 17, weight: .semibold))
                        Text("\(model.visibleAccounts.count)")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.line.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    Text("Mỗi tài khoản, một phiên đăng nhập riêng.")
                        .font(.system(size: 11)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button { model.addAccount() } label: { Label("Thêm tài khoản", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(model.loadFailed)
                    .accessibilityIdentifier("addAccount")
            }
            if model.visibleAccounts.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 16)], spacing: 16) {
                    ForEach(model.visibleAccounts) { account in AccountCard(model: model, account: account) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: model.accounts.isEmpty ? "person.badge.plus" : "magnifyingglass")
                .font(.system(size: 25, weight: .light)).foregroundColor(Palette.accent)
                .frame(width: 58, height: 58).background(Palette.accent.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Text(model.accounts.isEmpty ? "Thêm tài khoản đầu tiên" : "Chưa có tài khoản phù hợp")
                .font(.system(size: 15, weight: .semibold))
            Text(model.accounts.isEmpty ? "Cá nhân, công việc hay học tập — đặt tên để dễ nhận ra." : "Thử tìm tên khác hoặc xem tất cả tài khoản.")
                .font(.system(size: 11)).foregroundColor(Palette.secondary).multilineTextAlignment(.center)
            if model.accounts.isEmpty {
                Button { model.addAccount() } label: { Label("Bắt đầu thiết lập", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).padding(.top, 3).disabled(model.loadFailed)
            } else {
                Button("Xem tất cả") { model.search = ""; model.filter = .all }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 29).padding(.horizontal, 16)
        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var setupSteps: some View {
        HStack(spacing: 0) {
            step("1", "Thêm hồ sơ", "Đặt tên dễ nhận biết")
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Palette.line)
            Spacer()
            step("2", "Đăng nhập một lần", "Trực tiếp trên ChatGPT")
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Palette.line)
            Spacer()
            step("3", "Bấm để chuyển", "Từ app hoặc thanh menu")
        }.padding(.horizontal, 6)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.accent)
                .frame(width: 24, height: 24).background(Palette.accent.opacity(0.07)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium))
                Text(detail).font(.system(size: 9)).foregroundColor(Palette.secondary)
            }
        }
    }

    private var recoveryBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            Text("Chưa đọc được dữ liệu. Tệp hiện tại được giữ nguyên.").font(.system(size: 11))
            Spacer()
            Button("Thử lại") { model.reload() }
            Button("Mở thư mục") { model.revealData() }
        }.padding(13).background(Color.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.accent).frame(width: 4, height: 4)
            Text(model.lastAction ?? "Sẵn sàng khi bạn cần").lineLimit(1)
            Spacer()
            Text("AI Switcher 1.0").foregroundColor(Palette.secondary.opacity(0.7))
        }
        .font(.system(size: 10)).foregroundColor(Palette.secondary)
        .padding(.horizontal, 31).frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

private struct AccountCard: View {
    @ObservedObject var model: AppModel
    let account: Account
    @State private var hovering = false

    private var busy: Bool { model.launchingIDs.contains(account.id) }
    private var running: Bool { model.runningIDs.contains(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Button { model.open(account) } label: { AccountAvatar(account: account) }
                    .buttonStyle(.plain).help("Mở \(account.name)").disabled(busy)
                Spacer()
                Button { model.toggleFavorite(account) } label: {
                    Image(systemName: account.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12)).foregroundColor(account.isFavorite ? AccountColor.gold.tint : Palette.secondary.opacity(0.6))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(account.isFavorite ? "Bỏ yêu thích" : "Thêm vào yêu thích")
                Menu {
                    Button("Chỉnh sửa hồ sơ…") { model.editor = AccountEditor(account: account) }
                    Button("Mở cửa sổ ChatGPT mới") { model.open(account, newWindow: true) }
                    Divider()
                    Button("Đóng phiên trình duyệt…") { model.accountToClose = account }.disabled(!running)
                    Button("Xóa hồ sơ trên máy…", role: .destructive) { model.accountToDelete = account }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 18, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().help("Tùy chọn hồ sơ").disabled(busy)
            }

            Button { model.open(account) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.name).font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.ink).lineLimit(1)
                    Text(account.emailHint.isEmpty ? "Hồ sơ ChatGPT riêng" : account.emailHint)
                        .font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(busy)

            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 10))
                Text(account.browser == .chrome ? "Chrome" : account.browser == .edge ? "Edge" : "Brave")
                Spacer()
                Circle().fill(running ? Palette.accent : Palette.secondary.opacity(0.35)).frame(width: 4, height: 4)
                Text(running ? "Đang mở" : account.lastOpenedAt == nil ? "Chưa mở" : "Đã lưu hồ sơ")
            }.font(.system(size: 10)).foregroundColor(Palette.secondary)

            Button { model.open(account) } label: {
                HStack(spacing: 7) {
                    if busy { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                    Text(busy ? "Đang mở…" : "Mở ChatGPT")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold)).foregroundColor(account.color.tint)
                .padding(.horizontal, 12).frame(height: 35)
                .background(account.color.pale).clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(busy)
                .accessibilityLabel("Mở ChatGPT bằng hồ sơ \(account.name)")
        }
        .padding(20).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(hovering ? account.color.tint.opacity(0.4) : Palette.line))
        .shadow(color: Palette.ink.opacity(hovering ? 0.045 : 0), radius: 10, y: 4)
        .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    static let focusAccountSearch = Notification.Name("AISwitcher.focusAccountSearch")
}
