import SwiftUI
import AISwitcherCore

struct QuotaSummaryView: View {
    @ObservedObject var model: AppModel
    let account: Account

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Quota Codex", systemImage: "gauge").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if model.quotaBusyIDs.contains(account.id) {
                        ProgressView().controlSize(.mini)
                    } else if account.displayedCodexConnection != nil {
                        Button { model.refreshQuota(account) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                            .buttonStyle(.plain).help("Làm mới quota Codex")
                    }
                }
                if let connection = account.displayedCodexConnection {
                    Button { model.quotaAccountID = account.id } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(connection.identity.email ?? "Danh tính Codex đã xác nhận")
                                .font(.system(size: 9)).lineLimit(1).foregroundColor(Palette.secondary)
                            if let quota = connection.quota, let bucket = quota.limits.buckets.first {
                                if bucket.id != "codex" {
                                    Text(bucket.value.limitName ?? bucket.id).font(.system(size: 9, weight: .medium)).foregroundColor(Palette.secondary)
                                }
                                QuotaBucketView(bucket: bucket.value, now: timeline.date, compact: true,
                                                stale: quota.isStale(at: timeline.date) || model.quotaErrors[account.id] != nil)
                                Text(model.quotaErrors[account.id] != nil ? "Không làm mới được · dữ liệu lần đọc trước" : quota.isStale(at: timeline.date) ? "Dữ liệu cũ · cần làm mới" : "Đọc lúc \(quota.fetchedAt.formatted(date: .omitted, time: .shortened)) · Chi tiết ↗")
                                    .font(.system(size: 9)).foregroundColor(model.quotaErrors[account.id] != nil ? .orange : Palette.secondary)
                            } else {
                                Text(model.quotaErrors[account.id] == nil ? "Chưa có dữ liệu hạn mức · xem chi tiết" : "Chưa đọc được quota · xem chi tiết")
                                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Xem quota, thời điểm reset và tài khoản Codex đã kết nối")
                } else {
                    HStack {
                        Text(model.connectingID == account.id ? "Đang chờ đăng nhập…" : (account.effectiveLaunchMode == .desktop ? "Đăng nhập trong Desktop" : "Chưa kết nối"))
                            .font(.system(size: 10)).foregroundColor(Palette.secondary)
                        Spacer()
                        Button(model.connectingID == account.id ? "Chi tiết" : "Kết nối") { model.quotaAccountID = account.id }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.accent)
                    }
                }
            }
        }
        .padding(12).background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct QuotaBucketView: View {
    let bucket: CodexQuotaBucket
    let now: Date
    var compact = false
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 15) {
            if bucket.primary == nil && bucket.secondary == nil {
                Text("Codex chưa trả về cửa sổ hạn mức.").font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
            if let window = bucket.primary { windowView(window) }
            if let window = bucket.secondary { windowView(window) }
            if bucket.rateLimitReachedType != nil {
                Text("Codex báo đã chạm hạn mức hoặc giới hạn workspace.")
                    .font(.system(size: 10)).foregroundColor(.orange)
            }
        }
    }

    private func windowView(_ window: CodexQuotaWindow) -> some View {
        let expired = window.resetHasPassed(at: now)
        let remaining = expired ? nil : window.remainingPercent
        let color: Color = stale || expired ? Palette.secondary : (remaining ?? 100) <= 10 ? .red : (remaining ?? 100) <= 25 ? .orange : Palette.accent
        return VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack {
                Text(window.durationLabel).foregroundColor(Palette.secondary)
                Spacer()
                Text(remaining.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))% còn lại" } ?? "Chưa có dữ liệu")
                    .fontWeight(.semibold).foregroundColor(color)
            }.font(.system(size: compact ? 10 : 12))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line)
                    Capsule().fill(color).frame(width: geometry.size.width * CGFloat((remaining ?? 0) / 100))
                }
            }.frame(height: compact ? 4 : 6).accessibilityHidden(true)
            if expired {
                Text("Đã tới giờ reset · cần làm mới").font(.system(size: compact ? 9 : 11)).foregroundColor(.orange)
            } else if let date = window.resetDate {
                HStack(spacing: 3) {
                    Text("Reset")
                    Text(date, format: .dateTime.day().month().hour().minute())
                }.font(.system(size: compact ? 9 : 11)).foregroundColor(Palette.secondary)
            } else if !compact {
                Text("Codex chưa cung cấp thời điểm reset.").font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuotaDetailView: View {
    @ObservedObject var model: AppModel
    let accountID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @State private var executableRevision = 0

    private var account: Account? { model.accounts.first { $0.id == accountID } }
    private var busy: Bool { model.quotaBusyIDs.contains(accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Quota Codex").font(.system(size: 23, weight: .semibold))
                    Text(account?.name ?? "Hồ sơ").font(.system(size: 12)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Đóng")
            }.padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let pending = model.pendingConnections[accountID] {
                        confirmation(pending)
                    } else if let account, let connection = account.displayedCodexConnection {
                        connected(account, connection)
                    } else if let account {
                        onboarding(account)
                    }
                    if let error = model.quotaErrors[accountID] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Đang xử lý…").font(.system(size: 11)).foregroundColor(Palette.secondary) }
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.top, 20)
        }
        .padding(28).frame(width: 530, height: 600).background(Color.white).foregroundColor(Palette.ink)
        .preferredColorScheme(.light).environment(\.locale, Locale(identifier: "vi_VN"))
        .onDisappear { model.cancelQuotaConnection(accountID) }
        .alert("Ngắt kết nối Codex?", isPresented: $confirmDisconnect) {
            Button("Hủy", role: .cancel) { }
            Button("Ngắt kết nối", role: .destructive) { model.disconnectQuota(accountID) }
        } message: {
            Text("Phiên Codex riêng và quota đã lưu của hồ sơ này sẽ được xóa trên máy. Cửa sổ ChatGPT và tài khoản Codex bạn dùng ở app khác vẫn được giữ.")
        }
    }

    @ViewBuilder
    private func onboarding(_ account: Account) -> some View {
        if account.effectiveLaunchMode == .desktop {
            VStack(alignment: .leading, spacing: 16) {
                Text("Quota của chính phiên Desktop").font(.system(size: 15, weight: .semibold))
                Text("Mở phiên ChatGPT Desktop của hồ sơ này và đăng nhập đúng tài khoản. Quota giờ/tuần được đọc qua cùng backend, tự làm mới mỗi 5 phút khi phiên đang chạy.")
                    .font(.system(size: 12)).lineSpacing(4).foregroundColor(Palette.secondary)
                Text("Sau khi đăng nhập, bấm Làm mới. Muốn đổi tài khoản của phiên, đăng xuất bên trong cửa sổ ChatGPT đó. Email trên thẻ là danh tính do backend trả về.")
                    .font(.system(size: 11)).lineSpacing(4).foregroundColor(Palette.secondary)
                Button { model.open(account) } label: { Label("Mở ChatGPT Desktop", systemImage: "macwindow") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(model.launchingIDs.contains(accountID))
                Button("Làm mới quota") { model.refreshQuota(account) }.disabled(busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
            Text("Kết nối một lần cho hồ sơ này").font(.system(size: 15, weight: .semibold))
            Text("Đăng nhập đúng tài khoản Codex trong cửa sổ trình duyệt của hồ sơ. Sau khi xong, kiểm tra danh tính và xác nhận để gắn quota vào thẻ.")
                .font(.system(size: 12)).lineSpacing(4).foregroundColor(Palette.secondary)
            Text("Codex CLI lưu phiên OAuth trong thư mục riêng trên máy để tự làm mới quota mỗi 5 phút. Đây là kết nối riêng với phiên ChatGPT trên trình duyệt. App không đọc cookie Chrome hay dùng phiên Codex mặc định của bạn.")
                .font(.system(size: 11)).lineSpacing(4).foregroundColor(Palette.secondary)
                .padding(13).background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 9))
            if model.connectingID == accountID {
                Label("Hoàn tất đăng nhập trong cửa sổ vừa mở.", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12)).foregroundColor(Palette.accent)
                Button("Hủy đăng nhập") { model.cancelQuotaConnection(accountID) }.disabled(!busy)
            } else {
                Button { model.connectQuota(account) } label: { Label("Đăng nhập Codex", systemImage: "person.crop.circle.badge.checkmark") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(busy || model.connectingID != nil || model.quotaService.executableURL == nil)
                if model.connectingID != nil { Text("Hãy hoàn tất kết nối hồ sơ khác trước.").font(.system(size: 11)).foregroundColor(Palette.secondary) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text(model.quotaService.executableURL == nil ? "Cần cài Codex CLI để đọc quota." : "Đã tìm thấy Codex CLI trên máy.")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary).id(executableRevision)
                HStack {
                    Button("Chọn Codex CLI…") { model.quotaService.chooseExecutable(); executableRevision += 1 }.disabled(busy)
                    Link("Hướng dẫn cài", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                }.font(.system(size: 11))
            }
        }
    }
    }

    private func confirmation(_ connection: CodexConnection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Đăng nhập thành công", systemImage: "checkmark.circle.fill").foregroundColor(Palette.accent)
            identity(connection.identity)
            Text("Kiểm tra tài khoản này có đúng với hồ sơ “\(account?.name ?? "")” không. App không tự kiểm tra danh tính tài khoản đang mở trên ChatGPT.")
                .font(.system(size: 12)).lineSpacing(4).foregroundColor(Palette.secondary)
            Text("Sau khi xác nhận, app mở một cửa sổ ChatGPT trong hồ sơ này để bạn kiểm tra tài khoản.")
                .font(.system(size: 11)).foregroundColor(Palette.secondary)
            Button("Dùng tài khoản này") { if model.confirmQuotaConnection(accountID) { dismiss() } }
                .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(busy)
            Button("Hủy, chọn tài khoản khác") { model.cancelQuotaConnection(accountID) }.disabled(busy)
        }
    }

    private func connected(_ account: Account, _ connection: CodexConnection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            identity(connection.identity)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                VStack(alignment: .leading, spacing: 20) {
                    if let quota = connection.quota {
                        ForEach(quota.limits.buckets, id: \.id) { bucket in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(bucket.value.limitName ?? (bucket.id == "codex" ? "Codex" : bucket.id))
                                    .font(.system(size: 13, weight: .semibold))
                                QuotaBucketView(bucket: bucket.value, now: timeline.date,
                                                stale: quota.isStale(at: timeline.date) || model.quotaErrors[accountID] != nil)
                            }.padding(15).background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if quota.limits.buckets.isEmpty { Text("Codex chưa trả về hạn mức cho tài khoản này.").font(.system(size: 12)) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Đọc lần cuối: \(quota.fetchedAt.formatted(date: .abbreviated, time: .standard))")
                            if quota.isStale(at: timeline.date) || model.quotaErrors[accountID] != nil {
                                Text("Dữ liệu lần đọc trước; hãy làm mới để biết quota hiện tại.").foregroundColor(.orange)
                            }
                        }.font(.system(size: 10)).foregroundColor(Palette.secondary)
                    } else { Text("Chưa đọc được dữ liệu quota. Bấm Làm mới để thử lại.").font(.system(size: 12)) }
                }
            }
            HStack {
                Button { model.refreshQuota(account) } label: { Label("Làm mới", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(busy)
                Spacer()
                if account.effectiveLaunchMode == .browser {
                    Button("Ngắt kết nối…") { confirmDisconnect = true }.disabled(busy)
                }
            }
            Text("Phần trăm là hạn mức còn lại do Codex trả về. Cửa sổ không có dữ liệu không được coi là không giới hạn. App không thực hiện tác vụ AI khi đọc quota.")
                .font(.system(size: 10)).lineSpacing(4).foregroundColor(Palette.secondary)
        }
    }

    private func identity(_ identity: CodexIdentity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(identity.email ?? "Tài khoản Codex đã xác nhận").font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
            Text("Gói: \(identity.planType ?? "Chưa có dữ liệu")").font(.system(size: 11)).foregroundColor(Palette.secondary)
        }
    }
}
