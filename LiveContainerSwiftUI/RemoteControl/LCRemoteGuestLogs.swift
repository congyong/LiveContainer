//
//  LCRemoteGuestLogs.swift
//  LiveContainerSwiftUI
//  Summary (EN): Captures guest app / injected tweak stdout-stderr into per-pid log files and serves them incrementally.
//
//  guest App / 注入进去的 tweak 的日志读取。
//  这些日志由 LiveProcess 侧在启动时把 stdout/stderr 重定向到
//  <appGroup>/LiveContainer/RemoteControl/guest-logs/<app>_<pid>.log（见 LiveProcess/main.m），
//  这里只负责列目录、按字节偏移增量读、清理。
//
//  注意：只覆盖 stderr/stdout（NSLog、printf、Swift print）。单独调用 os_log() 的日志
//  走统一日志系统，不在这里。
//

import Foundation

enum LCRemoteGuestLogs {

    static var logsDirectory: URL {
        LCPath.lcGroupDocPath
            .appendingPathComponent("RemoteControl")
            .appendingPathComponent("guest-logs")
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(base.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined())
    }

    private static func fileURL(_ name: String) -> URL {
        logsDirectory.appendingPathComponent(sanitize(name))
    }

    // MARK: - 列表

    static func list() -> [[String: Any]] {
        ensureDirectory()
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: logsDirectory.path)) ?? []
        var out: [[String: Any]] = []
        for name in names.sorted() {
            let url = logsDirectory.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let base = name.replacingOccurrences(of: ".log", with: "")
            let parts = base.split(separator: "_")
            let pidPart = parts.last.map(String.init) ?? ""
            out.append([
                "name": name,
                "app": parts.dropLast().joined(separator: "_"),
                "pid": Int(pidPart) ?? 0,
                "size": size,
                "mtime": mtime,
                "running": isPidAlive(Int(pidPart) ?? 0)
            ])
        }
        return out
    }

    private static func isPidAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    // MARK: - 增量读取

    /// - offset: 从该字节位置开始（0 = 从头）；返回 next 供下次 continue
    static func read(name: String, offset: Int = 0, limitBytes: Int = 64 * 1024) -> [String: Any]? {
        let url = fileURL(name)
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = UInt64(max(0, min(offset, Int(size))))
        try? fh.seek(toOffset: start)
        let data = (try? fh.read(upToCount: limitBytes)) ?? Data()
        let next = Int(start) + data.count
        return [
            "name": sanitize(name),
            "offset": Int(start),
            "next": next,
            "size": Int(size),
            "eof": next >= Int(size),
            "text": String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        ]
    }

    // MARK: - 清理

    @discardableResult
    static func clear(name: String?) -> Int {
        ensureDirectory()
        let fm = FileManager.default
        if let name {
            try? fm.removeItem(at: fileURL(name))
            return 1
        }
        let names = (try? fm.contentsOfDirectory(atPath: logsDirectory.path)) ?? []
        var removed = 0
        for n in names {
            try? fm.removeItem(at: logsDirectory.appendingPathComponent(n))
            removed += 1
        }
        return removed
    }
}
