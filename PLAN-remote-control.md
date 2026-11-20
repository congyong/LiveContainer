# LiveContainer + 远程调试服务（app 内 HTTP API / MCP）

目标：把一台装了 LiveContainer 的 iPhone 变成可远程操控的调试机 —— 装/卸沙盒 IPA、导入并启停 dylib、拉日志。

## 结论先说

可行性高，且不需要改 LiveContainer 的核心逻辑：它的安装/签名/日志能力已经全部是现成的 Swift/ObjC 方法，
我们做的是**把 UI 背后的动作抽成 service，再包一层 HTTP**。

两处真实难点（不是能不能做，是要不要付代价）：

1. **后台常驻**：iPhone 上一旦 LiveContainer 被挂起，socket 就断。要长期在线必须靠 `UIBackgroundModes: audio`
   + 静音音频循环保活（越狱机可换 launchd 守护）。这会改变 app 的 Info.plist 行为，且耗电。
2. **构建环境**：上游 CI 用自建 `xcode-27` runner + Xcode 27.2；GitHub 托管 runner 目前只有 Xcode 26.x。
   要在我们自己的 fork 里出 IPA，得先确认 Xcode 版本够不够（或砍掉 iOS 26 专属分支）。

## 代码落点（已核对本仓库）

| 能力 | 现有实现 | 复用方式 |
|---|---|---|
| 应用列表 | `LiveContainerSwiftUI/Utilities/Shared.swift:71` `SharedModel.apps` | 直接读（需在主线程/actor 上） |
| 路径约定 | `Shared.swift:14` `LCPath.bundlePath / dataPath / tweakPath` | 直接用 |
| IPA 安装 | `Views/AppList/LCAppListView.swift:590 installIpaFile` | **抽成 `LCAppInstaller`**，UI 与 API 共用 |
| 卸载 | `Views/AppList/LCAppBanner/LCAppBannerViewController.swift:246 uninstall()` | 抽成 `LCAppUninstaller` |
| 签名 | `Utilities/LCUtils.h` `+signAppBundleWithZSign:` / `+signFilesWithZSignWithURLs:` | 直接调 |
| 启动 App | `Models/LCAppModel.swift:225 runApp(...)` | 需在 UI 上下文调用；走 `@MainActor` |
| Tweak 列表/签名 | `Views/LCTweaksView.swift`（TweakInfo.plist + `LCUtils.signTweaks(tweakFolderUrl:force:)`） | 抽成 `LCTweakManager` |
| 解压 | `Utilities/unarchive.h` `extract(path,destination,progress)` | 直接用 |

## 模块设计

新增 `RemoteControl/`（加入 LiveContainerSwiftUI target），全部不引第三方依赖：

```
RemoteControl/
  LCRemoteServer.swift      NWListener + 极简 HTTP/1.1（keep-alive、chunked 读、multipart 解析）
  LCRemoteRouter.swift      路由表 + Bearer token 鉴权 + 统一错误 JSON
  LCRemoteLogStore.swift    dup2(pipe)/NSLog 捕获 → 环形缓冲（内存 5k 条）+ SSE 广播
  LCAppInstaller.swift      从 LCAppListView 抽出（不依赖 SwiftUI）
  LCAppUninstaller.swift    从 LCAppBannerViewController 抽出
  LCTweakManager.swift      tweak 导入/启用/删除 + signTweaks
  Models.swift              请求/响应 DTO
```

设置页加一个开关 + 端口 + token（token 默认随机生成写 UserDefaults，**默认关闭**）。

## API（v1）

鉴权：`Authorization: Bearer <token>`。所有响应 JSON，错误 `{"error":{"code":..,"message":..}}`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/health` | 版本、设备、端口、存活 |
| GET | `/api/v1/apps` | 已装应用：bundleId、名字、版本、路径、是否 hidden、容器列表 |
| POST | `/api/v1/apps` | 上传 IPA（`multipart/form-data` 或裸 body + `X-Filename`）→ 安装，返回 bundleId |
| DELETE | `/api/v1/apps/{bundleId}` | 卸载（`?keepData=1` 保留数据容器） |
| POST | `/api/v1/apps/{bundleId}/launch` | 启动（可带 `container=`、`url=`） |
| POST | `/api/v1/apps/{bundleId}/stop` | 结束进程 |
| GET | `/api/v1/tweaks` | 全局与各 folder 下的 dylib + 启用状态 |
| POST | `/api/v1/tweaks` | 上传 dylib（可指定 folder）→ 落盘 + ZSign 重签 |
| PATCH | `/api/v1/tweaks/{id}` | `{"enabled":true/false}` |
| DELETE | `/api/v1/tweaks/{id}` | 删除 |
| GET | `/api/v1/logs?since=<seq>&limit=` | 拉增量日志（进程内环形缓冲） |
| GET | `/api/v1/logs/stream` | SSE 实时流（`text/event-stream`） |
| GET | `/api/v1/fs?path=` | 只读列目录/取文件（可选，限沙盒内） |

MCP 不放在设备上：设备只出 REST，另在 robo 上放一个零依赖 MCP 桥（单文件 python，stdio→REST），
符合"客户端零依赖、服务端出 HTTP 端点"的既有偏好。工具集：`lc_list_apps` / `lc_install_ipa` /
`lc_uninstall_app` / `lc_launch_app` / `lc_tweaks` / `lc_tweak_toggle` / `lc_logs` / `lc_log_stream`。

## 日志捕获（关键细节）

- `dup2(pipe, STDERR_FILENO)` + `DispatchSourceRead`：拿到 NSLog / fprintf / Swift `print`（stderr）输出，
  这些正是 LiveContainer 与 guest app 在同一进程时的日志来源。
- `os_log` 走统一日志，不进 stderr：需要 fishhook swizzle `_os_log_impl`（仓库已有 fishhook/litehook 子模块）。
- 每条记录 `{seq, ts, level, tag, msg}`；`seq` 单调递增，供 `since` 增量拉取；同时落盘 `Documents/RemoteControl/logs.jsonl`（轮转 10MB）。
- 只读 API 不阻塞业务：ring buffer 用 `os_unfair_lock`，SSE 用后台队列写。

## 已完成（可验证）

- S1 server + token + /health + /apps(GET) + /logs(+长轮询)
- S2 POST/DELETE /apps（LCAppInstaller，ZSign 签名后进 sharedModel）
- S3 tweak：GET/POST/PATCH/DELETE /api/v1/tweaks、/tweaks/sign、/tweakfolders（启用=去 `.disabled` 后缀）
- S4 POST /apps/{id}/launch（LCAppModel.runApp，可指定 container / url）
- S5 GET /api/v1/windows、POST /api/v1/windows/{id}/{scale|pip|maximize|close}、
     GET /api/v1/screenshot（JPEG，可指定窗口/质量/最大宽度）
- MCP 桥 15 个工具：health/apps/install/uninstall/launch/tweaks(5)/logs/windows/window_action/screenshot

## 分阶段（原始计划，保留）

- **S1**：server + token + `/health` + `/apps`(GET) + `/logs` + SSE。目标：`curl` 通，能看日志。
- **S2**：`LCAppInstaller` 抽取 + `POST /apps` + `DELETE /apps`。目标：`curl -F file=@x.ipa` 装上、卸掉。
- **S3**：`LCTweakManager` + tweaks 三个端点。目标：上传 dylib 后 app 内 Tweaks 页能看到且已签名。
- **S4**：launch/stop + 启动后按 bundleId 过滤日志。
- **S5**：MCP 桥 + 保活（audio 背景模式）+ 文档。

## 已确认的构建/分发前提

- 产物仍是未签名或自签 IPA，侧载方式与现在一致（Sideloadly / SideStore / TrollStore）。
- 若要 TrollStore 免签安装，需在 `entitlements.xml` 里加 `platform-application` 等（后续单独评估）。

## 待定（需要你拍板）

1. fork 落在哪个仓库（congyong/LiveContainer？），CI 能否用你的 GitHub 账号跑 macOS runner。
2. 后台常驻是否接受 `UIBackgroundModes: audio`（不改就只有 app 在前台时在线）。
3. 先只做 S1+S2（能远程装/卸 + 看日志）还是五阶段一次做完。
