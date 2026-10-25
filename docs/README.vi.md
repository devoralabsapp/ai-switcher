# AI Switcher for macOS

[English README](../README.md) · [Tải bản dùng thử](https://github.com/devoralabsapp/ai-switcher/releases)

App macOS bằng SwiftUI, giúp mở và chuyển giữa nhiều tài khoản ChatGPT từ một cửa sổ quản lý hoặc thanh menu. Giao diện tiếng Việt; chạy trên macOS 13 trở lên.

Mỗi tài khoản có **một thư mục dữ liệu trình duyệt riêng**. Bạn đăng nhập trên ChatGPT một lần cho từng hồ sơ; những lần sau chỉ cần bấm mở. App đưa cửa sổ đang mở của đúng hồ sơ lên trước, hoặc mở lại khi đã đóng. Chrome, Microsoft Edge và Brave được hỗ trợ.

## Sử dụng

1. Mở `dist/AI Switcher.app`. Có thể kéo app vào Applications để dùng lâu dài.
2. Bấm **Thêm tài khoản**, đặt tên và chọn trình duyệt đã cài. Email là nhãn tùy chọn, không phải thông tin đăng nhập.
3. Đăng nhập đúng tài khoản tại `chatgpt.com` trong cửa sổ mới. Lặp lại với các tài khoản khác.
4. Bấm **Mở ChatGPT** ở thẻ tương ứng để chuyển. Hoặc chọn tài khoản từ biểu tượng hai mũi tên trên thanh menu macOS.

Đóng cửa sổ quản lý vẫn giữ thanh menu hoạt động. **⌘1…⌘9** mở hồ sơ tương ứng khi AI Switcher đang được chọn; **⌘N** thêm hồ sơ, **⌘K** tìm, **⌘0** mở quản lý. Những phím này không phải phím tắt toàn hệ thống.

Menu **⋯** cho phép sửa nhãn, mở cửa sổ mới, đóng phiên trình duyệt hoặc xóa hồ sơ. Hãy đóng phiên trước khi xóa; app không ép đóng trình duyệt nếu có nội dung chưa gửi hoặc hộp thoại ngăn thoát.

## Dữ liệu và giới hạn

- App dùng cửa sổ ChatGPT của trình duyệt, **không thay đổi tài khoản trong app ChatGPT chính thức**. Đây là tiện ích độc lập, không phải sản phẩm của OpenAI.
- Không cần API key, máy chủ, extension, Accessibility hay quyền điều khiển trình duyệt bằng AppleScript.
- App không đọc mật khẩu, cookie, token hoặc nội dung trò chuyện. Trình duyệt tự quản lý phiên đăng nhập trong hồ sơ riêng.
- Nhãn lưu trong `~/Library/Application Support/AI Switcher/accounts.json`; dữ liệu trình duyệt trong `Profiles/<UUID>/` cùng thư mục. Hồ sơ Chrome cá nhân đang dùng của bạn không được nhập hay chỉnh sửa.
- Thư mục mới có quyền `0700`, tệp nhãn `0600`. Hồ sơ thuộc cùng người dùng macOS; app không bổ sung lớp mã hóa hoặc khóa bằng mật khẩu. Không chia sẻ thư mục này.
- Khi ChatGPT hết hạn phiên, thu hồi phiên, hoặc bạn đăng xuất, cần đăng nhập lại trong hồ sơ đó.
- Tên/email trên thẻ là nhãn bạn tự đặt; app không xác minh tài khoản nào đã đăng nhập. Chọn avatar trong ChatGPT để kiểm tra khi thiết lập.
- Xóa hồ sơ xóa dữ liệu trình duyệt tại chỗ. Việc này không xóa tài khoản hoặc lịch sử trên ChatGPT, và không thay cho thao tác thu hồi phiên trên dịch vụ.
- Một số chính sách trình duyệt do tổ chức quản lý có thể chặn thư mục hồ sơ tùy chỉnh.

Cơ chế hồ sơ riêng dựa trên hướng dẫn [User Data Directory của Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md).

## Build từ mã nguồn

Cần Xcode hoặc Command Line Tools có Swift 5.9 trở lên. Không có thư viện phụ thuộc từ bên ngoài.

```sh
bash scripts/build.sh
```

Build cả Intel và Apple Silicon:

```sh
bash scripts/build.sh --universal
```

App được ký ad hoc để chạy cục bộ; chưa được ký Developer ID hoặc notarize để phân phối công khai.

Đóng gói app đã build thành ZIP kèm checksum:

```sh
bash scripts/package.sh
```

## Kiểm tra

```sh
bash scripts/test.sh
bash scripts/test.sh --browser
```

Kiểm tra đầu tiên chạy các unit test về lưu/khôi phục, tách hồ sơ, định tuyến tiến trình, quyền tệp và xóa đúng dữ liệu. `--browser` cần Google Chrome, sẽ mở hai cửa sổ kiểm thử tạm để xác minh chuyển đúng tiến trình và tái sử dụng cửa sổ. Sau đó kiểm tra cookie/localStorage bằng trang HTTP loopback trong Chrome headless. Các hồ sơ tạm được dọn sau kiểm tra; không dùng tài khoản ChatGPT thật.

Có thể chạy app với nơi lưu dữ liệu thử nghiệm:

```sh
"dist/AI Switcher.app/Contents/MacOS/AISwitcher" --data-dir /tmp/ai-switcher-dev
```

## Cấu trúc

- `Sources/AISwitcherCore`: mô hình tài khoản, lưu JSON và tạo tham số hồ sơ.
- `Sources/AISwitcher`: giao diện SwiftUI, thanh menu AppKit, mở và nhận diện phiên trình duyệt bằng đối số tiến trình chính xác.
- `Tests`: unit test dữ liệu và định tuyến.
- `scripts`: build bundle, tạo icon và kiểm tra tích hợp bằng hồ sơ dùng một lần.
