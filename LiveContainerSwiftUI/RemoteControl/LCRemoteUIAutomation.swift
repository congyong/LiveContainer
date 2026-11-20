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

    /// 单一遍历入口：tree() 和 activate(index:) 必须用同一套顺序，index 才对得上。
    /// 用 ObjectIdentifier 去重 —— 同一批 SwiftUI 节点会同时出现在 view.subviews 和
    /// accessibilityElements 里，不去重会出现同一个 label 重复 4 次、600 上限被瞬间打满。
    private static func collect() -> [NSObject] {
        var out: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        for window in windows() {
            walk(window, depth: 0, visited: &visited, into: &out)
        }
        return out
    }

    private static func isInteresting(_ ns: NSObject) -> Bool {
        if !(ns.accessibilityLabel ?? "").isEmpty { return true }
        if !(((ns as? UIAccessibilityIdentification)?.accessibilityIdentifier) ?? "").isEmpty { return true }
        if !(ns.accessibilityValue ?? "").isEmpty { return true }
        if ns is UIControl { return true }
        return ns.accessibilityTraits.contains(.button) || ns.accessibilityTraits.contains(.link)
    }

    private static func walk(_ obj: Any, depth: Int, visited: inout Set<ObjectIdentifier>, into out: inout [NSObject]) {
        guard out.count < maxNodes, depth <= maxDepth, let ns = obj as? NSObject else { return }
        guard visited.insert(ObjectIdentifier(ns)).inserted else { return }

        if isInteresting(ns) { out.append(ns) }

        if let view = ns as? UIView {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            for sub in view.subviews { walk(sub, depth: depth + 1, visited: &visited, into: &out) }
        }
        if let elements = ns.accessibilityElements as? [Any] {
            for element in elements { walk(element, depth: depth + 1, visited: &visited, into: &out) }
        }
    }

    static func tree() -> [LCRemoteUIElement] {
        var out: [LCRemoteUIElement] = []
        for (index, ns) in collect().enumerated() {
            let label = ns.accessibilityLabel ?? ""
            let ident = (ns as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
            let value = ns.accessibilityValue ?? ""
            var frame = CGRect.zero
            if let view = ns as? UIView {
                frame = view.convert(view.bounds, to: nil)
            } else {
                frame = ns.accessibilityFrame
            }
            let activatable = ns is UIControl
                || ns.accessibilityTraits.contains(.button)
                || ns.accessibilityTraits.contains(.link)
                || ns.accessibilityTraits.contains(.tabBar)
            out.append(LCRemoteUIElement(index: index, label: label, identifier: ident,
                                         value: value, className: String(describing: type(of: ns)),
                                         frame: frame, isControl: ns is UIControl,
                                         canActivate: activatable, depth: 0))
        }
        return out
    }

    // MARK: - 激活

    private static func object(for index: Int) -> NSObject? {
        let all = collect()
        guard index >= 0, index < all.count else { return nil }
        return all[index]
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
        var tried = 0
        var lastDetail = ""
        for element in tree() {
            let matched = (!wantIdent.isEmpty && element.identifier.lowercased() == wantIdent)
                || (!wanted.isEmpty && (element.label.lowercased() == wanted
                                        || element.label.lowercased().contains(wanted)))
            guard matched else { continue }
            tried += 1
            if let obj = object(for: element.index) {
                let r = activate(obj)
                if r.ok { return r }
                lastDetail = r.detail
            }
        }
        let name = label.isEmpty ? identifier : label
        if tried == 0 {
            return (false, "树里没有 \(name)（先 GET /api/v1/ui/tree 看 label）")
        }
        return (false, "匹配到 \(tried) 个 \(name)，但都激活不了：\(lastDetail)")
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
        if !(obj is UIView) {
            // SwiftUI 的行/按钮常常只以 AccessibilityNode 出现（不是 UIView），
            // accessibilityActivate 不认，只能按它自己的 frame 中心点一下。
            let f = obj.accessibilityFrame
            if f.width > 1, f.height > 1 {
                let r = tap(x: f.midX, y: f.midY)
                if r.ok { return (true, r.detail + " (a11y frame center)") }
                return (false, "a11y 节点不能直接激活，按 frame 点击也失败: \(r.detail)")
            }
        }
        return (false, "\(name) 不支持激活（没有 accessibilityActivate / UIControl，frame 也拿不到）")
    }

    private static func activateHit(_ hit: UIView) -> (ok: Bool, detail: String)? {
        var node: UIView? = hit
        while let current = node {
            if let field = current as? UITextField {
                field.becomeFirstResponder()
                return (true, "becomeFirstResponder on \(type(of: current))")
            }
            if let textView = current as? UITextView {
                textView.becomeFirstResponder()
                return (true, "becomeFirstResponder on \(type(of: current))")
            }
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
        for window in windows() {
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
        for window in windows() {
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
        for window in windows() {
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
