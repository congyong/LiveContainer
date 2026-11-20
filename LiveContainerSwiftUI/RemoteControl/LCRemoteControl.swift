//
//  LCRemoteControl.swift
//  LiveContainerSwiftUI
//
//  服务生命周期 + 单例门面。AppDelegate 启动时调用 startIfEnabled()。
//

import Foundation
import UIKit

@MainActor
final class LCRemoteControl {
    static let shared = LCRemoteControl()

    private var server: LCRemoteHTTPServer?
    private(set) var lastError: String?

    private init() {}

    var isRunning: Bool { server?.isRunning ?? false }
    var boundPort: UInt16 { server?.boundPort ?? 0 }
    var isEnabled: Bool { LCRemoteConfig.isEnabled }

    func startIfEnabled() {
        guard LCRemoteConfig.isEnabled else { return }
        do {
            try start()
        } catch {
            lastError = error.localizedDescription
            LCRemoteLogStore.shared.append("start failed: \(error.localizedDescription)", src: "api")
        }
    }

    func start() throws {
        stop()
        LCRemoteLogStore.shared.installCapture()
        let srv = LCRemoteHTTPServer { req in
            await LCRemoteAPI.handle(req)
        }
        srv.onLog = { msg in
            LCRemoteLogStore.shared.append(msg, src: "api")
        }
        try srv.start(port: LCRemoteConfig.port)
        server = srv
        lastError = nil
        // 服务起来后按设置恢复保活（静音音频 / 屏幕常亮）
        LCRemoteKeepAlive.shared.restore()
        LCRemoteLogStore.shared.append("remote control started on :\(LCRemoteConfig.port)", src: "api")
    }

    func stop() {
        server?.stop()
        server = nil
        LCRemoteKeepAlive.shared.apply(.off)
    }

    func restart() {
        stop()
        guard LCRemoteConfig.isEnabled else { return }
        try? start()
    }

    func applyEnabled(_ enabled: Bool) {
        LCRemoteConfig.isEnabled = enabled
        if enabled {
            restart()
        } else {
            stop()
        }
    }

    /// 前台/后台切换时保活：iOS 允许前台时保持监听
    func installLifecycleHooks() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, LCRemoteConfig.isEnabled, !self.isRunning else { return }
                self.startIfEnabled()
            }
        }
    }
}
