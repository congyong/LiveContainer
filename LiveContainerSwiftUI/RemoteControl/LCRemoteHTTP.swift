//
//  LCRemoteHTTP.swift
//  LiveContainerSwiftUI
//
//  极简 HTTP/1.1 服务端（Network.framework，无第三方依赖）：
//   - 只做本项目 API 需要的子集：GET/POST/PATCH/DELETE，Content-Length body
//   - body 超过内存阈值时直接落到临时文件，避免 IPA 上传把内存打爆
//   - 一次请求一条连接（Connection: close），实现简单、行为可预测
//

import Foundation
import Network

struct LCRemoteRequest {
    var method: String = ""
    var path: String = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Data = Data()
    var bodyFile: URL?

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// 便于把 body 当文件用（multipart 解析、IPA 落盘都走这里）
    func bodyData() -> Data {
        if let bodyFile, let d = try? Data(contentsOf: bodyFile, options: .mappedIfSafe) {
            return d
        }
        return body
    }

    var bearerToken: String? {
        guard let auth = header("authorization") else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

struct LCRemoteResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200) -> LCRemoteResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"error\":\"encode failed\"}".utf8)
        var r = LCRemoteResponse(status: status, headers: [:], body: data)
        r.headers["Content-Type"] = "application/json; charset=utf-8"
        return r
    }

    static func error(_ message: String, status: Int, code: String = "error") -> LCRemoteResponse {
        .json(["error": ["code": code, "message": message]], status: status)
    }
}

final class LCRemoteHTTPServer {
    private let queue = DispatchQueue(label: "lc.remote.http", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private let handler: (LCRemoteRequest) async -> LCRemoteResponse

    private(set) var boundPort: UInt16 = 0
    var onLog: ((String) -> Void)?

    init(handler: @escaping (LCRemoteRequest) async -> LCRemoteResponse) {
        self.handler = handler
    }

    var isRunning: Bool { listener != nil }

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: LCRemoteConfig.defaultPort)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? port
                self?.onLog?("listening on :\(self?.boundPort ?? port)")
            case .failed(let err):
                self?.onLog?("listener failed: \(err.localizedDescription)")
                self?.stop()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        boundPort = port
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = 0
    }

    private func accept(_ conn: NWConnection) {
        let session = LCRemoteSession(conn: conn, queue: queue, handler: handler)
        connections.insert(ObjectIdentifier(session))
        session.onClose = { [weak self] in
            self?.connections.remove(ObjectIdentifier(session))
        }
        session.start()
    }
}

/// 一条连接 = 一条请求
private final class LCRemoteSession {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: (LCRemoteRequest) async -> LCRemoteResponse
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var head: ParsedHead?
    private var accumulated = Data()
    private var bodyFileURL: URL?
    private var bodyFileHandle: FileHandle?
    private var finished = false
    // 超过这个大小的 body 落盘（IPA 动辄上百 MB）
    private let memoryBodyLimit = 8 * 1024 * 1024

    init(conn: NWConnection, queue: DispatchQueue,
         handler: @escaping (LCRemoteRequest) async -> LCRemoteResponse) {
        self.conn = conn
        self.queue = queue
        self.handler = handler
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func close() {
        guard !finished else { return }
        finished = true
        bodyFileHandle?.closeFile()
        bodyFileHandle = nil
        conn.cancel()
        if let url = bodyFileURL {
            try? FileManager.default.removeItem(at: url)
            bodyFileURL = nil
        }
        onClose?()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.respond(.error("recv failed: \(error.localizedDescription)", status: 400))
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.pump() { return }   // 已响应或出错
            }
            if isComplete {
                if self.head == nil {
                    self.close()
                } else {
                    self.finishRequest()
                }
                return
            }
            self.receive()
        }
    }

    /// 返回 true 表示连接已处理完（响应已发出或即将发出）
    private func pump() -> Bool {
        if head == nil {
            guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
            let headData = buffer.subdata(in: buffer.startIndex..<sep.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<sep.upperBound)
            guard let parsed = ParsedHead(data: headData) else {
                respond(.error("malformed request head", status: 400))
                return true
            }
            head = parsed
            if parsed.contentLength > memoryBodyLimit {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-remote-\(UUID().uuidString).body")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let fh = try? FileHandle(forWritingTo: url) else {
                    respond(.error("cannot create temp body file", status: 500))
                    return true
                }
                bodyFileURL = url
                bodyFileHandle = fh
            }
        }
        guard let head else { return false }

        // 先把已到手的 body 字节消费掉
        if !buffer.isEmpty {
            consumeBody(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        if pendingBodyBytes == 0 {
            finishRequest()
            return true
        }
        return false
    }

    private var pendingBodyBytes: Int {
        guard let head else { return 0 }
        return max(0, head.contentLength - accumulatedCount)
    }

    private var accumulatedCount = 0

    private func consumeBody(_ data: Data) {
        guard let head else { return }
        let remain = max(0, head.contentLength - accumulatedCount)
        guard remain > 0 else { return }
        let take = min(remain, data.count)
        let chunk = data.prefix(take)
        if let fh = bodyFileHandle {
            try? fh.write(contentsOf: chunk)
        } else {
            accumulated.append(contentsOf: chunk)
        }
        accumulatedCount += take
    }

    private func finishRequest() {
        guard let head, !finished else { return }
        bodyFileHandle?.closeFile()
        bodyFileHandle = nil

        var req = LCRemoteRequest()
        req.method = head.method
        req.path = head.path
        req.query = head.query
        req.headers = head.headers
        if let url = bodyFileURL {
            req.bodyFile = url
        } else {
            req.body = accumulated
        }
        accumulated.removeAll()
        buffer.removeAll()

        Task { [weak self] in
            guard let self else { return }
            let resp = await self.handler(req)
            self.respond(resp)
        }
    }

    private func respond(_ resp: LCRemoteResponse) {
        guard !finished else { return }
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = "close"
        headers["Server"] = "LiveContainer-Remote/1"
        var head = "HTTP/1.1 \(resp.status) \(LCRemoteHTTP.reason(resp.status))\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(resp.body)

        finished = true
        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}

struct ParsedHead {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var contentLength = 0

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qIndex])
            query = ParsedHead.parseQuery(String(target[target.index(after: qIndex)...]))
        } else {
            path = target
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        contentLength = Int(headers["content-length"] ?? "0") ?? 0
    }

    static func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }
}

enum LCRemoteHTTP {
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
