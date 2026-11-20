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
import CryptoKit

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

struct LCTweakSignatureInfo {
    var hasSignature = false
    var sigSize = 0
    var cdhash = ""

    var json: [String: Any] { ["hasSignature": hasSignature, "sigSize": sigSize, "cdhash": cdhash] }
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
    var signature: LCTweakSignatureInfo?

    var json: [String: Any] {
        ["name": name, "fileName": fileName, "folder": folder, "path": path,
         "enabled": isEnabled, "isFolder": isFolder,
         "isFramework": isFramework, "isTweak": isTweak,
         "signature": signature?.json ?? [:]]
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
            var sig: LCTweakSignatureInfo?
            if isTweak || isFramework {
                let binary = isFramework
                    ? url.appendingPathComponent((displayName as NSString).deletingPathExtension)
                    : url
                sig = signatureInfo(of: binary)
            }
            out.append(LCTweakSummary(name: displayName, fileName: fileName,
                                      folder: folder ?? "", path: url.path,
                                      isEnabled: enabled, isFolder: isDir.boolValue,
                                      isFramework: isFramework, isTweak: isTweak,
                                      signature: sig))
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

    /// 调用方可能传显示名（不带 .disabled）也可能传磁盘名，这里统一解析
    private static func resolve(_ base: URL, name: String) throws -> (displayName: String, url: URL) {
        let fm = FileManager.default
        let stripped = name.hasSuffix(disabledSuffix) ? String(name.dropLast(disabledSuffix.count)) : name
        var candidates = [name, stripped, stripped + disabledSuffix]
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }
        for candidate in candidates {
            let url = base.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) {
                return (stripped, url)
            }
        }
        throw LCTweakManagerError.notFound(name)
    }

    static func setEnabled(folder: String?, name: String, enabled: Bool) throws -> LCTweakSummary {
        let base = try folderURL(folder)
        let fm = FileManager.default
        let (displayName, currentURL) = try resolve(base, name: name)
        var isDir: ObjCBool = false
        fm.fileExists(atPath: currentURL.path, isDirectory: &isDir)
        guard !isDir.boolValue || displayName.hasSuffix(".framework") else {
            throw LCTweakManagerError.unsupported("\(displayName) 是 tweak 文件夹，不能启停")
        }
        let targetName = enabled ? displayName : displayName + disabledSuffix
        if currentURL.lastPathComponent != targetName {
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
        let (displayName, url) = try resolve(base, name: name)
        try FileManager.default.removeItem(at: url)
        if (folder ?? "").isEmpty {
            DataManager.shared.model.tweakFolderNames.removeAll { $0 == name || $0 == displayName }
        }
        LCRemoteLogStore.shared.append("tweak deleted: \(name)", src: "api")
    }

    // MARK: - 签名取证

    /// 解析 LC_CODE_SIGNATURE 与 CodeDirectory，算 cdhash（sha256 前 8 字节）。
    /// 只读文件头和签名块，不整份载入，几 MB 的 dylib 也很快。
    static func signatureInfo(of url: URL) -> LCTweakSignatureInfo {
        var info = LCTweakSignatureInfo()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return info }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 32), head.count == 32 else { return info }
        let magicLE = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magicLE == 0xFEEDFACF else { return info }   // 只处理 64 位 little-endian Mach-O
        let ncmds = head.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        guard let cmds = try? fh.read(upToCount: Int(ncmds) * 32 * 8), !cmds.isEmpty else { return info }

        var dataoff = 0, datasize = 0
        var offset = 0
        let count = Int(ncmds)
        var i = 0
        while i < count && offset + 8 <= cmds.count {
            let cmd = cmds.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            let cmdsize = cmds.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }
            if cmd == 0x1D {   // LC_CODE_SIGNATURE
                dataoff = Int(cmds.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt32.self) })
                datasize = Int(cmds.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self) })
                break
            }
            guard cmdsize >= 8 else { break }
            offset += Int(cmdsize)
            i += 1
        }
        guard dataoff > 0, datasize > 0 else { return info }

        info.hasSignature = true
        info.sigSize = datasize
        guard let fh2 = try? FileHandle(forReadingFrom: url) else { return info }
        defer { try? fh2.close() }
        try? fh2.seek(toOffset: UInt64(dataoff))
        guard let blob = try? fh2.read(upToCount: datasize), blob.count >= 20 else { return info }
        // SuperBlob: magic(4) length(4) count(4) 然后 (type, offset) × count
        let magic = blob.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard magic == 0xFADE0CC0 else { return info }
        let n = Int(blob.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).bigEndian })
        for idx in 0..<max(0, min(n, 16)) {
            let off = Int(blob.withUnsafeBytes { $0.load(fromByteOffset: 12 + idx * 8 + 4, as: UInt32.self).bigEndian })
            guard off + 4 <= blob.count else { continue }
            let cdMagic = blob.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self).bigEndian }
            guard cdMagic == 0xFADE0C02 else { continue }   // CodeDirectory
            let cdLen = Int(blob.withUnsafeBytes { $0.load(fromByteOffset: off + 4, as: UInt32.self).bigEndian })
            guard cdLen > 0, off + cdLen <= blob.count else { continue }
            let cd = blob.subdata(in: off..<(off + cdLen))
            info.cdhash = SHA256.hash(data: cd).prefix(8).map { String(format: "%02x", $0) }.joined()
            break
        }
        return info
    }

    /// 重签并给出前后 cdhash 对比 —— 证书载入失败时 signTweaks 会静默不签，
    /// 只回 {"signed":true} 是骗人的（真机就踩到 PKCS12 mac verify failure）。
    static func sign(folder: String?, force: Bool) async throws -> [String: Any] {
        let base = try folderURL(folder)
        let before = try list(folder: folder).reduce(into: [String: String]()) { acc, item in
            acc[item.fileName] = item.signature?.cdhash ?? ""
        }
        var signError: String?
        do {
            try await LCUtils.signTweaks(tweakFolderUrl: base, force: force)
        } catch {
            signError = error.localizedDescription
        }
        let after = try list(folder: folder)
        var files: [[String: Any]] = []
        var changed = 0
        for item in after {
            guard let sig = item.signature, sig.hasSignature else { continue }
            let prev = before[item.fileName] ?? ""
            let didChange = !prev.isEmpty && prev != sig.cdhash
            if didChange { changed += 1 }
            files.append(["name": item.fileName,
                          "cdhash": sig.cdhash,
                          "sigSize": sig.sigSize,
                          "before": prev,
                          "changed": didChange])
        }
        var result: [String: Any] = [
            "folder": folder ?? "",
            "force": force,
            "files": files,
            "changedCount": changed,
            "signed": changed > 0,
            "certificatePasswordPresent": LCSharedUtils.certificatePassword() != nil
        ]
        if let signError { result["error"] = signError }
        if changed == 0 {
            result["hint"] = "没有任何文件的签名发生变化：多半是证书载入失败（p12 密码不对/证书过期），ZSign 会静默跳过。看 /api/v1/logs 里的 openssl PKCS12 报错。"
        }
        return result
    }
}
