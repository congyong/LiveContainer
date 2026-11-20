//
//  LCRemoteSettingsView.swift
//  LiveContainerSwiftUI
//
//  远程控制（HTTP API）设置页：开关 / 端口 / token / 用法。
//

import SwiftUI
import UIKit

struct LCRemoteSettingsView: View {
    @AppStorage("LCRemoteEnabled", store: LCUtils.appGroupUserDefault) private var enabled: Bool = false
    @AppStorage("LCRemotePort", store: LCUtils.appGroupUserDefault) private var port: Int = 8848

    @State private var token: String = LCRemoteConfig.token
    @State private var portText: String = ""
    @State private var statusText: String = ""
    @State private var errorText: String?

    private var keepAliveMode: LCRemoteKeepAliveMode {
        LCRemoteKeepAliveMode.stored
    }

    private var keepAliveBinding: Binding<LCRemoteKeepAliveMode> {
        Binding(get: { LCRemoteKeepAliveMode.stored },
                set: { newValue in
                    LCRemoteKeepAlive.shared.apply(newValue)
                    refreshStatus()
                })
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 HTTP 服务", isOn: $enabled)
                    .onChange(of: enabled) { newValue in
                        LCRemoteControl.shared.applyEnabled(newValue)
                        refreshStatus()
                    }

                HStack {
                    Text("监听端口")
                    Spacer()
                    TextField("8848", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                    Button("应用") { applyPort() }
                        .buttonStyle(.borderless)
                        .disabled(Int(portText) == nil || Int(portText) == port)
                }

                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(LCRemoteControl.shared.isRunning ? .green : .secondary)
                }
            } header: {
                Text("远程控制")
            } footer: {
                Text("服务只在 LiveContainer 处于前台时保持监听；切到后台后 iOS 会挂起进程，请求会超时。\n端口范围 1024–65535，改端口后自动重启服务。")
            }

            Section {
                Picker("保活方式", selection: keepAliveBinding) {
                    ForEach(LCRemoteKeepAliveMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("后台保活")
            } footer: {
                Text("iOS 挂起进程时 socket 会断。\"静音音频\"靠 UIBackgroundModes: audio 让进程锁屏后继续跑（耗电，且可能与 guest app 音频混流）；\"屏幕常亮\"配合\"引导式访问\"(设置 → 辅助功能) 是最省心的长期挂机方案。")
            }

            Section {
                Text(token)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("复制 token") {
                        UIPasteboard.general.string = token
                    }
                    Spacer()
                    Button("重新生成", role: .destructive) {
                        token = LCRemoteConfig.regenerateToken()
                        LCRemoteControl.shared.restart()
                        refreshStatus()
                    }
                }
            } header: {
                Text("Token")
            } footer: {
                Text("所有请求都要带 Authorization: Bearer <token>（/api/v1/health 除外）。重新生成会让已连上的客户端立刻失效。")
            }

            Section {
                Text("""
                curl http://<设备IP>:\(port)/api/v1/health
                curl -H 'Authorization: Bearer \(token)' \\
                  http://<设备IP>:\(port)/api/v1/apps
                curl -H 'Authorization: Bearer \(token)' \\
                  -F 'file=@app.ipa' \\
                  http://<设备IP>:\(port)/api/v1/apps
                curl -H 'Authorization: Bearer \(token)' \\
                  'http://<设备IP>:\(port)/api/v1/logs?since=0&limit=200'
                """)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            } header: {
                Text("用法")
            }

            if let errorText {
                Section {
                    Text(errorText).foregroundColor(.red)
                }
            }
        }
        .navigationTitle("远程控制")
        .onAppear {
            portText = String(port)
            token = LCRemoteConfig.token
            refreshStatus()
        }
    }

    private func applyPort() {
        guard let v = Int(portText), v >= 1024, v <= 65535 else {
            errorText = "端口必须在 1024–65535 之间"
            return
        }
        errorText = nil
        LCRemoteConfig.port = UInt16(v)
        LCRemoteControl.shared.restart()
        refreshStatus()
    }

    private func refreshStatus() {
        let control = LCRemoteControl.shared
        if !LCRemoteConfig.isEnabled {
            statusText = "已关闭"
        } else if control.isRunning {
            statusText = "运行中 :\(control.boundPort)"
        } else {
            statusText = "未运行"
        }
        if let err = control.lastError {
            errorText = err
        }
    }
}
