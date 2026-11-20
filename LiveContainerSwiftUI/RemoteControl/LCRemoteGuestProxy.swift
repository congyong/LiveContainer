//
//  LCRemoteGuestProxy.swift
//  LiveContainerSwiftUI
//
//  把 /api/v1/guest/* 代理到 guest 进程里的 sidecar（127.0.0.1:8850）。
//  sidecar 在 guest 自己的进程内，因此能真正点到 App 内部的控件、截 App 自己的画面。
//  token 通过 app group 里的文件共享（主进程写、sidecar 读）。
//

import Foundation

enum LCRemoteGuestProxy {

    static let port: UInt16 = 8850

    static var tokenFileURL: URL {
        LCPath.lcGroupDocPath
            .appendingPathComponent("RemoteControl")
            .appendingPathComponent("guest-sidecar-token")
    }

    /// 主进程启动服务时调用：把 token 写到共享文件，guest 侧的 sidecar 读它做鉴权
    static func writeTokenIfNeeded() {
        let fm = FileManager.default
        let dir = tokenFileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let token = LCRemoteConfig.token
        if let existing = try? String(contentsOf: tokenFileURL, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) == token {
            return
        }
        try? token.write(to: tokenFileURL, atomically: true, encoding: .utf8)
        // 只给本进程和同组扩展用
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
    }

    /// path 形如 /api/v1/guest/ui/tree → 转发到 http://127.0.0.1:8850/guest/ui/tree
    static func forward(_ req: LCRemoteRequest, path: String) async -> LCRemoteResponse {
        writeTokenIfNeeded()
        let suffix = String(path.dropFirst("/api/v1".count))
        guard let url = URL(string: "http://127.0.0.1:\(port)\(suffix)") else {
            return .error("bad guest path", status: 400, code: "bad_request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = req.method
        request.timeoutInterval = 60
        request.setValue("Bearer \(LCRemoteConfig.token)", forHTTPHeaderField: "Authorization")
        if let contentType = req.header("content-type") {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if req.method != "GET" && req.method != "HEAD" {
            request.httpBody = req.bodyData()
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            if ctype.contains("json") {
                if let obj = try? JSONSerialization.jsonObject(with: data) {
                    return .json(obj, status: status)
                }
                return LCRemoteResponse(status: status, headers: ["Content-Type": ctype], body: data)
            }
            return LCRemoteResponse(status: status, headers: ["Content-Type": ctype], body: data)
        } catch {
            return .error("guest sidecar 不可达（guest App 是否在运行？）: \(error.localizedDescription)",
                          status: 502, code: "guest_unreachable")
        }
    }
}
