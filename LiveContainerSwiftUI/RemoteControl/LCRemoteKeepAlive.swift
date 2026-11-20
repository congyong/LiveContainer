//
//  LCRemoteKeepAlive.swift
//  LiveContainerSwiftUI
//
//  远程服务保活。iOS 一挂起 socket 就断，这里给几种办法：
//   - audio      : 静音音频循环（已声明 UIBackgroundModes: audio），锁屏/切后台仍在线
//   - screenAwake: isIdleTimerDisabled，配合"引导式访问"可以一直前台
//   - 两者叠加
//
//  Info.plist 里本来就有 audio / location / voip / processing 等背景模式，
//  所以音频方案不需要改工程配置。真机长期挂机更稳的组合见 README/PLAN：
//  引导式访问 + 自动锁定永不 + screenAwake。
//

import AVFoundation
import UIKit

enum LCRemoteKeepAliveMode: String, CaseIterable, Identifiable {
    case off
    case audio
    case screenAwake
    case audioAndScreen

    var id: String { rawValue }

    var usesAudio: Bool { self == .audio || self == .audioAndScreen }
    var keepsScreenOn: Bool { self == .screenAwake || self == .audioAndScreen }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .audio: return "静音音频（锁屏也在线）"
        case .screenAwake: return "屏幕常亮"
        case .audioAndScreen: return "静音音频 + 屏幕常亮"
        }
    }

    static let defaultsKey = "LCRemoteKeepAlive"

    /// 默认值就是 .audio：远程服务一开就带静音音频保活，用户不用再手动选。
    static var stored: LCRemoteKeepAliveMode {
        get {
            if let raw = LCUtils.appGroupUserDefault.string(forKey: defaultsKey),
               let mode = LCRemoteKeepAliveMode(rawValue: raw) {
                return mode
            }
            return .audio
        }
        set { LCUtils.appGroupUserDefault.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

@MainActor
final class LCRemoteKeepAlive {
    static let shared = LCRemoteKeepAlive()

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private(set) var mode: LCRemoteKeepAliveMode = .off

    private init() {}

    func apply(_ mode: LCRemoteKeepAliveMode) {
        self.mode = mode
        LCRemoteKeepAliveMode.stored = mode

        if mode.usesAudio {
            startAudio()
        } else {
            stopAudio()
        }
        UIApplication.shared.isIdleTimerDisabled = mode.keepsScreenOn
        LCRemoteLogStore.shared.append("keepalive -> \(mode.rawValue)", src: "api")
    }

    /// 停服时用：只停音频/屏幕常亮，**不改**用户选的偏好
    func suspend() {
        stopAudio()
        UIApplication.shared.isIdleTimerDisabled = false
        LCRemoteLogStore.shared.append("keepalive suspended (mode stays \(mode.rawValue))", src: "api")
    }

    func restore() {
        apply(LCRemoteKeepAliveMode.stored)
    }

    /// 状态给 API 用
    var status: [String: Any] {
        ["mode": mode.rawValue,
         "audioPlaying": player?.isPlaying ?? false,
         "idleTimerDisabled": UIApplication.shared.isIdleTimerDisabled]
    }

    // MARK: - 静音音频

    private func startAudio() {
        if let player, player.isPlaying { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers：别把 guest app 自己的声音掐掉
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let p = try AVAudioPlayer(data: LCRemoteKeepAlive.silentWAV(seconds: 2))
            p.numberOfLoops = -1
            p.volume = 0.05
            p.prepareToPlay()
            p.play()
            player = p

            if interruptionObserver == nil {
                interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: nil, queue: .main) { [weak self] note in
                        guard let self else { return }
                        let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
                        if raw == AVAudioSession.InterruptionType.ended.rawValue {
                            Task { @MainActor in
                                if self.mode.usesAudio { self.restartAudio() }
                            }
                        }
                    }
            }
        } catch {
            LCRemoteLogStore.shared.append("keepalive audio failed: \(error.localizedDescription)", src: "api")
        }
    }

    private func restartAudio() {
        player?.stop()
        player = nil
        startAudio()
    }

    private func stopAudio() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - 生成静音 WAV（44 字节头 + 全零 PCM）

    static func silentWAV(seconds: Double, sampleRate: Int = 8000) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let frames = Int(Double(sampleRate) * max(0.5, seconds))
        let dataBytes = frames * channels * bitsPerSample / 8

        var d = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                                        // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * bitsPerSample / 8))  // byte rate
        append16(UInt16(channels * bitsPerSample / 8))     // block align
        append16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))
        return d
    }
}
