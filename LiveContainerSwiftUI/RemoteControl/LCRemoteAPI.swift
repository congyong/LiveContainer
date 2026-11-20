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
            case (_, let p) where p.hasPrefix("/api/v1/guest/"):
                return await LCRemoteGuestProxy.forward(req, path: p)

            case ("GET", "/api/v1/self"):
                return await selfInfo()

            case ("GET", "/api/v1/config"):
                let keepAlive = await MainActor.run { LCRemoteKeepAlive.shared.status }
                return .json([
                    "enabled": LCRemoteConfig.isEnabled,
                    "port": Int(LCRemoteConfig.port),
                    "keepAlive": keepAlive,
                    "apps": await MainActor.run { DataManager.shared.model.apps.count }
                ])

            case ("POST", "/api/v1/keepalive"):
                return await keepAlive(req)

            case ("GET", "/api/v1/apps"):
                return try await listApps()

            case ("POST", "/api/v1/apps"):
                return try await install(req)

            case ("GET", "/api/v1/logs"):
                return await logs(req)

            case ("GET", "/api/v1/logs/guest"):
                return guestLogs(req)

            case ("DELETE", "/api/v1/logs/guest"):
                let removed = LCRemoteGuestLogs.clear(name: req.query["name"])
                return .json(["removed": removed])

            case ("DELETE", let p) where p.hasPrefix("/api/v1/apps/"):
                let bundleId = String(p.dropFirst("/api/v1/apps/".count)).removingPercentEncoding ?? ""
                return try await uninstall(bundleId: bundleId, keepData: req.query["keepData"] == "1" || req.query["keepData"] == "true")

            case ("POST", "/api/v1/apps/from-url"):
                return await installFromURL(req)

            case ("GET", "/api/v1/jobs"):
                return await jobsList()

            case ("GET", let p) where p.hasPrefix("/api/v1/jobs/"):
                return await jobStatus(String(p.dropFirst("/api/v1/jobs/".count)))

            case ("POST", let p) where p.hasPrefix("/api/v1/apps/") && p.hasSuffix("/launch"):
                let bundleId = String(p.dropFirst("/api/v1/apps/".count).dropLast("/launch".count))
                return try await launch(req, bundleId: bundleId)

            case ("GET", "/api/v1/tweaks"):
                return try await tweakList(folder: req.query["folder"])

            case ("POST", "/api/v1/tweaks"):
                return try await tweakImport(req, folder: req.query["folder"])

            case ("PATCH", "/api/v1/tweaks"):
                return try await tweakSetEnabled(req)

            case ("DELETE", "/api/v1/tweaks"):
                return try await tweakDelete(req)

            case ("POST", "/api/v1/tweaks/sign"):
                return try await tweakSign(req)

            case ("POST", "/api/v1/tweakfolders"):
                return try await tweakCreateFolder(req)

            case ("GET", "/api/v1/windows"):
                return await windowList()

            case ("POST", let p) where p.hasPrefix("/api/v1/windows/"):
                return try await windowAction(req, path: p)

            case ("GET", "/api/v1/screenshot"):
                return await screenshot(req)

            case ("GET", "/api/v1/ui/tree"):
                return await uiTree()

            case ("POST", "/api/v1/ui/activate"):
                return await uiActivate(req)

            case ("POST", "/api/v1/ui/taps"):
                return await uiTaps(req)

            case ("POST", "/api/v1/ui/tap"):
                return await uiTap(req)

            case ("POST", "/api/v1/ui/tab"):
                return await uiTab(req)

            case ("POST", "/api/v1/ui/text"):
                return await uiText(req)

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

    // MARK: - 异步任务（设备自己下载 IPA）

    @MainActor
    private static func installFromURL(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let obj = (try? JSONSerialization.jsonObject(with: req.bodyData())) as? [String: Any]
        guard let raw = ((obj?["url"] as? String) ?? req.query["url"]), !raw.isEmpty else {
            return .error("需要 url", status: 400, code: "bad_request")
        }
        let nameHint = (obj?["filename"] as? String) ?? req.query["filename"]
        let replace: Bool = {
            if let b = obj?["replace"] as? Bool { return b }
            if let s = req.query["replace"] { return s != "0" && s.lowercased() != "false" }
            return true
        }()
        var urlString = raw
        if !urlString.contains(".") , let hint = nameHint, !hint.isEmpty {
            urlString += "/" + hint
        }
        let job = LCRemoteJobs.shared.create(kind: "install_ipa_from_url")
        job.message = "queued \(urlString)"
        Task { @MainActor in
            await LCRemoteJobs.shared.runInstall(job, urlString: urlString, replaceExisting: replace)
        }
        return .json(job.json, status: 202)
    }

    @MainActor
    private static func jobsList() async -> LCRemoteResponse {
        let items = LCRemoteJobs.shared.all().map { $0.json }
        return .json(["count": items.count, "jobs": items])
    }

    @MainActor
    private static func jobStatus(_ id: String) async -> LCRemoteResponse {
        guard let job = LCRemoteJobs.shared.get(id) else {
            return .error("没有这个任务: \(id)", status: 404, code: "not_found")
        }
        return .json(job.json)
    }

    // MARK: - 启动

    @MainActor
    private static func launch(_ req: LCRemoteRequest, bundleId: String) async throws -> LCRemoteResponse {
        let model = (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps)
            .first { $0.appInfo.bundleIdentifier() == bundleId }
        guard let model else {
            return .error("未找到应用 \(bundleId)", status: 404, code: "not_found")
        }
        let container = req.query["container"].flatMap { $0.isEmpty ? nil : $0 }
        let urlStr = req.query["url"].flatMap { $0.isEmpty ? nil : $0 }
        // multitask=1 → 在 LiveContainer 内的多任务窗口里跑，主 UI 不退，HTTP 服务不会跟着挂起
        let multitask: Bool? = req.query["multitask"].map { $0 == "1" || $0.lowercased() == "true" }
        LCRemoteLogStore.shared.append("launch \(bundleId) (container=\(container ?? "-"), url=\(urlStr ?? "-"))", src: "api")
        do {
            try await model.runApp(multitask: multitask, containerFolderName: container, urlStr: urlStr)
        } catch {
            return .error("启动失败: \(error.localizedDescription)", status: 500, code: "launch_failed")
        }
        return .json(["launched": true, "bundleId": bundleId,
                      "multitask": multitask.map { $0 } ?? NSNull(),
                      "isAppRunning": model.isAppRunning])
    }

    // MARK: - Tweaks

    @MainActor
    private static func tweakList(folder: String?) async throws -> LCRemoteResponse {
        let items = try LCTweakManager.list(folder: folder)
        let folders: [String] = DataManager.shared.model.tweakFolderNames
        return .json(["folder": folder ?? "", "count": items.count,
                      "tweaks": items.map { $0.json }, "folders": folders])
    }

    @MainActor
    private static func tweakImport(_ req: LCRemoteRequest, folder: String?) async throws -> LCRemoteResponse {
        let ctype = (req.header("content-type") ?? "").lowercased()
        if ctype.hasPrefix("application/json") {
            return .error("POST /api/v1/tweaks 需要 multipart 文件；切换启用状态请用 PATCH /api/v1/tweaks {name,enabled,folder}",
                          status: 400, code: "bad_request")
        }
        let upload = try LCRemoteUpload.extract(req)
        // 导入是 move 语义：内容已落在临时文件，交给 manager 搬走
        let name = req.query["filename"] ?? upload.filename
        let summary = try await LCTweakManager.importTweak(from: upload.url, folder: folder, filename: name)
        return .json(summary.json, status: 201)
    }

    @MainActor
    private static func tweakSetEnabled(_ req: LCRemoteRequest) async throws -> LCRemoteResponse {
        let body = req.bodyData()
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let name = (obj?["name"] as? String) ?? req.query["name"] ?? ""
        let enabled: Bool = {
            if let b = obj?["enabled"] as? Bool { return b }
            if let s = obj?["enabled"] as? String { return s == "1" || s.lowercased() == "true" }
            return req.query["enabled"] == "1" || req.query["enabled"] == "true"
        }()
        let folder = (obj?["folder"] as? String) ?? req.query["folder"]
        guard !name.isEmpty else {
            return .error("需要 name", status: 400, code: "bad_request")
        }
        let summary = try LCTweakManager.setEnabled(folder: folder, name: name, enabled: enabled)
        return .json(summary.json)
    }

    @MainActor
    private static func tweakDelete(_ req: LCRemoteRequest) async throws -> LCRemoteResponse {
        guard let name = req.query["name"], !name.isEmpty else {
            return .error("需要 name", status: 400, code: "bad_request")
        }
        try LCTweakManager.delete(folder: req.query["folder"], name: name)
        return .json(["deleted": name])
    }

    @MainActor
    private static func tweakSign(_ req: LCRemoteRequest) async throws -> LCRemoteResponse {
        let force = req.query["force"] == "1" || req.query["force"] == "true"
        let result = try await LCTweakManager.sign(folder: req.query["folder"], force: force)
        return .json(result)
    }

    @MainActor
    private static func tweakCreateFolder(_ req: LCRemoteRequest) async throws -> LCRemoteResponse {
        let body = req.bodyData()
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let name = (obj?["name"] as? String) ?? req.query["name"] ?? ""
        guard !name.isEmpty else {
            return .error("需要 name", status: 400, code: "bad_request")
        }
        let created = try LCTweakManager.createFolder(name)
        return .json(["created": created], status: 201)
    }

    // MARK: - 多任务窗口 / 截图

    @MainActor
    private static func windowList() async -> LCRemoteResponse {
        let infos = LCWindowManager.windows()
        return .json(["count": infos.count, "windows": infos.map { $0.json }])
    }

    /// POST /api/v1/windows/{id}/{scale|pip|maximize|close}
    /// 参数走 query 或 JSON body：scale=<0.4-3.0>, enabled=true/false
    @MainActor
    private static func windowAction(_ req: LCRemoteRequest, path: String) async throws -> LCRemoteResponse {
        let rest = String(path.dropFirst("/api/v1/windows/".count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .error("用法: /api/v1/windows/{id}/scale|pip|maximize|close", status: 400, code: "bad_request")
        }
        let id = parts[0].removingPercentEncoding ?? parts[0]
        let action = parts[1]
        let body = req.bodyData()
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]

        func boolValue(_ key: String, default def: Bool) -> Bool {
            if let b = obj?[key] as? Bool { return b }
            if let s = obj?[key] as? String { return s == "1" || s.lowercased() == "true" }
            if let q = req.query[key] { return q == "1" || q.lowercased() == "true" }
            return def
        }
        func doubleValue(_ key: String) -> Double? {
            if let d = obj?[key] as? Double { return d }
            if let s = obj?[key] as? String { return Double(s) }
            if let q = req.query[key] { return Double(q) }
            return nil
        }

        do {
            switch action {
            case "scale":
                guard let v = doubleValue("scale") ?? doubleValue("value") else {
                    return .error("scale 需要数值", status: 400, code: "bad_request")
                }
                try LCWindowManager.setScale(id, CGFloat(v))
            case "pip":
                try LCWindowManager.setPiP(id, enabled: boolValue("enabled", default: true))
            case "maximize":
                try LCWindowManager.setMaximized(id, maximized: boolValue("enabled", default: true))
            case "close":
                try LCWindowManager.close(id)
            default:
                return .error("未知动作 \(action)", status: 400, code: "bad_request")
            }
        } catch {
            return .error(error.localizedDescription, status: 400, code: "window_action_failed")
        }
        let infos = LCWindowManager.windows()
        return .json(["ok": true, "action": action, "id": id,
                      "windows": infos.map { $0.json }])
    }

    @MainActor
    private static func screenshot(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let windowId = req.query["windowId"] ?? req.query["id"]
        let quality = min(max((Double(req.query["quality"] ?? "70") ?? 70) / 100.0, 0.1), 1.0)
        let maxWidth = CGFloat(Double(req.query["maxWidth"] ?? "1290") ?? 1290)
        guard let data = LCScreenshot.capture(windowId: windowId, maxWidth: maxWidth, quality: CGFloat(quality)) else {
            return .error("截图失败（窗口不可见或视图为空）", status: 500, code: "capture_failed")
        }
        return LCRemoteResponse(status: 200,
                                headers: ["Content-Type": "image/jpeg",
                                          "X-Window-Id": windowId ?? "key"],
                                body: data)
    }

    // MARK: - 保活

    @MainActor
    private static func keepAlive(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let body = req.bodyData()
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let raw = (obj?["mode"] as? String) ?? req.query["mode"]
        guard let raw, let mode = LCRemoteKeepAliveMode(rawValue: raw) else {
            let allowed = LCRemoteKeepAliveMode.allCases.map { $0.rawValue }
            return .error("mode 必须是 \(allowed.joined(separator: " / "))", status: 400, code: "bad_request")
        }
        LCRemoteKeepAlive.shared.apply(mode)
        return .json(["ok": true, "keepAlive": LCRemoteKeepAlive.shared.status])
    }

    // MARK: - 自身信息（排查"扩展找不到"这类安装问题）

    @MainActor
    private static func selfInfo() async -> LCRemoteResponse {
        let fm = FileManager.default
        let main = Bundle.main
        var plugins: [[String: Any]] = []
        if let dir = main.builtInPlugInsURL {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.sorted() {
                let url = dir.appendingPathComponent(name)
                let bundle = Bundle(url: url)
                let exec = bundle?.executableURL
                plugins.append([
                    "name": name,
                    "bundleId": bundle?.bundleIdentifier ?? "",
                    "executable": exec?.lastPathComponent ?? "",
                    "executableExists": exec.map { fm.fileExists(atPath: $0.path) } ?? false
                ])
            }
        }
        var frameworks: [String] = []
        if let fwDir = main.privateFrameworksURL {
            frameworks = ((try? fm.contentsOfDirectory(atPath: fwDir.path)) ?? []).sorted()
        }
        return .json([
            "bundlePath": main.bundlePath,
            "bundleId": main.bundleIdentifier ?? "",
            "version": (main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
            "build": (main.infoDictionary?["CFBundleVersion"] as? String) ?? "",
            "pluginsPath": main.builtInPlugInsURL?.path ?? "",
            "plugins": plugins,
            "frameworks": frameworks
        ])
    }

    // MARK: - UI 自动化

    private static func jsonBody(_ req: LCRemoteRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.bodyData())) as? [String: Any] ?? [:]
    }

    @MainActor
    private static func uiTree() async -> LCRemoteResponse {
        let items = LCRemoteUIAutomation.tree()
        return .json(["count": items.count, "elements": items.map { $0.json }])
    }

    /// {"index":12} 或 {"label":"App"} / {"identifier":"xxx"}
    @MainActor
    private static func uiActivate(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let obj = jsonBody(req)
        if let raw = obj["index"] as? Int {
            let r = LCRemoteUIAutomation.activate(index: raw)
            return .json(["ok": r.ok, "detail": r.detail, "index": raw])
        }
        if let rawStr = obj["index"] as? String, let raw = Int(rawStr) {
            let r = LCRemoteUIAutomation.activate(index: raw)
            return .json(["ok": r.ok, "detail": r.detail, "index": raw])
        }
        let label = (obj["label"] as? String) ?? req.query["label"] ?? ""
        let ident = (obj["identifier"] as? String) ?? req.query["identifier"] ?? ""
        guard !label.isEmpty || !ident.isEmpty else {
            return .error("需要 index / label / identifier 之一", status: 400, code: "bad_request")
        }
        let r = LCRemoteUIAutomation.activate(label: label, identifier: ident)
        return .json(["ok": r.ok, "detail": r.detail, "label": label, "identifier": ident])
    }

    /// {"x":120,"y":300}
    @MainActor
    private static func uiTap(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let obj = jsonBody(req)
        func number(_ key: String) -> Double? {
            if let d = obj[key] as? Double { return d }
            if let i = obj[key] as? Int { return Double(i) }
            if let s = obj[key] as? String { return Double(s) }
            if let q = req.query[key] { return Double(q) }
            return nil
        }
        guard let x = number("x"), let y = number("y") else {
            return .error("需要 x / y", status: 400, code: "bad_request")
        }
        let r = LCRemoteUIAutomation.tap(x: CGFloat(x), y: CGFloat(y))
        return .json(["ok": r.ok, "detail": r.detail, "x": x, "y": y])
    }

    /// {"index":1} 或 {"name":"App"}
    @MainActor
    private static func uiTab(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let obj = jsonBody(req)
        var index: Int?
        if let i = obj["index"] as? Int { index = i }
        else if let s = obj["index"] as? String { index = Int(s) }
        else if let q = req.query["index"] { index = Int(q) }
        if index == nil, let name = (obj["name"] as? String) ?? req.query["name"], !name.isEmpty {
            // 名字走可访问性激活（Tab 按钮都有 label）
            let r = LCRemoteUIAutomation.activate(label: name, identifier: "")
            return .json(["ok": r.ok, "detail": r.detail, "name": name])
        }
        let r = LCRemoteUIAutomation.tab(index: index)
        return .json(["ok": r.ok, "detail": r.detail, "index": index ?? -1])
    }

    /// {"steps":[{"label":"启动"},{"x":200,"y":300,"delayMs":800}], "detectChange":true, "captureAfter":true}
    @MainActor
    private static func uiTaps(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let obj = jsonBody(req)
        guard let steps = obj["steps"] as? [[String: Any]], !steps.isEmpty else {
            return .error("需要 steps 数组", status: 400, code: "bad_request")
        }
        let detect = (obj["detectChange"] as? Bool) ?? true
        let results = await LCRemoteUIAutomation.runSequence(steps, detectChange: detect)
        var payload: [String: Any] = ["count": results.count, "steps": results]
        if (obj["captureAfter"] as? Bool) ?? false,
           let data = LCScreenshot.capture(windowId: obj["windowId"] as? String,
                                           maxWidth: 600, quality: 0.6) {
            payload["screenshotB64"] = data.base64EncodedString()
            payload["screenshotBytes"] = data.count
        }
        return .json(payload)
    }

    /// {"text":"hello"}
    @MainActor
    private static func uiText(_ req: LCRemoteRequest) async -> LCRemoteResponse {
        let obj = jsonBody(req)
        let text = (obj["text"] as? String) ?? req.query["text"] ?? ""
        guard !text.isEmpty else {
            return .error("需要 text", status: 400, code: "bad_request")
        }
        let r = LCRemoteUIAutomation.typeText(text)
        return .json(["ok": r.ok, "detail": r.detail, "text": text])
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

    // MARK: - guest 日志（LiveProcess 侧落盘）

    private static func guestLogs(_ req: LCRemoteRequest) -> LCRemoteResponse {
        if let name = req.query["name"] {
            let offset = Int(req.query["offset"] ?? "0") ?? 0
            let limit = min(max(Int(req.query["limit"] ?? "65536") ?? 65536, 512), 1024 * 1024)
            guard let payload = LCRemoteGuestLogs.read(name: name, offset: offset, limitBytes: limit) else {
                return .error("没有这个日志文件: \(name)", status: 404, code: "not_found")
            }
            return .json(payload)
        }
        let items = LCRemoteGuestLogs.list()
        return .json(["count": items.count, "logs": items])
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
