import SwiftUI

struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text("Đăng nhập một lần.\nChuyển tài khoản mỗi ngày.")
                .font(.system(size: 25, weight: .semibold)).tracking(-0.5)
            row("1", "Thêm hồ sơ cho từng tài khoản", "Đặt tên và màu để dễ phân biệt. Email trong app chỉ là nhãn, không quyết định tài khoản đăng nhập.")
            row("2", "Đăng nhập trực tiếp trên ChatGPT", "Trong cửa sổ vừa mở, đăng nhập đúng tài khoản bằng email, Google hoặc Apple như bình thường. Mỗi hồ sơ giữ một phiên trình duyệt riêng.")
            row("3", "Một cú bấm để quay lại", "Bấm Mở ChatGPT trong app hoặc chọn tài khoản từ biểu tượng AI Switcher trên thanh menu macOS. Cửa sổ đang mở sẽ được đưa lên trước.")
            VStack(alignment: .leading, spacing: 9) {
                Text("Một vài điều cần biết").font(.system(size: 12, weight: .semibold))
                Text("• App quản lý các cửa sổ ChatGPT riêng, độc lập với app ChatGPT chính thức.\n• Bấm Kết nối trong mục Quota Codex để đăng nhập một lần và xác nhận danh tính cho từng hồ sơ. Cần Codex CLI; quota tự làm mới mỗi 5 phút.\n• Đóng cửa sổ quản lý vẫn giữ biểu tượng trên thanh menu.\n• ChatGPT/Codex có thể yêu cầu đăng nhập lại khi phiên hết hạn.\n• Dữ liệu hồ sơ thuộc người dùng macOS hiện tại; đây không phải kho tài khoản được mã hóa riêng.\n• Xóa hồ sơ chỉ xóa dữ liệu trên máy này, không xóa tài khoản trên dịch vụ.")
                    .font(.system(size: 11)).lineSpacing(6).foregroundColor(Palette.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack { Spacer(); Button("Đã hiểu") { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction) }
        }
        .padding(30).frame(width: 530).background(Color.white).foregroundColor(Palette.ink).preferredColorScheme(.light)
    }

    private func row(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.accent)
                .frame(width: 30, height: 30).background(Palette.accent.opacity(0.08)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).lineSpacing(4).foregroundColor(Palette.secondary)
            }
        }
    }
}
