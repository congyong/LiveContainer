//
//  LCRemoteLogStore.swift
//  LiveContainerSwiftUI
//  Summary (EN): In-process log ring buffer with sequence numbers so clients can poll incrementally.
//
//  日志捕获与环形缓冲：
//   - 把进程的 stdout / stderr 用 dup2 接到一根 pipe 上（NSLog、Swift print、guest app
//     在同进程时的输出都走这里）
//   - 按行切分后写进环形缓冲，供 HTTP API 增量拉取
//   - seq 单调递增，客户端用 ?since=<seq> 做增量
//

import Foundation
import os

struct LCRemoteLogEntry {
    let seq: Int
    let ts: TimeInterval
    let src: String
    let msg: String

    var json: [String: Any] {
        ["seq": seq, "ts": ts, "src": src, "msg": msg]
    }
}

final class LCRemoteLogStore {
    static let shared = LCRemoteLogStore()

    private let queue = DispatchQueue(label: "lc.remote.log")
    private let capacity = 5000
    private var entries: [LCRemoteLogEntry] = []
    private var nextSeq = 1
    private var installed = false
    private var readFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var pending = Data()
    private let maxPendingBytes = 32 * 1024

    private init() {}

    // MARK: - 捕获

    /// 幂等；重复调用只会装一次。
    func installCapture() {
        queue.sync {
            guard !installed else { return }
            installed = true

            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                installed = false
                return
            }
            // 不缓冲，否则 NSLog / print 的行要等缓冲区满才出来
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
            dup2(fds[1], STDOUT_FILENO)
            dup2(fds[1], STDERR_FILENO)
            close(fds[1])

            readFD = fds[0]
            let src = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
            src.setEventHandler { [weak self] in
                self?.drain()
            }
            src.setCancelHandler { [weak self] in
                guard let self, self.readFD >= 0 else { return }
                close(self.readFD)
                self.readFD = -1
            }
            source = src
            src.resume()

            appendLocked("remote control log capture installed", src: "api")
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(readFD, &buf, buf.count)
        guard n > 0 else { return }
        pending.append(contentsOf: buf[0..<n])

        while let range = pending.range(of: Data([0x0A])) {
            let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            var text = String(data: lineData, encoding: .utf8) ?? ""
            if text.hasSuffix("\r") { text.removeLast() }
            appendLocked(text, src: "log")
        }
        if pending.count > maxPendingBytes {
            let text = String(data: pending, encoding: .utf8) ?? ""
            pending.removeAll()
            appendLocked(text, src: "log")
        }
    }

    // MARK: - 写入 / 读取

    func append(_ msg: String, src: String = "api") {
        queue.sync { appendLocked(msg, src: src) }
    }

    private func appendLocked(_ msg: String, src: String) {
        for line in msg.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = LCRemoteLogEntry(seq: nextSeq, ts: Date().timeIntervalSince1970,
                                         src: src, msg: String(line))
            nextSeq += 1
            entries.append(entry)
        }
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 返回 seq > since 的记录，最多 limit 条；`latest` 是当前最大 seq。
    func snapshot(since: Int, limit: Int) -> (items: [LCRemoteLogEntry], latest: Int) {
        queue.sync {
            let filtered = entries.filter { $0.seq > since }
            let slice = filtered.suffix(max(0, limit))
            return (Array(slice), nextSeq - 1)
        }
    }

    var latestSeq: Int {
        queue.sync { nextSeq - 1 }
    }
}
