//
//  LCRemoteAPI.swift
//  LiveContainerSwiftUI
//
//  路由与 handler。v1 只做读 + 装/卸 + 日志；tweak / launch 后续加。
//  约定：除 /health 外全部要 `Authorization: Bearer <token>`。
//

import Foundation

enum LCRemoteAPI {

    static func handle(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let path = req.path

        // 免鉴权：只暴露"活着"，方便探活
        if path == "/api/v1/health" && req.method == "GET" {
            return .json([
                "ok": true,
                "server": "LiveContainer-Remote/1",
                "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
                "port": Int(LCRemoteConfig.port)
            ])
        }

        guard let token = req.bearerToken, equalsConstTime(token, LCRemoteConfig.token) else {
            return .error("missing or invalid bearer token", status: 401, code: "unauthorized")
        }

        do {
            switch (req.method, path) {
            case ("GET", "/api/v1/config"):
                return .json([
                    "enabled": LCRemoteConfig.isEnabled,
                    "port": Int(LCRemoteConfig.port),
                    "apps": await MainActor.run { DataManager.shared.model.apps.count }
                ])

            case ("GET", "/api/v1/apps"):
                return try await listApps()

            case ("POST", "/api/v1/apps"):
                return try await install(req)

            case ("GET", "/api/v1/logs"):
                return await logs(req)

            case ("DELETE", let p) where p.hasPrefix("/api/v1/apps/"):
                let bundleId = String(p.dropFirst("/api/v1/apps/".count)).removingPercentEncoding ?? ""
                return try await uninstall(bundleId: bundleId, keepData: req.query["keepData"] == "1" || req.query["keepData"] == "true")

            default:
                return .error("no route for \(req.method) \(path)", status: 404, code: "not_found")
            }
        } catch {
            LCRemoteLogStore.shared.append("\(req.method) \(path) failed: \(error.localizedDescription)", src: "api")
            return .error(error.localizedDescription, status: 500, code: "internal")
        }
    }

    // MARK: - Apps 列表

    private static func listApps() async throws -> LCRemoteResponse {
        let items: [[String: Any]] = await MainActor.run {
            DataManager.shared.model.apps.map { LCAppInstaller.summary(of: $0) }
        }
        return .json(["count": items.count, "apps": items])
    }

    // MARK: - 安装

    private static func install(_ req: LCRemoteRequest) async throws -> LCRemoteResponse {
        let upload = try LCRemoteUpload.extract(req)
        defer { try? FileManager.default.removeItem(at: upload.url) }

        guard upload.filename.lowercased().hasSuffix(".ipa") else {
            return .error("只接受 .ipa（收到 \(upload.filename)）", status: 400, code: "bad_extension")
        }
        let replace = !(req.query["replace"] == "0" || req.query["replace"] == "false")
        LCRemoteLogStore.shared.append("installing \(upload.filename) (\(replace ? "replace" : "keep") )", src: "api")

        let info = try await LCAppInstaller.install(ipa: upload.url, replaceExisting: replace)
        return .json([
            "bundleId": info.bundleIdentifier() ?? "",
            "name": info.displayName() ?? "",
            "version": info.version() ?? "",
            "relativePath": info.relativeBundlePath ?? ""
        ], status: 201)
    }

    // MARK: - 卸载

    private static func uninstall(bundleId: String, keepData: Bool) async throws -> LCRemoteResponse {
        guard !bundleId.isEmpty else {
            return .error("bundleId 为空", status: 400, code: "bad_request")
        }
        let result = try await MainActor.run {
            try LCAppInstaller.uninstall(bundleId: bundleId, removeData: !keepData)
        }
        return .json(result)
    }

    // MARK: - 日志

    private static func logs(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let since = Int(req.query["since"] ?? "0") ?? 0
        let limit = min(max(Int(req.query["limit"] ?? "500") ?? 500, 1), 5000)
        let wait = min(max(Int(req.query["wait"] ?? "0") ?? 0, 0), 60)
        var (items, latest) = LCRemoteLogStore.shared.snapshot(since: since, limit: limit)
        if items.isEmpty && wait > 0 {
            let deadline = Date().addingTimeInterval(Double(wait))
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                (items, latest) = LCRemoteLogStore.shared.snapshot(since: since, limit: limit)
                if !items.isEmpty { break }
            }
        }
        return .json([
            "latest": latest,
            "count": items.count,
            "items": items.map { $0.json }
        ])
    }

    // MARK: - 工具

    private static func equalsConstTime(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

// MARK: - 上传解析（raw body 或 multipart/form-data）

enum LCRemoteUpload {
    struct Upload {
        let filename: String
        let url: URL
    }

    enum UploadError: LocalizedError {
        case emptyBody
        case badMultipart(String)
        var errorDescription: String? {
            switch self {
            case .emptyBody: return "请求体为空"
            case .badMultipart(let m): return "multipart 解析失败: \(m)"
            }
        }
    }

    private static let chunkSize = 4 * 1024 * 1024

    static func extract(_ req: LCRemoteRequest) throws -> Upload {
        let contentType = (req.header("content-type") ?? "").lowercased()
        let fallbackName = (req.query["filename"] ?? req.header("x-filename") ?? "upload.ipa")

        if contentType.hasPrefix("multipart/form-data") {
            guard let boundary = boundaryValue(from: req.header("content-type") ?? "") else {
                throw UploadError.badMultipart("没有 boundary")
            }
            let data = req.bodyData()
            guard !data.isEmpty else { throw UploadError.emptyBody }
            return try extractMultipart(data: data, boundary: boundary, fallbackName: fallbackName)
        }

        // raw body（curl -T）
        let dest = tempURL(name: fallbackName)
        try FileManager.default.createFile(atPath: dest.path, contents: nil)
        let fh = try FileHandle(forWritingTo: dest)
        defer { try? fh.close() }
        if let _ = req.bodyFile {
            try fh.write(contentsOf: req.bodyData())
        } else {
            guard !req.body.isEmpty else { throw UploadError.emptyBody }
            try fh.write(contentsOf: req.body)
        }
        return Upload(filename: sanitize(fallbackName), url: dest)
    }

    private static func extractMultipart(data: Data, boundary: String, fallbackName: String) throws -> Upload {
        let marker = Data("--\(boundary)".utf8)
        guard let firstMarker = data.range(of: marker) else {
            throw UploadError.badMultipart("找不到起始 boundary")
        }
        // 第一部分（有 name="file" 的就用它）
        var cursor = firstMarker.upperBound
        for _ in 0..<8 {
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8),
                                            in: cursor..<data.endIndex) else {
                throw UploadError.badMultipart("part 头没有结束")
            }
            let partHeaderText = String(data: data[cursor..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let contentStart = headerEnd.upperBound
            guard let nextMarker = data.range(of: Data("\r\n--\(boundary)".utf8),
                                              in: contentStart..<data.endIndex) else {
                throw UploadError.badMultipart("part 没有结束 boundary")
            }
            let contentEnd = nextMarker.lowerBound
            let lowerHeader = partHeaderText.lowercased()
            let hasFilename = lowerHeader.contains("filename=")
            if hasFilename || partHeaderText.contains("name=\"file\"") {
                let name = filenameValue(from: partHeaderText) ?? fallbackName
                let dest = tempURL(name: name)
                try FileManager.default.createFile(atPath: dest.path, contents: nil)
                let fh = try FileHandle(forWritingTo: dest)
                defer { try? fh.close() }
                var idx = contentStart
                while idx < contentEnd {
                    let end = min(idx + chunkSize, contentEnd)
                    try fh.write(contentsOf: data[idx..<end])
                    idx = end
                }
                return Upload(filename: sanitize(name), url: dest)
            }
            cursor = nextMarker.upperBound
            guard let again = data.range(of: marker, in: cursor..<data.endIndex) else {
                throw UploadError.badMultipart("没有可用的 file part")
            }
            cursor = again.upperBound
        }
        throw UploadError.badMultipart("没有可用的 file part")
    }

    private static func boundaryValue(from header: String) -> String? {
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var v = String(trimmed.dropFirst("boundary=".count))
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return v.isEmpty ? nil : v
        }
        return nil
    }

    private static func filenameValue(from partHeader: String) -> String? {
        guard let r = partHeader.range(of: "filename=\"") else { return nil }
        let rest = partHeader[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = base.unicodeScalars.map { allowed.contains($0) ? String($0) : "" }.joined()
        return cleaned.isEmpty ? "upload.ipa" : cleaned
    }

    private static func tempURL(name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-upload-\(UUID().uuidString)-\(sanitize(name))")
        return url
    }
}
