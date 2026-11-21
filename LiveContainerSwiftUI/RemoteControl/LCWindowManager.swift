//
//  LCWindowManager.swift
//  LiveContainerSwiftUI
//
//  多任务窗口（小窗 / PiP / 缩放 / 最大化 / 关闭）的远程控制。
//  这些窗口是 Scene 承载的 AppSceneViewController，套在 DecoratedAppSceneViewController 里，
//  所以做法是遍历当前所有 scene 的 VC 树，找到这些控制器再操作。
//
//  注意：这两个类是 API_AVAILABLE(ios(16.0))，而 app 的部署目标是 iOS 15，
//  所以所有引用都收在 @available(iOS 16.0, *) 的内部实现里，对外只做 guard 转发。
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

    static func windows() -> [LCWindowInfo] {
        if #available(iOS 16.0, *) {
            return LCWindowManager16.windows()
        }
        return []
    }

    /// 缩放（0.4–3.0），与 UI 里那个 scale 滑块的实现保持一致
    static func setScale(_ id: String, _ scale: CGFloat) throws {
        guard #available(iOS 16.0, *) else { throw LCWindowManagerError.unsupported("需要 iOS 16+") }
        try LCWindowManager16.setScale(id, scale)
    }

    /// 小窗 / 还原：走 DecoratedAppSceneViewController 的 PiP 收放
    static func setPiP(_ id: String, enabled: Bool) throws {
        guard #available(iOS 16.0, *) else { throw LCWindowManagerError.unsupported("需要 iOS 16+") }
        try LCWindowManager16.setPiP(id, enabled: enabled)
    }

    static func setMaximized(_ id: String, maximized: Bool) throws {
        guard #available(iOS 16.0, *) else { throw LCWindowManagerError.unsupported("需要 iOS 16+") }
        try LCWindowManager16.setMaximized(id, maximized: maximized)
    }

    static func close(_ id: String) throws {
        guard #available(iOS 16.0, *) else { throw LCWindowManagerError.unsupported("需要 iOS 16+") }
        try LCWindowManager16.close(id)
    }

    /// 截图用：优先装饰窗口整块，其次 App 内容视图；id 为空则取 key window
    static func captureView(_ id: String?) -> UIView? {
        if let id {
            if #available(iOS 16.0, *) {
                return LCWindowManager16.captureView(id)
            }
            return nil
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

@available(iOS 16.0, *)
@MainActor
private enum LCWindowManager16 {

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
        var out: [LCWindowInfo] = []
        var seen = Set<String>()
        for vc in allControllers() {
            if let deco = vc as? DecoratedAppSceneViewController, let inner = deco.appSceneVC {
                let id = inner.dataUUID ?? ""
                guard !id.isEmpty else { continue }
                if seen.contains(id) {
                    // 已经有同 id 的条目了：只有在跑的那个才覆盖掉旧的僵尸条目
                    if inner.isAppRunning, let i = out.firstIndex(where: { $0.id == id }) {
                        out[i] = LCWindowInfo(id: id, bundleId: inner.bundleId ?? "", pid: inner.pid,
                                              isRunning: true, scale: deco.scaleRatio,
                                              isMaximized: deco.isMaximized, isDecorated: true,
                                              frame: deco.view.frame)
                    }
                    continue
                }
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

    /// 按 dataUUID 找控制器。同一个 id 可能同时存在"上一轮残留（已退出）"和"当前在跑"的对象，
    /// 所以要两趟：先找 isAppRunning 的，找不到再退回任意一个。
    static func find(_ id: String) -> (decorated: DecoratedAppSceneViewController?, scene: AppSceneViewController)? {
        var fallback: (DecoratedAppSceneViewController?, AppSceneViewController)?
        for vc in allControllers() {
            if let deco = vc as? DecoratedAppSceneViewController, let inner = deco.appSceneVC,
               (inner.dataUUID ?? "") == id {
                if inner.isAppRunning { return (deco, inner) }
                if fallback == nil { fallback = (deco, inner) }
            } else if let scene = vc as? AppSceneViewController, (scene.dataUUID ?? "") == id {
                if scene.isAppRunning { return (nil, scene) }
                if fallback == nil { fallback = (nil, scene) }
            }
        }
        return fallback
    }

    static func captureView(_ id: String) -> UIView? {
        guard let found = find(id) else { return nil }
        if let deco = found.decorated { return deco.view }
        return found.scene.view
    }

    /// 装饰窗口标题栏上的三个按钮（关闭 / 最大化 / 最小化）就是 UIBarButtonItem，
    /// 这里把它们连同绑定的 selector 一起列出来，方便"按按钮"而不是自己发明行为。
    static func chromeButtons(_ id: String) -> [[String: Any]] {
        guard let deco = find(id)?.decorated else { return [] }
        var out: [[String: Any]] = []
        let items = (deco.navigationBar.topItem?.leftBarButtonItems ?? [])
                  + (deco.navigationBar.topItem?.rightBarButtonItems ?? [])
        for (i, item) in items.enumerated() {
            guard let action = item.action else { continue }
            out.append([
                "index": i,
                "selector": NSStringFromSelector(action),
                "target": item.target.map { NSStringFromClass(type(of: $0)) } ?? "",
                "enabled": item.isEnabled,
                "tint": item.tintColor.map { "\($0)" } ?? ""
            ])
        }
        return out
    }

    /// 按 UI 上按钮绑定的 selector 触发事件（等价于点那个按钮）
    @discardableResult
    static func pressChrome(_ id: String, selector: String) throws -> [String: Any] {
        guard let deco = find(id)?.decorated else {
            throw LCWindowManagerError.unsupported("窗口 \(id) 不是装饰窗口，没有标题栏按钮")
        }
        let items = (deco.navigationBar.topItem?.leftBarButtonItems ?? [])
                  + (deco.navigationBar.topItem?.rightBarButtonItems ?? [])
        for item in items where item.action != nil {
            guard NSStringFromSelector(item.action!) == selector else { continue }
            let sent = UIApplication.shared.sendAction(item.action!, to: item.target, from: item, for: nil)
            LCRemoteLogStore.shared.append("window \(id) chrome button \(selector) sent=\(sent)", src: "api")
            return ["ok": sent, "selector": selector, "sent": sent]
        }
        // 标题栏没拿到（有些状态按钮不在 items 里）→ 直接对控制器发同名 selector
        let sel = NSSelectorFromString(selector)
        guard deco.responds(to: sel) else {
            throw LCWindowManagerError.unsupported("装饰窗口没有 \(selector)，可用的按钮: \(chromeButtons(id))")
        }
        _ = deco.perform(sel)
        LCRemoteLogStore.shared.append("window \(id) performed \(selector) directly", src: "api")
        return ["ok": true, "selector": selector, "sent": false]
    }

    private static func findSlider(in v: UIView) -> UISlider? {
        if let s = v as? UISlider { return s }
        for sub in v.subviews {
            if let s = findSlider(in: sub) { return s }
        }
        return nil
    }

    static func setScale(_ id: String, _ scale: CGFloat) throws {
        guard let found = find(id) else { throw LCWindowManagerError.notFound(id) }
        let scene = found.scene
        let clamped = min(max(scale, 0.4), 3.0)
        // 优先走 UI 上那个缩放滑块的 valueChanged 事件
        if let deco = found.decorated, let slider = findSlider(in: deco.view) {
            slider.value = Float(clamped)
            slider.sendActions(for: .valueChanged)
            LCRemoteLogStore.shared.append("window \(id) scaleSliderChanged -> \(clamped)", src: "api")
            return
        }
        scene.scaleRatio = clamped
        if let deco = found.decorated {
            deco.scaleRatio = clamped
            deco.updateVerticalConstraints()
        }
        if let content = scene.contentView {
            if scene.usesHostingControllerAPI() {
                content.transform = CGAffineTransform(scaleX: clamped, y: clamped)
            } else {
                content.layer.sublayerTransform = CATransform3DMakeScale(clamped, clamped, 1.0)
            }
        }
        scene.updateFrame(settingsBlock: { (settings: UIMutableApplicationSceneSettings?) in
            guard let settings else { return }
            settings.peripheryInsets = .zero
            settings.safeAreaInsetsPortrait = .zero
        })
        LCRemoteLogStore.shared.append("window \(id) scale -> \(clamped)", src: "api")
    }

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
        if deco.isMaximized != maximized {
            // 绿色按钮绑的就是 maximizeWindow（toggle）
            try pressChrome(id, selector: "maximizeWindow")
        }
        LCRemoteLogStore.shared.append("window \(id) maximized=\(maximized)", src: "api")
    }

    static func close(_ id: String) throws {
        guard let found = find(id) else { throw LCWindowManagerError.notFound(id) }
        if found.decorated != nil {
            // UI 上红色 ✕ 绑的就是 closeWindow（置 _isAppTerminationRequested → scene terminate）
            try pressChrome(id, selector: "closeWindow")
            return
        }
        found.scene.terminate()
        LCRemoteLogStore.shared.append("window \(id) terminated (无装饰窗口)", src: "api")
    }
}
