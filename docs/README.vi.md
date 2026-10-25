# AI Switcher cho macOS

[English README](../README.md) · [Tải bản dùng thử](https://github.com/devoralabsapp/ai-switcher/releases)

Chuyển giữa nhiều tài khoản bằng **những phiên ChatGPT Desktop riêng**, không cần Chrome để dùng hằng ngày. App SwiftUI có giao diện tiếng Việt/tiếng Anh, thanh menu và quota Codex giờ/tuần cho từng hồ sơ.

## Cách dùng

1. Cài ChatGPT Desktop mới có Chat, Work và Codex vào Applications. **ChatGPT Classic chưa được hỗ trợ.**
2. Tải ZIP từ Releases, giải nén và kéo **AI Switcher.app** vào Applications. Bản preview ký ad hoc, chưa notarize.
3. Bấm **Thêm tài khoản**, đặt tên/màu, giữ chế độ **ChatGPT Desktop**. Email chỉ là nhãn tùy chọn.
4. Đăng nhập đúng tài khoản trong cửa sổ ChatGPT vừa mở. Lần đầu có thể chờ lâu hơn để cài backend riêng; xác thực có thể mở trình duyệt mặc định một lần.
5. Lặp lại cho tài khoản khác. Sau đó bấm **Mở ChatGPT** trên thẻ hoặc chọn hồ sơ từ thanh menu để đưa đúng cửa sổ lên trước.
6. Đăng nhập xong, quota tự hiện sau vài giây từ phiên của đúng hồ sơ Desktop, không cần đăng nhập Codex lần thứ hai. Nếu daemon còn giữ trạng thái chưa đăng nhập, Codex đọc phiên đã lưu trong chính thư mục hồ sơ đó qua giao thức app-server. App tự thử lại khi đang chờ đăng nhập hoặc gặp lỗi đọc; bạn cũng có thể bấm **Làm mới quota**.

Đây là chế độ **thử nghiệm**, dựa trên cơ chế khởi động nội bộ của ChatGPT mới (`com.openai.codex`). OpenAI chưa công bố đây là giao diện chuyển nhiều tài khoản được hỗ trợ; bản cập nhật ChatGPT có thể làm cơ chế này thay đổi. App báo lỗi khi thiếu cơ chế tách phiên, không tự mở Chrome thay thế.

Hồ sơ cũ mặc định chuyển sang Desktop và cần đăng nhập mới một lần. Phiên trình duyệt và kết nối quota cũ vẫn được giữ. Muốn quay lại, chọn **⋯ → Đóng phiên tài khoản…**, sửa hồ sơ và chọn **Trình duyệt**. Không đổi chế độ khi phiên hoặc thao tác quota đang chạy.

## Ngôn ngữ và theme

Mở **Giao diện & Ngôn ngữ** ở thanh bên, menu macOS hoặc bấm **⌘,**. Chọn **Tiếng Việt / English** và theme **Sáng, Tối, Terminal, Code (lấy cảm hứng từ VS Code), Dracula**. Lựa chọn áp dụng ngay và được giữ khi mở lại app.

Terminal và Code dùng font đơn cách, góc gọn cùng bảng màu riêng. Theme áp dụng cho giao diện AI Switcher, hộp thoại và quota. Bản dịch bao gồm menu, thông báo lỗi, hạn mức, số và ngày giờ. Tài khoản và phiên đăng nhập vẫn dùng dữ liệu hiện có.

Xem [ảnh mẫu các theme](../README.md#language-and-appearance); ảnh dùng hồ sơ và quota giả để minh họa.

## Quota và đóng phiên

Thẻ hiển thị phần trăm **còn lại** và thời điểm reset của các cửa sổ do Codex trả về, thường là giờ/tuần. Bấm chi tiết để xem mọi nhóm hạn mức, email/gói và lần đọc gần nhất. Email trong mục quota do backend trả về, khác với nhãn bạn tự đặt.

Quota tự cập nhật mỗi 5 phút khi backend của hồ sơ đang chạy. Không có dữ liệu thì hiển thị chưa biết; dữ liệu cũ hoặc lỗi đọc được đánh dấu rõ. Đến giờ reset không đồng nghĩa app tự suy ra quota đã đầy. Muốn đổi tài khoản trong một phiên, đăng xuất ở chính cửa sổ ChatGPT đó.

Đóng cửa sổ quản lý vẫn giữ thanh menu; thoát AI Switcher vẫn giữ các phiên Desktop. **Đóng phiên tài khoản…** yêu cầu đóng đúng tiến trình của hồ sơ và dừng backend riêng, không ép đóng. Đăng nhập vẫn được lưu khi phiên còn hiệu lực. Cần đóng phiên và chờ thao tác quota xong trước khi xóa hồ sơ.

Ở chế độ trình duyệt, quota vẫn dùng kết nối Codex riêng: **Kết nối → Đăng nhập Codex → Dùng tài khoản này**. Hãy kiểm tra và xác nhận email. **Ngắt kết nối** chỉ áp dụng cho kết nối riêng này.

## Dữ liệu

- Nhãn, chế độ, danh tính và quota lưu tại `~/Library/Application Support/AI Switcher/accounts.json`.
- Dữ liệu cửa sổ Desktop: `Desktop/<UUID>/UserData/` trong thư mục trên.
- Backend Desktop: `~/.aisw/<profile-key>/`. Đường dẫn ngắn để phù hợp giới hạn Unix socket macOS; `backend-location.txt` ghi vị trí tương ứng và backend có marker sở hữu.
- Phiên trình duyệt cũ ở `Profiles/<UUID>/`; kết nối quota trình duyệt ở `Codex/<UUID>/`.
- AI Switcher không đọc mật khẩu, cookie, tệp token hay hội thoại; ChatGPT/Codex quản lý đăng nhập. App đọc danh tính và quota qua giao thức app-server, không tạo lượt AI hay dùng credit reset.
- Hồ sơ mới không nhập dữ liệu ChatGPT/Codex mặc định. App chỉ nhận diện, đưa lên trước hoặc đóng tiến trình có đúng đường dẫn hồ sơ.
- Thư mục mới có quyền `0700`, metadata `0600`; đây không phải kho mã hóa độc lập. Không chia sẻ các thư mục phiên hoặc tải lên GitHub.
- Xóa hồ sơ xóa dữ liệu cục bộ của nó, không xóa tài khoản/hội thoại trên dịch vụ. Các tích hợp theo bundle ID như deep link, thông báo hoặc quyền macOS có thể dùng chung giữa nhiều phiên.

Xem [kiến trúc](ARCHITECTURE.md) và [chính sách bảo mật](../SECURITY.md).

## Build và kiểm tra

Cần macOS 13+, Swift 5.9+, Xcode/Command Line Tools và Python 3 để đóng gói icon. Chế độ Desktop cần ChatGPT tương thích; trình duyệt chỉ cần nếu dùng chế độ cũ.

```sh
bash scripts/test.sh
bash scripts/build.sh --universal
bash scripts/package.sh
bash scripts/test.sh --desktop
```

53 unit/protocol test kiểm tra lưu dữ liệu, marker sở hữu, tách môi trường, định tuyến đúng tiến trình, quota và xóa/khôi phục. `--desktop` mở hai phiên ChatGPT thật dùng một lần, xác minh không thừa hưởng tài khoản, tái sử dụng cửa sổ, đóng/mở lại và dọn dữ liệu thử. Không dùng thông tin đăng nhập thật. `--browser` và `--codex` kiểm tra các chế độ tương ứng.

Đã kiểm tra cục bộ trên Intel; build universal chưa thay thế kiểm tra runtime trên Apple Silicon. Đăng nhập thật, quota thật, cửa sổ thu nhỏ và nhiều Spaces vẫn cần kiểm tra thủ công. Đây là tiện ích độc lập, không phải sản phẩm của OpenAI.
