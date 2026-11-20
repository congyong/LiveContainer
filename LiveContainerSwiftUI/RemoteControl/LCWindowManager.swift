//
//  LCWindowManager.swift
//  LiveContainerSwiftUI
//
//  多任务窗口（小窗 / PiP / 缩放 / 最大化 / 关闭）的远程控制。
//  这些窗口是 Scene 承载的 AppSceneViewController，套在 DecoratedAppSceneViewController 里，
//  所以做法是遍历当前所有 scene 的 VC 树，找到这些控制器再操作。
//

import UIKit

struct LCWindowInfo {
    let id: String            // dataUUID，一个 App 实例唯一
    let bundleId: String
    let pid: Int32
    let isRunning: Bool
    let scale: CGFloat
    let isMaximized: Bool?
    let isDecorated: Bool
    let frame: CGRect

    var json: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "bundleId": bundleId,
            "pid": Int(pid),
            "running": isRunning,
            "scale": Double(scale),
            "decorated": isDecorated,
            "frame": ["x": Double(frame.origin.x), "y": Double(frame.origin.y),
                      "width": Double(frame.width), "height": Double(frame.height)]
        ]
        if let isMaximized { d["maximized"] = isMaximized }
        return d
    }
}

enum LCWindowManagerError: LocalizedError {
    case notFound(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "没有这个窗口: \(id)"
        case .unsupported(let m): return m
        }
    }
}

@MainActor
enum LCWindowManager {

    // MARK: - 枚举

    private static func collectControllers(_ vc: UIViewController?, into out: inout [UIViewController]) {
        guard let vc else { return }
        out.append(vc)
        for child in vc.children {
            collectControllers(child, into: &out)
        }
        collectControllers(vc.presentedViewController, into: &out)
    }

    private static func allControllers() -> [UIViewController] {
        var out: [UIViewController] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                collectControllers(window.rootViewController, into: &out)
            }
        }
        return out
    }

    static func windows() -> [LCWindowInfo] {
        let vcs = allControllers()
        var out: [LCWindowInfo] = []
        var seen = Set<String>()
        for vc in vcs {
            if let deco = vc as? DecoratedAppSceneViewController, let inner = deco.appSceneVC {
                let id = inner.dataUUID ?? ""
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(LCWindowInfo(id: id, bundleId: inner.bundleId ?? "", pid: inner.pid,
                                        isRunning: inner.isAppRunning, scale: deco.scaleRatio,
                                        isMaximized: deco.isMaximized, isDecorated: true,
                                        frame: deco.view.frame))
            } else if let scene = vc as? AppSceneViewController {
                let id = scene.dataUUID ?? ""
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(LCWindowInfo(id: id, bundleId: scene.bundleId ?? "", pid: scene.pid,
                                        isRunning: scene.isAppRunning, scale: scene.scaleRatio,
                                        isMaximized: nil, isDecorated: false,
                                        frame: scene.view.frame))
            }
        }
        return out
    }

    static func find(_ id: String) -> (decorated: DecoratedAppSceneViewController?, scene: AppSceneViewController)? {
        for vc in allControllers() {
            if let deco = vc as? DecoratedAppSceneViewController, let inner = deco.appSceneVC,
               inner.dataUUID == id {
                return (deco, inner)
            }
            if let scene = vc as? AppSceneViewController, scene.dataUUID == id {
                return (nil, scene)
            }
        }
        return nil
    }

    // MARK: - 动作

    /// 缩放（0.4–3.0），与 UI 里那个 scale 滑块的实现保持一致
    static func setScale(_ id: String, _ scale: CGFloat) throws {
        guard let found = find(id), let scene = found.scene else {
            throw LCWindowManagerError.notFound(id)
        }
        let clamped = min(max(scale, 0.4), 3.0)
        scene.scaleRatio = clamped
        if let deco = found.decorated {
            deco.scaleRatio = clamped
            deco.updateVerticalConstraints()
        }
        guard let content = scene.contentView else { return }
        if scene.usesHostingControllerAPI() {
            content.transform = CGAffineTransform(scaleX: clamped, y: clamped)
        } else {
            content.layer.sublayerTransform = CATransform3DMakeScale(clamped, clamped, 1.0)
        }
        scene.updateFrameWithSettingsBlock { settings in
            settings.peripheryInsets = .zero
            settings.safeAreaInsetsPortrait = .zero
        }
        LCRemoteLogStore.shared.append("window \(id) scale -> \(clamped)", src: "api")
    }

    /// 小窗 / 恢复：走 DecoratedAppSceneViewController 的 PiP 收放
    static func setPiP(_ id: String, enabled: Bool) throws {
        guard let found = find(id), let deco = found.decorated else {
            throw LCWindowManagerError.unsupported("窗口 \(id) 不是装饰窗口，没法切小窗")
        }
        if enabled {
            deco.minimizeWindowPiP()
        } else {
            deco.unminimizeWindowPiP()
        }
        LCRemoteLogStore.shared.append("window \(id) pip=\(enabled)", src: "api")
    }

    static func setMaximized(_ id: String, maximized: Bool) throws {
        guard let found = find(id), let deco = found.decorated else {
            throw LCWindowManagerError.unsupported("窗口 \(id) 不是装饰窗口")
        }
        deco.isMaximized = maximized
        deco.updateVerticalConstraints()
        LCRemoteLogStore.shared.append("window \(id) maximized=\(maximized)", src: "api")
    }

    static func close(_ id: String) throws {
        guard let found = find(id), let scene = found.scene else {
            throw LCWindowManagerError.notFound(id)
        }
        scene.terminate()
        LCRemoteLogStore.shared.append("window \(id) terminated", src: "api")
    }

    /// 截图用：优先装饰窗口整块，其次 App 内容视图
    static func captureView(_ id: String?) -> UIView? {
        if let id, let found = find(id) {
            return found.decorated?.view ?? found.scene?.view
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
