#!/usr/bin/env python3
"""LiveContainer 远程控制 MCP 桥（stdio → HTTP API）。

零依赖，只用标准库。设备侧只跑 REST，MCP 放在这头，符合"客户端零依赖"的偏好。

用法（在 MCP 客户端里注册，例如 Hermes 的 mcp_servers）：
    command: python3
    args: ["/home/congyong/workspace/lc-mcp/lc_mcp.py"]
    env:
      LC_REMOTE_URL:   http://100.x.y.z:8848      # 设备的 tailnet IP
      LC_REMOTE_TOKEN: <设备上 设置 → 远程控制 里显示的 token>

自检（不需要设备）：
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | python3 lc_mcp.py
"""

import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import quote
import uuid

SERVER_NAME = "livecontainer-remote"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"

BASE = os.environ.get("LC_REMOTE_URL", "").rstrip("/")
TOKEN = os.environ.get("LC_REMOTE_TOKEN", "")
TIMEOUT = float(os.environ.get("LC_REMOTE_TIMEOUT", "300"))


# ── HTTP ────────────────────────────────────────────────────────────────────
def _request(method, path, data=None, content_type=None, timeout=None):
    if not BASE:
        raise RuntimeError("未设置 LC_REMOTE_URL（例如 http://<设备IP>:8848）")
    url = BASE + path
    req = urllib.request.Request(url, data=data, method=method)
    if TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=timeout or TIMEOUT) as resp:
            body = resp.read()
            ctype = resp.headers.get("Content-Type", "")
            if "json" in ctype:
                return json.loads(body or b"{}")
            return body
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None


def api_get(path):
    return _request("GET", path)


def api_delete(path):
    return _request("DELETE", path)


def api_upload(path, filepath):
    """multipart/form-data 上传单个文件。"""
    boundary = "----lcmcp" + uuid.uuid4().hex
    filename = os.path.basename(filepath)
    ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    with open(filepath, "rb") as fh:
        payload = fh.read()
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {ctype}\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    body = head + payload + tail
    return _request("POST", path, data=body,
                    content_type=f"multipart/form-data; boundary={boundary}")


# ── 工具实现 ────────────────────────────────────────────────────────────────
def tool_health(_args):
    return api_get("/api/v1/health")


def tool_apps(_args):
    return api_get("/api/v1/apps")


def tool_install(args):
    path = args.get("ipa_path", "")
    if not os.path.isfile(path):
        raise RuntimeError(f"找不到文件: {path}")
    replace = "1" if args.get("replace", True) else "0"
    return api_upload(f"/api/v1/apps?replace={replace}", path)


def tool_uninstall(args):
    bundle_id = args.get("bundle_id", "")
    if not bundle_id:
        raise RuntimeError("需要 bundle_id")
    keep = "1" if args.get("keep_data", False) else "0"
    return api_delete(f"/api/v1/apps/{urllib.parse.quote(bundle_id)}?keepData={keep}")


def tool_logs(args):
    since = int(args.get("since", 0))
    limit = int(args.get("limit", 200))
    wait = int(args.get("wait", 0))
    return api_get(f"/api/v1/logs?since={since}&limit={limit}&wait={wait}")


def tool_launch(args):
    bundle_id = args.get("bundle_id", "")
    if not bundle_id:
        raise RuntimeError("需要 bundle_id")
    qs = []
    if args.get("container"):
        qs.append("container=" + urllib.parse.quote(args["container"]))
    if args.get("url"):
        qs.append("url=" + urllib.parse.quote(args["url"], safe=""))
    if args.get("multitask") is not None:
        qs.append("multitask=" + ("1" if args["multitask"] else "0"))
    suffix = ("?" + "&".join(qs)) if qs else ""
    return _request("POST", f"/api/v1/apps/{urllib.parse.quote(bundle_id)}/launch{suffix}")


def tool_tweaks(args):
    folder = args.get("folder")
    q = ("?folder=" + urllib.parse.quote(folder)) if folder else ""
    return api_get("/api/v1/tweaks" + q)


def tool_tweak_import(args):
    path = args.get("path", "")
    if not os.path.isfile(path):
        raise RuntimeError(f"找不到文件: {path}")
    qs = []
    if args.get("folder"):
        qs.append("folder=" + urllib.parse.quote(args["folder"]))
    qs.append("filename=" + urllib.parse.quote(os.path.basename(path)))
    return api_upload("/api/v1/tweaks?" + "&".join(qs), path)


def tool_tweak_toggle(args):
    body = json.dumps({
        "name": args.get("name", ""),
        "enabled": bool(args.get("enabled", True)),
        "folder": args.get("folder"),
    }).encode()
    return _request("PATCH", "/api/v1/tweaks", data=body, content_type="application/json")


def tool_tweak_delete(args):
    name = args.get("name", "")
    if not name:
        raise RuntimeError("需要 name")
    qs = ["name=" + urllib.parse.quote(name)]
    if args.get("folder"):
        qs.append("folder=" + urllib.parse.quote(args["folder"]))
    return api_delete("/api/v1/tweaks?" + "&".join(qs))


def tool_tweak_sign(args):
    qs = ["force=" + ("1" if args.get("force") else "0")]
    if args.get("folder"):
        qs.append("folder=" + urllib.parse.quote(args["folder"]))
    return _request("POST", "/api/v1/tweaks/sign?" + "&".join(qs))


def tool_tweak_folder(args):
    name = args.get("name", "")
    if not name:
        raise RuntimeError("需要 name")
    return _request("POST", "/api/v1/tweakfolders", data=json.dumps({"name": name}).encode(),
                    content_type="application/json")


def tool_windows(_args):
    return api_get("/api/v1/windows")


def tool_window_action(args):
    wid = args.get("id", "")
    action = args.get("action", "")
    if not wid or not action:
        raise RuntimeError("需要 id 与 action（scale|pip|maximize|close）")
    body = {}
    if args.get("scale") is not None:
        body["scale"] = float(args["scale"])
    if args.get("enabled") is not None:
        body["enabled"] = bool(args["enabled"])
    return _request("POST", f"/api/v1/windows/{urllib.parse.quote(wid)}/{action}",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_screenshot(args):
    qs = []
    if args.get("window_id"):
        qs.append("windowId=" + urllib.parse.quote(args["window_id"]))
    qs.append("quality=%d" % int(args.get("quality", 70)))
    qs.append("maxWidth=%d" % int(args.get("max_width", 1290)))
    data = _request("GET", "/api/v1/screenshot?" + "&".join(qs))
    if not isinstance(data, (bytes, bytearray)) or not data:
        raise RuntimeError("截图返回为空或不是二进制")
    out = args.get("out_path") or f"/tmp/lc-shot-{int(time.time())}.jpg"
    with open(out, "wb") as fh:
        fh.write(data)
    return {"path": out, "bytes": len(data)}


def tool_keepalive(args):
    mode = args.get("mode", "")
    if mode not in ("off", "audio", "screenAwake", "audioAndScreen"):
        raise RuntimeError("mode 必须是 off / audio / screenAwake / audioAndScreen")
    return _request("POST", "/api/v1/keepalive",
                    data=json.dumps({"mode": mode}).encode(),
                    content_type="application/json")


def tool_install_from_url(args):
    url = args.get("url", "")
    if not url:
        raise RuntimeError("需要 url")
    body = {"url": url, "replace": bool(args.get("replace", True))}
    return _request("POST", "/api/v1/apps/from-url",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_jobs(args):
    jid = args.get("job_id")
    if jid:
        return api_get("/api/v1/jobs/" + urllib.parse.quote(jid))
    return api_get("/api/v1/jobs")


def tool_ui_tree(_args):
    return api_get("/api/v1/ui/tree")


def tool_ui_activate(args):
    body = {}
    for k in ("index", "label", "identifier"):
        if args.get(k) is not None:
            body[k] = args[k]
    if not body:
        raise RuntimeError("需要 index / label / identifier 之一")
    return _request("POST", "/api/v1/ui/activate",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_ui_tap(args):
    body = {"x": float(args["x"]), "y": float(args["y"])}
    return _request("POST", "/api/v1/ui/tap",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_ui_tab(args):
    body = {}
    if args.get("index") is not None:
        body["index"] = int(args["index"])
    if args.get("name"):
        body["name"] = args["name"]
    return _request("POST", "/api/v1/ui/tab",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_ui_text(args):
    return _request("POST", "/api/v1/ui/text",
                    data=json.dumps({"text": args.get("text", "")}).encode(),
                    content_type="application/json")


def tool_guest_logs(args):
    name = args.get("name")
    if not name:
        return api_get("/api/v1/logs/guest")
    qs = ["name=" + urllib.parse.quote(name),
          "offset=%d" % int(args.get("offset", 0)),
          "limit=%d" % int(args.get("limit", 65536))]
    return api_get("/api/v1/logs/guest?" + "&".join(qs))


def tool_guest_logs_clear(args):
    qs = ""
    if args.get("name"):
        qs = "?name=" + urllib.parse.quote(args["name"])
    return api_delete("/api/v1/logs/guest" + qs)


def tool_ui_taps(args):
    steps = args.get("steps") or []
    if not isinstance(steps, list) or not steps:
        raise RuntimeError("steps 必须是非空数组，例如 [{\"label\":\"启动\"},{\"x\":200,\"y\":300,\"delayMs\":800}]")
    body = {"steps": steps,
            "detectChange": bool(args.get("detect_change", True)),
            "captureAfter": bool(args.get("capture_after", True))}
    if args.get("window_id"):
        body["windowId"] = args["window_id"]
    res = _request("POST", "/api/v1/ui/taps",
                   data=json.dumps(body).encode(), content_type="application/json")
    b64 = None
    if isinstance(res, dict) and res.get("screenshotB64"):
        b64 = res.pop("screenshotB64")
    out_path = None
    if b64:
        import base64
        out_path = args.get("out_path") or f"/tmp/lc-seq-{int(time.time())}.jpg"
        with open(out_path, "wb") as fh:
            fh.write(base64.b64decode(b64))
        res["screenshot_path"] = out_path
    return res


def tool_guest_tree(_args):
    return api_get("/api/v1/guest/ui/tree")


def tool_guest_activate(args):
    body = {}
    for k in ("index", "label", "identifier", "x", "y"):
        if args.get(k) is not None:
            body[k] = args[k]
    if not body:
        raise RuntimeError("需要 index / label / identifier / x+y 之一")
    return _request("POST", "/api/v1/guest/ui/activate",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_guest_taps(args):
    steps = args.get("steps") or []
    if not steps:
        raise RuntimeError("steps 必须是非空数组")
    body = {"steps": steps, "detectChange": bool(args.get("detect_change", True))}
    return _request("POST", "/api/v1/guest/ui/taps",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_guest_text(args):
    return _request("POST", "/api/v1/guest/ui/text",
                    data=json.dumps({"text": args.get("text", "")}).encode(),
                    content_type="application/json")


def tool_guest_screenshot(args):
    qs = ["maxWidth=%d" % int(args.get("max_width", 900)),
          "quality=%d" % int(args.get("quality", 70))]
    data = _request("GET", "/api/v1/guest/screenshot?" + "&".join(qs))
    if not isinstance(data, (bytes, bytearray)) or not data:
        raise RuntimeError("guest 截图返回空")
    out = args.get("out_path") or f"/tmp/lc-guest-{int(time.time())}.jpg"
    with open(out, "wb") as fh:
        fh.write(data)
    return {"path": out, "bytes": len(data)}


def tool_guest_info(_args):
    return api_get("/api/v1/guest/info")


def tool_open_app(args):
    bundle_id = args.get("bundle_id", "")
    if not bundle_id:
        raise RuntimeError("需要 bundle_id（先用 lc_apps 取）")
    body = {"bundleId": bundle_id}
    if args.get("container"):
        body["container"] = args["container"]
    if args.get("url"):
        body["url"] = args["url"]
    return _request("POST", "/api/v1/apps/open",
                    data=json.dumps(body).encode(), content_type="application/json")


def tool_window_chrome(args):
    wid = args.get("window_id", "")
    if not wid:
        raise RuntimeError("需要 window_id（先用 lc_windows 取）")
    return api_get("/api/v1/windows/%s/chrome" % wid)


def tool_window_press(args):
    wid = args.get("window_id", "")
    sel = args.get("selector", "")
    if not wid or not sel:
        raise RuntimeError("需要 window_id 和 selector（closeWindow / maximizeWindow / minimizeWindow）")
    return _request("POST", "/api/v1/windows/%s/press" % wid,
                    data=json.dumps({"selector": sel}).encode(), content_type="application/json")


def tool_close_app(args):
    """按 bundleId 关掉 App：找到它的多任务窗口，走 UI 关闭按钮的事件（closeWindow），并确认进程已退出。"""
    bundle_id = args.get("bundle_id", "")
    if not bundle_id:
        raise RuntimeError("需要 bundle_id")
    wins = api_get("/api/v1/windows")
    targets = [w for w in wins.get("windows", []) if w.get("bundleId", "").startswith(bundle_id)]
    if not targets:
        return {"closed": False, "reason": "没有这个 App 的窗口（可能本来就没开）", "bundleId": bundle_id}
    results = []
    for w in targets:
        r = _request("POST", "/api/v1/windows/%s/close" % w["id"],
                     data=b"{}", content_type="application/json")
        results.append({"window": w["id"], "result": r})
    alive = api_get("/api/v1/windows")
    return {"bundleId": bundle_id, "results": results,
            "windowsLeft": alive.get("count", -1)}


def tool_guest_ocr(args):
    qs = []
    if args.get("text"):
        qs.append("text=" + quote(str(args["text"])))
    if args.get("no_cache"):
        qs.append("no_cache=1")
    path = "/api/v1/guest/ocr" + (("?" + "&".join(qs)) if qs else "")
    return api_get(path)


def tool_guest_ocr_history(args):
    return api_get("/api/v1/guest/ocr/history?limit=%d" % int(args.get("limit", 20)))


def tool_guest_inspect(args):
    idx = args.get("index")
    if idx is None:
        raise RuntimeError("需要 index（来自 lc_guest_tree）")
    return api_get("/api/v1/guest/inspect?index=%d" % int(idx))


TOOLS = [
    {
        "name": "lc_window_chrome",
        "description": "列出多任务窗口标题栏那三个按钮（关闭/最大化/最小化）绑定的 selector，便于按按钮而不是猜行为。",
        "inputSchema": {"type": "object", "properties": {"window_id": {"type": "string"}}, "required": ["window_id"]},
    },
    {
        "name": "lc_window_press",
        "description": "按标题栏按钮绑定的 selector 触发事件（等价于点那个按钮）：closeWindow / maximizeWindow / minimizeWindow。",
        "inputSchema": {
            "type": "object",
            "properties": {"window_id": {"type": "string"}, "selector": {"type": "string"}},
            "required": ["window_id", "selector"],
        },
    },
    {
        "name": "lc_close_app",
        "description": "按 bundle_id 关掉 App：触发窗口的关闭按钮事件并确认进程已退出。调试完收尾用它。",
        "inputSchema": {"type": "object", "properties": {"bundle_id": {"type": "string"}}, "required": ["bundle_id"]},
    },
    {
        "name": "lc_open_app",
        "description": "一步打开已装 App（多任务窗口）并等 guest 侧就绪，返回窗口与 guest pid。想进 App 内部操作时先用它。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "bundle_id": {"type": "string", "description": "来自 lc_apps"},
                "container": {"type": "string", "description": "数据容器 folderName，可选"},
                "url": {"type": "string", "description": "启动 URL，可选"},
            },
            "required": ["bundle_id"],
        },
    },
    {
        "name": "lc_health",
        "description": "探活：返回 LiveContainer 版本、端口。不需要 token。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "lc_apps",
        "description": "列出 LiveContainer 里已安装的应用（bundleId、版本、容器、是否隐藏）。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "lc_install_ipa",
        "description": "把本机的一个 .ipa 上传安装到 LiveContainer。返回安装后的 bundleId。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ipa_path": {"type": "string", "description": "本机 .ipa 绝对路径"},
                "replace": {"type": "boolean", "description": "同 bundleId 是否覆盖（默认 true）"},
            },
            "required": ["ipa_path"],
        },
    },
    {
        "name": "lc_uninstall_app",
        "description": "按 bundleId 卸载应用。keep_data=true 时保留数据容器。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "bundle_id": {"type": "string"},
                "keep_data": {"type": "boolean", "description": "默认 false（连数据一起删）"},
            },
            "required": ["bundle_id"],
        },
    },
    {
        "name": "lc_launch_app",
        "description": "启动一个已安装的应用（可选指定数据容器 folder 与启动 URL）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "bundle_id": {"type": "string"},
                "container": {"type": "string", "description": "数据容器 folderName，省略用默认容器"},
                "url": {"type": "string", "description": "传给 App 的启动 URL"},
                "multitask": {"type": "boolean", "description": "true=在 LiveContainer 的多任务窗口里跑（主 UI 不退，HTTP 服务不跟着挂起）"},
            },
            "required": ["bundle_id"],
        },
    },
    {
        "name": "lc_tweaks",
        "description": "列出 tweak（根目录或指定 folder），含启用状态。folder 省略=根目录。",
        "inputSchema": {
            "type": "object",
            "properties": {"folder": {"type": "string"}},
        },
    },
    {
        "name": "lc_tweak_import",
        "description": "上传 .dylib / .framework(zip) 到设备 tweak 目录并（有证书时）重签。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "本机文件绝对路径"},
                "folder": {"type": "string", "description": "tweak 子目录，省略=全局"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "lc_tweak_toggle",
        "description": "启用/停用某个 tweak（设备侧是把文件名加/去 .disabled 后缀）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "tweak 显示名，如 BlockNetPlus.dylib"},
                "enabled": {"type": "boolean"},
                "folder": {"type": "string"},
            },
            "required": ["name", "enabled"],
        },
    },
    {
        "name": "lc_tweak_delete",
        "description": "删除 tweak。",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}, "folder": {"type": "string"}},
            "required": ["name"],
        },
    },
    {
        "name": "lc_tweak_sign",
        "description": "对一个 tweak 目录跑 ZSign 重签（force=true 连签名有效的也重签）。",
        "inputSchema": {
            "type": "object",
            "properties": {"folder": {"type": "string"}, "force": {"type": "boolean"}},
        },
    },
    {
        "name": "lc_tweak_folder",
        "description": "新建 tweak 子目录（应用专用 tweak 文件夹）。",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
    {
        "name": "lc_windows",
        "description": "列出 LiveContainer 里的多任务窗口（小窗/虚拟窗口）：id(dataUUID)、bundleId、pid、scale、是否最大化、frame。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "lc_window_action",
        "description": "对窗口做动作：scale 缩放（0.4–3.0）、pip 收成小窗/还原、maximize 最大化、close 结束。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "窗口 id（lc_windows 返回的 dataUUID）"},
                "action": {"type": "string", "enum": ["scale", "pip", "maximize", "close"]},
                "scale": {"type": "number", "description": "action=scale 时的倍率"},
                "enabled": {"type": "boolean", "description": "action=pip/maximize 时切换开关"},
            },
            "required": ["id", "action"],
        },
    },
    {
        "name": "lc_screenshot",
        "description": "截取当前 screen/指定窗口的画面（JPEG），存到本机文件并返回路径，供直接查看判断界面状态。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "window_id": {"type": "string", "description": "省略=截当前 LiveContainer 界面"},
                "out_path": {"type": "string", "description": "本机保存路径，默认 /tmp/lc-shot-<ts>.jpg"},
                "quality": {"type": "integer", "description": "JPEG 质量 1-100，默认 70"},
                "max_width": {"type": "integer", "description": "最大宽度，默认 1290"},
            },
        },
    },
    {
        "name": "lc_keepalive",
        "description": "设置设备后台保活方式：off / audio（静音音频，锁屏也在线）/ screenAwake（屏幕常亮）/ audioAndScreen。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {"type": "string", "enum": ["off", "audio", "screenAwake", "audioAndScreen"]},
            },
            "required": ["mode"],
        },
    },
    {
        "name": "lc_install_from_url",
        "description": "让设备自己下载 ipa 并安装（推荐：不依赖长连接上传，进程被挂起也不会传一半）。返回 jobId，用 lc_jobs 轮询。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "ipa 的 http(s) 直链"},
                "replace": {"type": "boolean", "description": "同 bundleId 是否覆盖（默认 true）"},
            },
            "required": ["url"],
        },
    },
    {
        "name": "lc_jobs",
        "description": "查异步任务状态（省略 job_id 则列最近任务）。",
        "inputSchema": {
            "type": "object",
            "properties": {"job_id": {"type": "string"}},
        },
    },
    {
        "name": "lc_guest_ocr",
        "description": "OCR 当前 guest 画面（系统 Vision，中文+英文），返回文字与坐标框。视图树读不到文字的自绘/WebView 界面靠它。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "只返回包含该文字的结果"},
            },
        },
    },
    {
        "name": "lc_guest_ocr_history",
        "description": "回看 OCR 历史记录（每次识别都落盘），看某个页面当时识别到了什么文字。",
        "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}},
    },
    {
        "name": "lc_guest_inspect",
        "description": "导出某个元素的视图结构（class/frame/子视图/读到的文字），用来判断文字是控件还是画上去的。",
        "inputSchema": {"type": "object", "properties": {"index": {"type": "integer"}}, "required": ["index"]},
    },
    {
        "name": "lc_guest_info",
        "description": "guest App 进程信息（bundleId / pid / 屏幕尺寸）。需要 guest App 正在运行。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "lc_guest_tree",
        "description": "导出 **guest App 自己界面** 的可访问性树（在 guest 进程内取，能看到 App 内部的按钮）。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "lc_guest_activate",
        "description": "点 guest App 内部的元素：index / label / identifier / x+y。走 guest 进程内的 accessibilityActivate。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "index": {"type": "integer"},
                "label": {"type": "string"},
                "identifier": {"type": "string"},
                "x": {"type": "number"},
                "y": {"type": "number"},
            },
        },
    },
    {
        "name": "lc_guest_taps",
        "description": "在 guest App 内部按顺序点击多步（label/index/坐标），每步 track 画面是否变化。装完 ipa 做内部操作自测就用它。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "steps": {"type": "array", "items": {"type": "object"},
                          "description": "每步 {label?|identifier?|index?|x,y}，可选 delayMs"},
                "detect_change": {"type": "boolean"},
            },
            "required": ["steps"],
        },
    },
    {
        "name": "lc_guest_text",
        "description": "给 guest App 内当前输入框输入文本。",
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
    },
    {
        "name": "lc_guest_screenshot",
        "description": "截 guest App 自己的画面（在 guest 进程内渲染，不受跨进程合成影响），存本机并返回路径。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "max_width": {"type": "integer", "description": "默认 900"},
                "quality": {"type": "integer", "description": "JPEG 质量 1-100，默认 70"},
                "out_path": {"type": "string"},
            },
        },
    },
    {
        "name": "lc_ui_tree",
        "description": "导出当前界面可访问性树（label/identifier/frame/是否可激活）。做界面自测先调这个，再按 index 激活。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "lc_ui_activate",
        "description": "激活元素：index（来自 lc_ui_tree）或 label/identifier 匹配。走 accessibilityActivate / UIControl.sendActions，等价于点一下。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "index": {"type": "integer"},
                "label": {"type": "string", "description": "元素文字，支持包含匹配"},
                "identifier": {"type": "string"},
            },
        },
    },
    {
        "name": "lc_ui_taps",
        "description": "按顺序模拟多次点击（label / index / 坐标混合），每步可设 delayMs，回报每步是否让画面发生变化，可选跑完截图存本机。适合装完 ipa 后做内部点击自测。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "steps": {
                    "type": "array",
                    "description": "步骤数组。每步：{label?} 或 {identifier?} 或 {index?} 或 {x,y}，可选 delayMs（默认 400）、note",
                    "items": {
                        "type": "object",
                        "properties": {
                            "label": {"type": "string"},
                            "identifier": {"type": "string"},
                            "index": {"type": "integer"},
                            "x": {"type": "number"},
                            "y": {"type": "number"},
                            "delayMs": {"type": "integer"},
                            "note": {"type": "string"},
                        },
                    },
                },
                "detect_change": {"type": "boolean", "description": "每步比较截图哈希，判断界面是否变化（默认 true）"},
                "capture_after": {"type": "boolean", "description": "跑完截一张图存本机，返回路径（默认 true）"},
                "window_id": {"type": "string", "description": "截图用哪个窗口，省略=整个界面"},
                "out_path": {"type": "string", "description": "截图保存路径，默认 /tmp/lc-seq-<ts>.jpg"},
            },
            "required": ["steps"],
        },
    },
    {
        "name": "lc_ui_tap",
        "description": "按屏幕坐标点击（x,y），命中后走控件 sendActions 或 accessibilityActivate。",
        "inputSchema": {
            "type": "object",
            "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
            "required": ["x", "y"],
        },
    },
    {
        "name": "lc_ui_tab",
        "description": "切底部 Tab：index 或 name（如 App / 模块 / 设置 / 源）。",
        "inputSchema": {
            "type": "object",
            "properties": {"index": {"type": "integer"}, "name": {"type": "string"}},
        },
    },
    {
        "name": "lc_ui_text",
        "description": "给当前第一响应者输入文本（先 ui_activate 点中输入框）。",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "lc_guest_logs",
        "description": "读 guest App（以及注入的 tweak）的 stdout/stderr 日志。省略 name 则列文件；给 name 则按 offset 增量读（返回 next 供下次续读）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "日志文件名，来自列表"},
                "offset": {"type": "integer", "description": "从该字节开始，默认 0"},
                "limit": {"type": "integer", "description": "最多读多少字节，默认 65536"},
            },
        },
    },
    {
        "name": "lc_guest_logs_clear",
        "description": "删除 guest 日志文件（省略 name 清空全部）。",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}},
    },
    {
        "name": "lc_logs",
        "description": "拉设备日志（进程内 stdout/stderr 环形缓冲）。since=上次返回的 latest 可增量拉取；wait=长轮询秒数。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "since": {"type": "integer", "description": "从该 seq 之后开始（默认 0）"},
                "limit": {"type": "integer", "description": "最多返回条数（默认 200）"},
                "wait": {"type": "integer", "description": "没有新日志时最多等几秒（默认 0）"},
            },
        },
    },
]

HANDLERS = {
    "lc_window_chrome": tool_window_chrome,
    "lc_window_press": tool_window_press,
    "lc_close_app": tool_close_app,
    "lc_open_app": tool_open_app,
    "lc_health": tool_health,
    "lc_apps": tool_apps,
    "lc_install_ipa": tool_install,
    "lc_uninstall_app": tool_uninstall,
    "lc_launch_app": tool_launch,
    "lc_tweaks": tool_tweaks,
    "lc_tweak_import": tool_tweak_import,
    "lc_tweak_toggle": tool_tweak_toggle,
    "lc_tweak_delete": tool_tweak_delete,
    "lc_tweak_sign": tool_tweak_sign,
    "lc_tweak_folder": tool_tweak_folder,
    "lc_windows": tool_windows,
    "lc_window_action": tool_window_action,
    "lc_screenshot": tool_screenshot,
    "lc_install_from_url": tool_install_from_url,
    "lc_ui_tree": tool_ui_tree,
    "lc_ui_activate": tool_ui_activate,
    "lc_guest_ocr": tool_guest_ocr,
    "lc_guest_ocr_history": tool_guest_ocr_history,
    "lc_guest_inspect": tool_guest_inspect,
    "lc_guest_info": tool_guest_info,
    "lc_guest_tree": tool_guest_tree,
    "lc_guest_activate": tool_guest_activate,
    "lc_guest_taps": tool_guest_taps,
    "lc_guest_text": tool_guest_text,
    "lc_guest_screenshot": tool_guest_screenshot,
    "lc_ui_taps": tool_ui_taps,
    "lc_ui_tap": tool_ui_tap,
    "lc_ui_tab": tool_ui_tab,
    "lc_guest_logs": tool_guest_logs,
    "lc_guest_logs_clear": tool_guest_logs_clear,
    "lc_ui_text": tool_ui_text,
    "lc_jobs": tool_jobs,
    "lc_keepalive": tool_keepalive,
    "lc_logs": tool_logs,
}


# ── JSON-RPC / MCP 循环 ─────────────────────────────────────────────────────
def reply(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        return reply(msg_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    if method in ("notifications/initialized", "initialized"):
        return
    if method == "ping":
        return reply(msg_id, {})
    if method == "tools/list":
        return reply(msg_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        fn = HANDLERS.get(name)
        if fn is None:
            return reply(msg_id, error={"code": -32601, "message": f"unknown tool {name}"})
        try:
            result = fn(args)
            text = json.dumps(result, ensure_ascii=False, indent=2)
            return reply(msg_id, {"content": [{"type": "text", "text": text}],
                                  "isError": False})
        except Exception as exc:  # noqa: BLE001
            return reply(msg_id, {"content": [{"type": "text", "text": f"{exc}"}],
                                  "isError": True})
    if msg_id is not None:
        return reply(msg_id, error={"code": -32601, "message": f"unknown method {method}"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(msg)


if __name__ == "__main__":
    main()
