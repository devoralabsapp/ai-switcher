# AI Switcher cho Windows — bản preview

Bản Windows dùng giao diện native .NET/WPF, có cùng bộ agent, bảy theme và không gian quản lý quota với bản macOS.

## Cài và mở

Có thể tải trực tiếp file **.exe** tại [Releases](https://github.com/devoralabsapp/ai-switcher/releases), rồi bấm mở để chạy. Không cần giải nén hay cài .NET. Chọn x64 cho Intel/AMD, ARM64 cho Windows trên ARM.

Nếu dùng gói ZIP:

1. Tải ZIP **win-x64** cho máy Intel/AMD, hoặc **win-arm64** cho Windows trên ARM, tại [Windows Builds](https://github.com/devoralabsapp/ai-switcher/actions/workflows/windows.yml).
2. Giải nén toàn bộ ZIP vào một thư mục có quyền ghi.
3. Mở **AISwitcher.exe**. Không cần cài .NET hay chạy với quyền quản trị.
4. Cài ứng dụng/trình duyệt chính thức cần dùng. Nếu app không tự tìm thấy, vào **Giao diện & Ngôn ngữ → Đường dẫn ứng dụng** để chọn file `.exe` đã cài.
5. Thêm hồ sơ và đăng nhập trực tiếp trong cửa sổ của hồ sơ đó.

Windows 11 là môi trường kiểm tra chính. Bản preview chưa ký số; file SHA-256 đi kèm để đối chiếu gói tải. Gói ARM64 đã được biên dịch nhưng chưa được chạy thử trên máy ARM64 thật.

## Những phần đã có

- Hồ sơ ChatGPT Desktop và Claude Desktop với thư mục dữ liệu riêng cho từng tài khoản; mở lại đúng cửa sổ và đóng đúng phiên.
- Chrome, Edge, Brave cho ChatGPT, Claude, Gemini, Perplexity, DeepSeek. Antigravity mở ứng dụng đã cài và dùng đăng nhập chung của ứng dụng.
- Bộ lọc agent bên trái, tìm kiếm, yêu thích, gần đây và màu riêng cho hồ sơ.
- Tiếng Việt/Anh và bảy theme: Light, Dark, Terminal, Code, Dracula, Playful Retro Neo-Brutalism, Terminal Black.
- Nút Quota-only cạnh Add account; tắt chế độ này tự về Account cards.
- Kết nối ChatGPT ở nền để xem quota mà không mở cửa sổ Desktop; khóa Connect khi phiên đang chạy; đóng/khởi động lại phiên và tùy chọn kết nối khi AI Switcher mở.
- Chi tiết quota theo từng nhóm giới hạn, thời gian reset, trạng thái dữ liệu cũ, sắp xếp và kiểm tra danh tính tài khoản.
- Menu khay hệ thống; thông báo quota thấp/hồi không âm thanh, có tùy chọn bật/tắt và ngưỡng cảnh báo.
- Chẩn đoán phiên, lựa chọn đường dẫn ứng dụng, chia sẻ workspace cục bộ theo từng hồ sơ.

Đóng cửa sổ AI Switcher sẽ ẩn về khay hệ thống. Chọn **Thoát AI Switcher** trong menu khay để thoát; các cửa sổ agent và phiên nền vẫn giữ nguyên.

## Tài khoản và workspace

ChatGPT Desktop cần bản Electron tương thích có Codex và `codex.exe` native Windows. Claude dùng cơ chế `--user-data-dir` của ứng dụng đã cài. Mỗi hồ sơ đăng nhập riêng; app không nhập mật khẩu, cookie hoặc dữ liệu xác thực từ bản macOS hay hồ sơ mặc định.

Với ChatGPT ở chế độ trình duyệt, kết nối quota là một lần đăng nhập Codex riêng: mở **Chi tiết → Kết nối Codex…**, đăng nhập trong trình duyệt của hồ sơ rồi xác nhận email trả về.

Để chia sẻ lịch sử/project cục bộ, chọn thư mục workspace `.codex` gốc trong cài đặt, sau đó bật chia sẻ ở hồ sơ ChatGPT Desktop đã dừng. App đọc `sqlite_home` nếu có; có thể chọn thư mục database và thư mục artifact Work gốc riêng. Hồ sơ đã có lịch sử riêng không bị ghi đè. Transcript và artifact gốc được giữ khi xóa hồ sơ.

Dữ liệu Windows nằm trong `%LOCALAPPDATA%\AISwitcher`; backend riêng nằm trong `%USERPROFILE%\.aisw\win-<hash>`. Không đưa các thư mục tài khoản này lên GitHub.

## Phạm vi kiểm tra

Kiểm tra tự động chạy trên Windows x64 gồm core/RPC, giao diện bảy theme với hai ngôn ngữ, chuyển cards/quota, hộp thoại, định tuyến/đóng đúng tiến trình mẫu và chia sẻ workspace. Phiên nền được thử riêng bằng Codex native Windows với tài khoản người dùng thường: kết nối, xác nhận chưa đăng nhập, khởi động lại và dừng. Bản macOS tiếp tục có bộ kiểm tra riêng.

Tích hợp Desktop vẫn là preview: đăng nhập ChatGPT/Claude thực tế, OAuth/deep link, cập nhật Store, quota của tài khoản thật, Claude Code/Cowork và hành vi giao diện Work cần kiểm tra thêm trên máy Windows có các app đó. Không dùng tài khoản thật hoặc gửi yêu cầu model trong kiểm tra tự động.

Xem [hướng dẫn build và chi tiết kỹ thuật](README.md).
