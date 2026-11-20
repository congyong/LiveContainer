# MCP / HTTP 远程控制

> **LiveContainer 是开源项目**（AGPL-3.0，上游：https://github.com/LiveContainer/LiveContainer ）。
> 本文档描述的是其功能分支 `remote-control` 新增的能力：在 App 内跑一个带鉴权的 HTTP 服务，
> 把「装包 / 启动 / 窗口 / 界面点击 / 截图 / tweak / 日志」暴露成接口，并附带一层 MCP 桥，
> 让 Claude、Hermes 等 agent 直接操控这台 iPhone。
>
> 本分支的全部改动同样以 **AGPL-3.0** 发布，与上游项目无隶属关系，仅在其之上扩展。
> 设备侧只跑 HTTP（无第三方依赖）；MCP 桥是单文件 Python（仅标准库）。

## 架构

```
MCP 客户端（Claude / Hermes / …） ──stdio──▶ tools/mcp/lc_mcp.py ──HTTP + Bearer──▶ 设备 :8848（LiveContainer 进程内）
```

## 一、准备（设备侧）

1. 侧载 `LiveContainer-remote.ipa`（未签名包，用你自己的证书签名；**安装时务必保留 App Extensions**，
   否则启动 App 会报 `LiveProcess extension not found`）
2. App 内：设置 → 远程控制 → 打开「启用 HTTP 服务」
   - 端口默认 8848（可改）
   - 保活方式建议「静音音频（锁屏也在线）」
   - 复制页面上的 **token**
3. 设备与电脑网络互通（同一 Wi-Fi，或用 Tailscale）

## 二、准备（电脑侧）

把 `tools/mcp/lc_mcp.py` 拷到任意目录，配置两个环境变量即可：

| 变量 | 说明 |
|---|---|
| `LC_REMOTE_URL` | 设备地址，如 `http://192.168.1.8:8848` 或 `http://100.x.y.z:8848` |
| `LC_REMOTE_TOKEN` | 设备「远程控制」页显示的 token |

**MCP 客户端配置示例**（JSON 风格）

```json
{
  "mcpServers": {
    "livecontainer": {
      "command": "python3",
      "args": ["/path/to/tools/mcp/lc_mcp.py"],
      "env": {
        "LC_REMOTE_URL": "http://192.168.1.8:8848",
        "LC_REMOTE_TOKEN": "<token>"
      }
    }
  }
}
```

自检（不需要设备）：

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | python3 lc_mcp.py
```

## 三、工具清单（32 个）

### 设备 / 安装 / 启动

| 工具 | 参数 | 说明 |
|---|---|---|
| `lc_health` | — | 探活，返回版本与端口（唯一不需要 token 的接口） |
| `lc_apps` | — | 列出已安装 App（bundleId、名字、版本、容器、是否隐藏） |
| `lc_install_ipa` | `ipa_path`, `replace?` | 从本机上传 .ipa 安装 |
| `lc_install_from_url` | `url`, `replace?` | 让**设备自己下载**再安装，立即返回 `jobId`（大包/弱网推荐，不受长连接超时影响） |
| `lc_jobs` | `job_id?` | 查异步任务状态；省略则列最近任务 |
| `lc_uninstall_app` | `bundle_id`, `keep_data?` | 卸载，`keep_data=true` 保留数据容器 |
| `lc_launch_app` | `bundle_id`, `container?`, `url?`, `multitask?` | 启动 App。`multitask=true` 在容器内小窗运行（远程调试建议用它，否则容器进程会让位给 guest，服务会短暂掉线） |

### Tweak（dylib / framework）

| 工具 | 参数 | 说明 |
|---|---|---|
| `lc_tweaks` | `folder?` | 列出 tweak 及启用状态、签名信息（cdhash/sigSize） |
| `lc_tweak_import` | `path`, `folder?` | 上传 .dylib 或 .framework(zip)，落盘并补 rpath |
| `lc_tweak_toggle` | `name`, `enabled`, `folder?` | 启用/停用（设备侧是加/去 `.disabled` 后缀） |
| `lc_tweak_sign` | `folder?`, `force?` | ZSign 重签，返回每个文件 before/after cdhash、`changedCount`；`changedCount=0` 说明证书载入失败 |
| `lc_tweak_delete` | `name`, `folder?` | 删除 tweak |
| `lc_tweak_folder` | `name` | 新建 tweak 子目录（给单个 App 专用） |

### 多任务窗口

| 工具 | 参数 | 说明 |
|---|---|---|
| `lc_windows` | — | 列出小窗：id(dataUUID)、bundleId、pid、scale、maximized、frame、running |
| `lc_window_action` | `id`, `action`, `scale?`, `enabled?` | `action` ∈ `scale`(0.4–3.0) / `pip`(收成小窗·还原) / `maximize` / `close` |

### 界面自测（UI 自动化）

| 工具 | 参数 | 说明 |
|---|---|---|
| `lc_ui_tree` | — | 导出可访问性树：label / identifier / frame / 是否可激活 |
| `lc_ui_activate` | `index?` / `label?` / `identifier?` | 点一下元素（SwiftUI 走 accessibilityActivate，UIKit 走 sendActions） |
| `lc_ui_tap` | `x`, `y` | 按屏幕坐标点击（逻辑 point，可直接用 ui_tree 里的 frame 中心） |
| `lc_ui_taps` | `steps[]`, `detect_change?`, `capture_after?` | **连续点击序列**：每步 label / index / 坐标任意组合，可设 delayMs；回报每步画面是否变化，可选跑完截图 |
| `lc_ui_tab` | `index?` / `name?` | 切底部 Tab（源 / App / 模块 / 设置） |
| `lc_ui_text` | `text` | 给当前输入框输入文本（先 activate/tap 点中它） |
| `lc_screenshot` | `window_id?`, `out_path?`, `quality?`, `max_width?` | 截图成 JPEG 存到本机并返回路径；省略 window_id 截整个界面 |

### 界面自测 · guest App 内部（走 LiveProcess 里的 sidecar）

| 工具 | 参数 | 说明 |
| --- | --- | --- |
| `lc_guest_info` | — | guest 进程信息：bundleId / pid / 屏幕尺寸 |
| `lc_guest_tree` | — | guest App 自己的可访问性树（能看到 App 内部按钮） |
| `lc_guest_activate` | `index?` / `label?` / `identifier?` / `x,y` | 点 guest App 内部元素 |
| `lc_guest_taps` | `steps[]`, `detect_change?` | guest 内部连续点击，回报每步画面是否变化 |
| `lc_guest_text` | `text` | 给 guest 内部输入框输入文本 |
| `lc_guest_screenshot` | `max_width?`, `quality?`, `out_path?` | 截 guest App 自己的画面（不受跨进程合成影响） |

### 日志

| 工具 | 参数 | 说明 |
|---|---|---|
| `lc_logs` | `since?`, `limit?`, `wait?` | LiveContainer 自身进程日志（增量 + 长轮询） |
| `lc_guest_logs` | `name?`, `offset?`, `limit?` | **Guest App 与注入 tweak 的日志**；省略 name 列文件，给了 name 按字节续读（返回 `next`） |
| `lc_guest_logs_clear` | `name?` | 删除日志文件（省略清空） |

### 保活

| 工具 | 参数 | 说明 |
|---|---|---|
| `lc_keepalive` | `mode` | `off` / `audio`（静音音频，锁屏也在线，默认）/ `screenAwake` / `audioAndScreen` |

## 四、常用组合

**装包 → 启动 → 看画面**
```
lc_install_from_url {url, replace:true} → lc_jobs {job_id} 轮询到 done
→ lc_launch_app {bundle_id, multitask:true} → lc_screenshot
```

**界面自测闭环**
```
lc_ui_tree → 找到目标 label/index
→ lc_ui_activate {label:"启动"}（或 lc_ui_tap {x,y}）
→ lc_screenshot 验证画面变化
→ lc_guest_logs 看 App / tweak 的 NSLog
```

**装 tweak 并确认真的签上了**
```
lc_tweak_folder {name:"shark"}
lc_tweak_import {path:"/tmp/BlockNetPlus-arm64.dylib", folder:"shark"}
lc_tweak_sign {folder:"shark", force:true}   // 看 changedCount 是否 > 0
lc_tweaks {folder:"shark"}                   // 看 signature.cdhash
```

**装完 ipa 做内部点击自测**
```
lc_ui_taps {steps:[
  {label:"启动"},
  {x:200, y:520, delayMs:1500, note:"进首页"},
  {x:120, y:300, delayMs:800,  note:"点第一个入口"},
  {x:340, y:820, delayMs:800,  note:"点底部按钮"}
], detect_change:true, capture_after:true}
→ 返回每步 ok / changed，以及截图路径
```

## 五、设备端 REST（不用 MCP 也能直接 curl）

除 `/api/v1/health` 外都要 `Authorization: Bearer <token>`。

```
GET    /api/v1/health
GET    /api/v1/config
GET    /api/v1/self                     # bundle / PlugIns(.appex) / Frameworks，排查装包问题
GET    /api/v1/apps
POST   /api/v1/apps                     # multipart 或裸 body 上传 ipa
POST   /api/v1/apps/from-url            # {url, replace} → 202 jobId
DELETE /api/v1/apps/{bundleId}?keepData=1
POST   /api/v1/apps/{bundleId}/launch?container=&url=&multitask=1
GET    /api/v1/jobs   /api/v1/jobs/{id}
GET    /api/v1/tweaks?folder=
POST   /api/v1/tweaks?folder=           # multipart 上传 dylib
PATCH  /api/v1/tweaks                   # {name, enabled, folder}
DELETE /api/v1/tweaks?name=&folder=
POST   /api/v1/tweaks/sign?folder=&force=1
POST   /api/v1/tweakfolders             # {name}
GET    /api/v1/windows
POST   /api/v1/windows/{id}/{scale|pip|maximize|close}
GET    /api/v1/screenshot?windowId=&quality=&maxWidth=
GET    /api/v1/guest/info                              # 代理到 guest 进程 sidecar(127.0.0.1:8850)
GET    /api/v1/guest/ui/tree
POST   /api/v1/guest/ui/{activate|tap|taps|text}
GET    /api/v1/guest/screenshot?maxWidth=&quality=
GET    /api/v1/ui/tree
POST   /api/v1/ui/{activate|tap|tab|text}
GET    /api/v1/logs?since=&limit=&wait=
GET    /api/v1/logs/guest[?name=&offset=&limit=]
DELETE /api/v1/logs/guest[?name=]
POST   /api/v1/keepalive                # {mode}
```

## 六、已知限制

- 服务只在 **LiveContainer 前台 / 由 audio 保活维持**时在线；被系统挂起时请求会超时。
- 容器侧截图取进程内合成结果，guest 窗口可能是黑块 → 改用 `lc_guest_screenshot`（在 guest 进程内渲染）。
- guest 内部点击依赖 `lc_launch_app(..., multitask:true)`：非多任务模式下容器进程会让位给 guest，主服务会掉线。
- `lc_guest_logs` 只覆盖 stderr/stdout（NSLog / printf / Swift print），单独 `os_log()` 的日志不在其中。
- 启动 guest App 若未保留 App Extensions，会报 `LiveProcess extension not found`（重签时勾选 Keep Extensions）。
- tweak 必须由设备侧证书重签后才会被加载；`lc_tweak_sign` 的 `changedCount=0` 即代表证书不可用（p12 密码错/过期）。
