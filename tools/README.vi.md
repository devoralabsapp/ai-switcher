# Gỡ liên kết account của project Local trên Windows

Tải duy nhất **Unlink-Local-Accounts.bat**, chạy bằng nhấp đúp. Không cần cài Python, SQLite CLI hoặc chạy với quyền Administrator. File dùng Windows PowerShell 5 và `winsqlite3.dll` có sẵn trên Windows 10/11.

1. Lưu công việc; dùng **Close account session…** cho mọi account, đóng ChatGPT/Codex rồi **Quit AI Switcher** từ khay hệ thống.
2. Nhấp đúp file BAT, chọn **1**. File tìm workspace mặc định, các hồ sơ AI Switcher và các vị trí source/database đã lưu. Nếu không tìm thấy, bạn có thể nhập thêm đường dẫn workspace.
3. Kiểm tra danh sách project và thư mục. Gõ **REMOVE** để gỡ liên kết của toàn bộ project Local được liệt kê. Nhấn Enter để hủy mà không thay đổi gì.
4. Chờ **DONE**, rồi mở account cần dùng và tiếp tục hội thoại cũ.

Bản sao lưu và nhật ký khôi phục nằm trong `%USERPROFILE%\AI-Switcher-Unlink-Backups\...`. Để hoàn tác, chạy lại cùng file BAT, chọn **2** và nhập thư mục sao lưu. Khôi phục chỉ metadata liên kết trong database; không thay thế database bằng bản cũ nên không xóa các chat mới thêm. Nếu file trạng thái giao diện đã thay đổi, công cụ từ chối ghi đè; giữ nguyên thư mục backup để khôi phục có kiểm tra.

Phạm vi sửa:

- Gỡ `chatGptBacking`, `chatGptBackingCreation`, `retiredChatGptBacking`, `chatGptBackingRecoveryPending` của project Local có thư mục thật trong trạng thái giao diện gốc, từng hồ sơ và các bản sidebar đã lưu.
- Gỡ ba khóa metadata `codex.chatGptBacking`, `codex.chatGptBackingCreation`, `codex.retiredChatGptBacking` của project Local trong database; gỡ `projectOrigin: chatgpt` trên quan hệ chat thuộc project đó.
- Giữ nguyên ID project/chat, thư mục, nội dung hội thoại, phiên đăng nhập và thông tin người tạo lịch sử. Không sửa `auth.json`, token, `creator_account_id`, `creator_user_id`, quota hay file transcript.
- Không sửa project cloud `g-p-*`, thư mục `.chatgpt-projects`, dữ liệu remote, hoặc kho sao lưu liên kết của Preview 16. Không quét toàn ổ đĩa, tải phần mềm, gửi dữ liệu ra mạng hay tự kill tiến trình.

Công cụ chỉ gỡ các metadata Local đã biết. Nó không chuyển quyền sở hữu project cloud hay thay đổi giới hạn/định tuyến hội thoại do dịch vụ quản lý.
