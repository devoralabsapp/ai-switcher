import AppKit
import CoreGraphics
import Darwin

@MainActor
enum ManagedApplications {
    static func windowCount(_ application: NSRunningApplication) -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 100
        }.count
    }

    static func arguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return [] }
        var cursor = MemoryLayout<Int32>.size
        while cursor < size && data[cursor] != 0 { cursor += 1 }
        while cursor < size && data[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = cursor
            while cursor < size && data[cursor] != 0 { cursor += 1 }
            guard start < size else { break }
            result.append(String(decoding: data[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return result
    }
}
