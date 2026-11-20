//
//  LCRemoteUIAutomation.swift
//  LiveContainerSwiftUI
//
//  把 UI 操作暴露给 API，让 agent 能自己点界面自测：
//   - GET  /api/v1/ui/tree      可访问性树（label / identifier / frame / 能否激活）
//   - POST /api/v1/ui/activate  按 index（或 label/identifier）激活元素，走 accessibilityActivate
//   - POST /api/v1/ui/tap       按坐标点击：hitTest → UIControl.sendActions / accessibilityActivate
//   - POST /api/v1/ui/tab       切 Tab（找到 UITabBarController 直接改 selectedIndex，最可靠）
//   - POST /api/v1/ui/text      给当前第一响应者输入文本
//
//  SwiftUI 的按钮没有 UIControl，只能靠 accessibilityActivate —— 这正是 VoiceOver 用的口子。
//

import UIKit

struct LCRemoteUIElement {
    let index: Int
    let label: String
    let identifier: String
    let value: String
    let className: String
    let frame: CGRect
    let isControl: Bool
    let canActivate: Bool
    let depth: Int

    var json: [String: Any] {
        ["index": index,
         "label": label,
         "identifier": identifier,
         "value": value,
         "class": className,
         "frame": ["x": Double(frame.origin.x), "y": Double(frame.origin.y),
                   "w": Double(frame.width), "h": Double(frame.height)],
         "control": isControl,
         "activatable": canActivate,
         "depth": depth]
    }
}

@MainActor
enum LCRemoteUIAutomation {

    private static let maxNodes = 600
    private static let maxDepth = 24

    // MARK: - 树

    private static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.alpha > 0.01 }
    }

    static func tree() -> [LCRemoteUIElement] {
        var out: [LCRemoteUIElement] = []
        for window in windows {
            walkView(window, depth: 0, into: &out)
            if let elements = window.accessibilityElements as? [Any] {
                walkAccessibilityObjects(elements, depth: 1, into: &out)
            }
        }
        return out
    }

    private static func describe(_ obj: Any) -> (label: String, ident: String, value: String, frame: CGRect, activatable: Bool, cls: String)? {
        guard let ns = obj as? NSObject else { return nil }
        let label = ns.accessibilityLabel ?? ""
        let ident = ns.accessibilityIdentifier ?? ""
        let value = ns.accessibilityValue ?? ""
        var frame = CGRect.zero
        if let view = ns as? UIView {
            frame = view.convert(view.bounds, to: nil)
        } else {
            frame = ns.accessibilityFrame
        }
        let activatable = ns.accessibilityTraits.contains(.button)
            || ns.accessibilityTraits.contains(.link)
            || ns.accessibilityTraits.contains(.tabBar)
            || ns is UIControl
        guard !(label.isEmpty && ident.isEmpty && value.isEmpty && frame.isEmpty) else { return nil }
        return (label, ident, value, frame, activatable, String(describing: type(of: ns)))
    }

    private static func walkView(_ view: UIView, depth: Int, into out: inout [LCRemoteUIElement]) {
        guard out.count < maxNodes, depth <= maxDepth else { return }
        guard !view.isHidden, view.alpha > 0.01 else { return }

        if let info = describe(view) {
            out.append(LCRemoteUIElement(index: out.count,
                                         label: info.label, identifier: info.ident,
                                         value: info.value, className: info.cls,
                                         frame: info.frame,
                                         isControl: view is UIControl,
                                         canActivate: info.activatable,
                                         depth: depth))
        }
        if let elements = view.accessibilityElements as? [Any], !elements.isEmpty {
            walkAccessibilityObjects(elements, depth: depth + 1, into: &out)
        }
        for sub in view.subviews {
            walkView(sub, depth: depth + 1, into: &out)
        }
    }

    private static func walkAccessibilityObjects(_ objs: [Any], depth: Int, into out: inout [LCRemoteUIElement]) {
        for obj in objs {
            guard out.count < maxNodes, depth <= maxDepth else { return }
            if let view = obj as? UIView {
                walkView(view, depth: depth, into: &out)
                continue
            }
            guard let info = describe(obj) else { continue }
            out.append(LCRemoteUIElement(index: out.count,
                                         label: info.label, identifier: info.ident,
                                         value: info.value, className: info.cls,
                                         frame: info.frame, isControl: false,
                                         canActivate: info.activatable, depth: depth))
            if let ns = obj as? NSObject, let children = ns.accessibilityElements as? [Any], !children.isEmpty {
                walkAccessibilityObjects(children, depth: depth + 1, into: &out)
            }
        }
    }

    // MARK: - 激活

    private static func object(for index: Int) -> NSObject? {
        var all: [NSObject] = []
        for window in windows {
            collectViewObjects(window, into: &all)
            if let elements = window.accessibilityElements as? [Any] {
                collectA11yObjects(elements, into: &all)
            }
        }
        guard index >= 0, index < all.count else { return nil }
        return all[index]
    }

    private static func collectViewObjects(_ view: UIView, into out: inout [NSObject]) {
        guard out.count < maxNodes else { return }
        guard !view.isHidden, view.alpha > 0.01 else { return }
        if describe(view) != nil { out.append(view) }
        if let elements = view.accessibilityElements as? [Any], !elements.isEmpty {
            collectA11yObjects(elements, into: &out)
        }
        for sub in view.subviews { collectViewObjects(sub, into: &out) }
    }

    private static func collectA11yObjects(_ objs: [Any], into out: inout [NSObject]) {
        for obj in objs {
            guard out.count < maxNodes else { return }
            if let view = obj as? UIView { collectViewObjects(view, into: &out); continue }
            guard let ns = obj as? NSObject, describe(ns) != nil else { continue }
            out.append(ns)
            if let children = ns.accessibilityElements as? [Any], !children.isEmpty {
                collectA11yObjects(children, into: &out)
            }
        }
    }

    /// 按 index 激活；index 来自 /ui/tree
    static func activate(index: Int) -> (ok: Bool, detail: String) {
        guard let obj = object(for: index) else {
            return (false, "index \(index) 不存在，先 GET /api/v1/ui/tree")
        }
        return activate(obj)
    }

    static func activate(label: String, identifier: String) -> (ok: Bool, detail: String) {
        let wanted = label.lowercased()
        let wantIdent = identifier.lowercased()
        for element in tree() {
            let matched = (!wantIdent.isEmpty && element.identifier.lowercased() == wantIdent)
                || (!wanted.isEmpty && (element.label.lowercased() == wanted
                                        || element.label.lowercased().contains(wanted)))
            if matched, let obj = object(for: element.index) {
                let r = activate(obj)
                if r.ok { return r }
            }
        }
        return (false, "没找到可激活的 \(label.isEmpty ? identifier : label)")
    }

    private static func activate(_ obj: NSObject) -> (ok: Bool, detail: String) {
        let name = String(describing: type(of: obj))
        if let control = obj as? UIControl {
            control.sendActions(for: .touchUpInside)
            return (true, "sendActions(.touchUpInside) on \(name)")
        }
        if obj.accessibilityActivate() {
            return (true, "accessibilityActivate on \(name)")
        }
        if let view = obj as? UIView {
            // 点中心，看能不能命中内部控件
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            if let hit = view.hitTest(center, with: nil), hit !== view,
               let r = activateHit(hit) {
                return r
            }
        }
        return (false, "\(name) 不支持激活（没有 accessibilityActivate / UIControl）")
    }

    private static func activateHit(_ hit: UIView) -> (ok: Bool, detail: String)? {
        var node: UIView? = hit
        while let current = node {
            if let control = current as? UIControl {
                control.sendActions(for: .touchUpInside)
                return (true, "sendActions(.touchUpInside) on \(type(of: current))")
            }
            if current.accessibilityActivate() {
                return (true, "accessibilityActivate on \(type(of: current))")
            }
            node = current.superview
        }
        return nil
    }

    // MARK: - 坐标点击

    static func tap(x: CGFloat, y: CGFloat) -> (ok: Bool, detail: String) {
        let point = CGPoint(x: x, y: y)
        for window in windows {
            guard window.bounds.contains(point) else { continue }
            guard let hit = window.hitTest(point, with: nil) else { continue }
            if let r = activateHit(hit) { return r }
            return (false, "命中了 \(type(of: hit)) 但没有可触发控件")
        }
        return (false, "(\(Int(x)),\(Int(y))) 不在任何窗口里")
    }

    // MARK: - Tab

    static func tab(index: Int?) -> (ok: Bool, detail: String) {
        var controllers: [UITabBarController] = []
        for window in windows {
            collectTabBars(window.rootViewController, into: &controllers)
        }
        guard let tabBar = controllers.first else {
            return (false, "没找到 UITabBarController（SwiftUI TabView 有时不是它）")
        }
        guard let index, index >= 0, index < (tabBar.viewControllers?.count ?? 0) else {
            let names = (tabBar.viewControllers ?? []).enumerated().map { "\($0.offset):\($0.element.tabBarItem.title ?? "?")" }
            return (false, "需要 index（0..\((tabBar.viewControllers?.count ?? 1) - 1)），当前 \(names.joined(separator: ", "))")
        }
        tabBar.selectedIndex = index
        return (true, "selectedIndex = \(index)")
    }

    private static func collectTabBars(_ vc: UIViewController?, into out: inout [UITabBarController]) {
        guard let vc else { return }
        if let t = vc as? UITabBarController { out.append(t) }
        for child in vc.children { collectTabBars(child, into: &out) }
        collectTabBars(vc.presentedViewController, into: &out)
    }

    // MARK: - 文本输入

    static func typeText(_ text: String) -> (ok: Bool, detail: String) {
        guard let responder = firstResponder() else {
            return (false, "当前没有第一响应者（先点一下输入框）")
        }
        if let input = responder as? UIKeyInput {
            input.insertText(text)
            return (true, "insertText on \(type(of: responder))")
        }
        if let textField = responder as? UITextField {
            textField.text = (textField.text ?? "") + text
            return (true, "set text on UITextField")
        }
        return (false, "\(type(of: responder)) 不接受文本输入")
    }

    private static func firstResponder() -> UIResponder? {
        for window in windows {
            if let r = findFirstResponder(in: window) { return r }
        }
        return nil
    }

    private static func findFirstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let r = findFirstResponder(in: sub) { return r }
        }
        return nil
    }
}
