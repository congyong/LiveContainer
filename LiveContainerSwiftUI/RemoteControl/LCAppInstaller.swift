//
//  LCAppInstaller.swift
//  LiveContainerSwiftUI
//
//  把 LCAppListView.installIpaFile / LCAppBannerViewController.uninstall 里
//  与 UI 无关的部分抽出来，供远程 API 复用。行为与原实现保持一致：
//  解压 → 找 .app → 落到 LCPath.bundlePath → patchExecAndSignIfNeed → 进 sharedModel。
//

import Foundation

enum LCAppInstallerError: LocalizedError {
    case decompressFailed
    case noAppBundle
    case cannotReadInfo
    case moveFailed(String)
    case signFailed(String)

    var errorDescription: String? {
        switch self {
        case .decompressFailed: return "ipa 解压失败（文件不是合法 zip，或磁盘不足）"
        case .noAppBundle: return "Payload 里找不到 .app"
        case .cannotReadInfo: return "读不出 .app 的 Info.plist"
        case .moveFailed(let m): return "移动到 Applications 失败: \(m)"
        case .signFailed(let m): return "签名失败: \(m)"
        }
    }
}

@MainActor
enum LCAppInstaller {

    /// 安装一个 ipa。replaceExisting=false 时，同名 bundleId 会以带时间戳的新目录并存。
    static func install(ipa: URL,
                        replaceExisting: Bool = true,
                        progressHandler: ((Double) -> Void)? = nil) async throws -> LCAppInfo {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
        let payloadPath = tmpRoot.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try? fm.removeItem(at: payloadPath)
        }

        let progress = Progress.discreteProgress(totalUnitCount: 100)
        let rc: Int32 = await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: extract(ipa.path, tmpRoot.path, progress))
            }
        }
        guard rc == 0 else { throw LCAppInstallerError.decompressFailed }

        let payloadContents = (try? fm.contentsOfDirectory(atPath: payloadPath.path)) ?? []
        guard let bundleName = payloadContents.first(where: { $0.hasSuffix(".app") }) else {
            throw LCAppInstallerError.noAppBundle
        }
        let srcBundle = payloadPath.appendingPathComponent(bundleName)

        guard let newInfo = LCAppInfo(bundlePath: srcBundle.path),
              let bundleId = newInfo.bundleIdentifier() else {
            throw LCAppInstallerError.cannotReadInfo
        }

        let safeName = bundleId.sanitizeNonACSII()
        var relativePath = "\(safeName).app"
        var dest = LCPath.bundlePath.appendingPathComponent(relativePath)
        try? fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)

        if fm.fileExists(atPath: dest.path) {
            if replaceExisting {
                try? fm.removeItem(at: dest)
            } else {
                relativePath = "\(safeName)_\(Int(CFAbsoluteTimeGetCurrent())).app"
                dest = LCPath.bundlePath.appendingPathComponent(relativePath)
            }
        }

        do {
            try fm.moveItem(at: srcBundle, to: dest)
        } catch {
            throw LCAppInstallerError.moveFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: payloadPath)

        guard let finalNewApp = LCAppInfo(bundlePath: dest.path) else {
            throw LCAppInstallerError.cannotReadInfo
        }
        finalNewApp.relativeBundlePath = relativePath
        finalNewApp.spoofSDKVersion = true
        finalNewApp.installationDate = Date.now

        // 签名（ZSign），与原 UI 流程一致；失败也保留 app（ceiling: 与原实现一致的宽容）
        let signResult: (Bool, String?) = await withCheckedContinuation { c in
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                c.resume(returning: (success, error))
            }, progressHandler: { _ in }, forceSign: false)
        }
        if !signResult.0 {
            LCRemoteLogStore.shared.append("install \(bundleId): sign failed: \(signResult.1 ?? "unknown")",
                                           src: "api")
        }

        // 同名旧模型先摘掉，避免列表里出现两份
        DataManager.shared.model.apps.removeAll { $0.appInfo.bundleIdentifier() == bundleId }
        DataManager.shared.model.hiddenApps.removeAll { $0.appInfo.bundleIdentifier() == bundleId }
        let model = LCAppModel(appInfo: finalNewApp)
        DataManager.shared.model.apps.append(model)

        LCRemoteLogStore.shared.append("installed \(bundleId) -> \(relativePath)", src: "api")
        progressHandler?(1.0)
        return finalNewApp
    }

    /// 卸载：删 bundle，按需删数据容器与 keychain。
    @discardableResult
    static func uninstall(bundleId: String, removeData: Bool) throws -> [String: Any] {
        let fm = FileManager.default
        let model = (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps)
            .first { $0.appInfo.bundleIdentifier() == bundleId }
        guard let appInfo = model?.appInfo, let bundlePath = appInfo.bundlePath() else {
            throw NSError(domain: "LCRemote", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "未找到应用 \(bundleId)"])
        }
        let containers = appInfo.containers
        try fm.removeItem(atPath: bundlePath)
        DataManager.shared.model.apps.removeAll { $0.appInfo.bundleIdentifier() == bundleId }
        DataManager.shared.model.hiddenApps.removeAll { $0.appInfo.bundleIdentifier() == bundleId }

        var removedData: [String] = []
        if removeData {
            for container in containers {
                let folder = container.folderName
                guard !folder.isEmpty else { continue }
                try? fm.removeItem(at: container.containerURL)
                LCUtils.removeAppKeychain(dataUUID: folder)
                DataManager.shared.model.appDataFolderNames.removeAll { $0 == folder }
                removedData.append(folder)
            }
        }
        LCRemoteLogStore.shared.append("uninstalled \(bundleId) (data=\(removeData), containers=\(removedData.count))",
                                       src: "api")
        return ["bundleId": bundleId, "removedDataFolders": removedData]
    }

    /// 列表用：单个 app 的摘要
    @MainActor
    static func summary(of model: LCAppModel) -> [String: Any] {
        let info = model.appInfo
        var d: [String: Any] = [
            "bundleId": info.bundleIdentifier() ?? "",
            "name": info.displayName() ?? "",
            "version": info.version() ?? "",
            "relativePath": info.relativeBundlePath ?? "",
            "path": info.bundlePath() ?? "",
            "isHidden": info.isHidden,
            "isShared": info.isShared,
            "containers": info.containers.map { ["folderName": $0.folderName, "name": $0.name] },
            "isAppRunning": model.isAppRunning
        ]
        if let last = info.lastLaunched {
            d["lastLaunched"] = ISO8601DateFormatter().string(from: last as Date)
        }
        if let inst = info.installationDate {
            d["installationDate"] = ISO8601DateFormatter().string(from: inst as Date)
        }
        return d
    }
}
