//
//  LCTweakManager.swift
//  LiveContainerSwiftUI
//
//  tweak 目录管理：列表 / 导入 / 启停 / 删除 / 重签。
//  与 LCTweaksView 的约定保持一致：
//   - 根目录 = LCPath.tweakPath，子目录 = 某个 App 的专用 tweak 文件夹
//   - 停用 = 文件名加 ".disabled" 后缀（TweakLoader 只加载不带后缀的）
//   - 导入后按 UI 的做法补 rpath（LCParseMachO + LCPatchAddRPath）
//   - 真正的 ZSign 重签在启动前由 LCUtils.signTweaks 做；这里可选地提前签一次
//

import Foundation

enum LCTweakManagerError: LocalizedError {
    case badFolder(String)
    case notFound(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .badFolder(let f): return "非法 tweak 目录: \(f)"
        case .notFound(let n): return "找不到 \(n)"
        case .unsupported(let n): return "不支持的文件类型: \(n)"
        }
    }
}

struct LCTweakSummary {
    let name: String          // 不含 .disabled 的显示名
    let fileName: String      // 磁盘上的真实文件名
    let folder: String        // "" = 根目录
    let path: String
    let isEnabled: Bool
    let isFolder: Bool
    let isFramework: Bool
    let isTweak: Bool

    var json: [String: Any] {
        ["name": name, "fileName": fileName, "folder": folder, "path": path,
         "enabled": isEnabled, "isFolder": isFolder,
         "isFramework": isFramework, "isTweak": isTweak]
    }
}

@MainActor
enum LCTweakManager {
    static let disabledSuffix = ".disabled"

    // MARK: - 路径

    static func folderURL(_ folder: String?) throws -> URL {
        let root = LCPath.tweakPath
        guard let folder, !folder.isEmpty else { return root }
        // 防目录穿越
        guard !folder.contains("/"), !folder.contains(".."), folder != "." else {
            throw LCTweakManagerError.badFolder(folder)
        }
        let url = root.appendingPathComponent(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw LCTweakManagerError.notFound(folder)
        }
        return url
    }

    static func createFolder(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            throw LCTweakManagerError.badFolder(name)
        }
        let url = LCPath.tweakPath.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if !DataManager.shared.model.tweakFolderNames.contains(name) {
            DataManager.shared.model.tweakFolderNames.append(name)
        }
        LCRemoteLogStore.shared.append("tweak folder created: \(name)", src: "api")
        return name
    }

    // MARK: - 列表

    static func list(folder: String?) throws -> [LCTweakSummary] {
        let base = try folderURL(folder)
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
        var out: [LCTweakSummary] = []
        for fileName in names.sorted() {
            let url = base.appendingPathComponent(fileName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let enabled = !fileName.hasSuffix(disabledSuffix)
            let displayName = enabled ? fileName : String(fileName.dropLast(disabledSuffix.count))
            let isFramework = isDir.boolValue && displayName.hasSuffix(".framework")
            let isTweak = !isDir.boolValue && displayName.hasSuffix(".dylib")
            out.append(LCTweakSummary(name: displayName, fileName: fileName,
                                      folder: folder ?? "", path: url.path,
                                      isEnabled: enabled, isFolder: isDir.boolValue,
                                      isFramework: isFramework, isTweak: isTweak))
        }
        return out
    }

    // MARK: - 导入

    /// 把上传的文件落到 tweak 目录，补 rpath，并尝试立即重签一次。
    @discardableResult
    static func importTweak(from source: URL, folder: String?, filename: String? = nil,
                            sign: Bool = true) async throws -> LCTweakSummary {
        let base = try folderURL(folder)
        let fm = FileManager.default
        let name = filename ?? source.lastPathComponent
        guard name.hasSuffix(".dylib") || name.hasSuffix(".framework") || name.hasSuffix(".zip") else {
            throw LCTweakManagerError.unsupported(name)
        }
        let dest = base.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        if name.hasSuffix(".zip") {
            // framework 打包上传：解压到临时目录后整体搬进去
            let tmp = fm.temporaryDirectory.appendingPathComponent("lc-tweak-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let rc = extract(source.path, tmp.path, Progress(totalUnitCount: 1))
            guard rc == 0 else {
                throw LCTweakManagerError.unsupported("zip 解压失败: \(name)")
            }
            let inner = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
            guard let fw = inner.first(where: { $0.hasSuffix(".framework") || $0.hasSuffix(".dylib") }) else {
                throw LCTweakManagerError.unsupported("zip 里没有 .dylib/.framework")
            }
            try fm.moveItem(at: tmp.appendingPathComponent(fw), to: dest)
            try? fm.removeItem(at: tmp)
        } else if source.path != dest.path {
            try fm.moveItem(at: source, to: dest)
        }

        // 与 UI 一致：给 dylib 补 @executable_path/Frameworks 的 rpath
        if name.hasSuffix(".dylib") {
            LCParseMachO((dest.path as NSString).utf8String, false) { path, header, _, _ in
                LCPatchAddRPath(path, header)
            }
        }

        if sign, LCSharedUtils.certificatePassword() != nil {
            do {
                try await LCUtils.signTweaks(tweakFolderUrl: base, force: false)
            } catch {
                LCRemoteLogStore.shared.append("tweak sign failed (\(name)): \(error.localizedDescription)", src: "api")
            }
        }

        LCRemoteLogStore.shared.append("tweak imported: \(name) into \(folder ?? "<root>")", src: "api")
        let summaries = try list(folder: folder)
        return summaries.first { $0.fileName == name || $0.name == name }
            ?? LCTweakSummary(name: name, fileName: name, folder: folder ?? "", path: dest.path,
                              isEnabled: true, isFolder: false,
                              isFramework: name.hasSuffix(".framework"),
                              isTweak: name.hasSuffix(".dylib"))
    }

    // MARK: - 启停 / 删除

    static func setEnabled(folder: String?, name: String, enabled: Bool) throws -> LCTweakSummary {
        let base = try folderURL(folder)
        let fm = FileManager.default
        let displayName = name.hasSuffix(disabledSuffix) ? String(name.dropLast(disabledSuffix.count)) : name
        let currentURL = base.appendingPathComponent(name)
        guard fm.fileExists(atPath: currentURL.path) else {
            throw LCTweakManagerError.notFound(name)
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: currentURL.path, isDirectory: &isDir)
        guard !isDir.boolValue || displayName.hasSuffix(".framework") else {
            throw LCTweakManagerError.unsupported("\(displayName) 是 tweak 文件夹，不能启停")
        }
        let targetName = enabled ? displayName : displayName + disabledSuffix
        if targetName != name {
            try fm.moveItem(at: currentURL, to: base.appendingPathComponent(targetName))
        }
        LCRemoteLogStore.shared.append("tweak \(displayName) -> \(enabled ? "enabled" : "disabled")", src: "api")
        return LCTweakSummary(name: displayName, fileName: targetName, folder: folder ?? "",
                              path: base.appendingPathComponent(targetName).path,
                              isEnabled: enabled, isFolder: isDir.boolValue,
                              isFramework: displayName.hasSuffix(".framework"),
                              isTweak: displayName.hasSuffix(".dylib"))
    }

    static func delete(folder: String?, name: String) throws {
        let base = try folderURL(folder)
        let url = base.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LCTweakManagerError.notFound(name)
        }
        try FileManager.default.removeItem(at: url)
        if (folder ?? "").isEmpty {
            DataManager.shared.model.tweakFolderNames.removeAll { $0 == name }
        }
        LCRemoteLogStore.shared.append("tweak deleted: \(name)", src: "api")
    }

    static func sign(folder: String?, force: Bool) async throws {
        let base = try folderURL(folder)
        try await LCUtils.signTweaks(tweakFolderUrl: base, force: force)
    }
}
