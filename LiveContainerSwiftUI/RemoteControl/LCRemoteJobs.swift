//
//  LCRemoteJobs.swift
//  LiveContainerSwiftUI
//
//  异步任务：给"设备自己去下载 IPA 再安装"用。
//  走长连接上传 18MB，一旦 app 被挂起连接就断；让设备自己下载 + 轮询任务状态稳得多。
//

import Foundation

final class LCRemoteJob {
    enum Status: String {
        case running, done, failed
    }

    let id: String
    let kind: String
    var status: Status = .running
    var message: String = ""
    var result: [String: Any]?
    var createdAt = Date()
    var updatedAt = Date()

    init(kind: String) {
        self.id = UUID().uuidString
        self.kind = kind
    }

    var json: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "kind": kind,
            "status": status.rawValue,
            "message": message,
            "createdAt": createdAt.timeIntervalSince1970,
            "updatedAt": updatedAt.timeIntervalSince1970
        ]
        if let result { d["result"] = result }
        return d
    }
}

@MainActor
final class LCRemoteJobs {
    static let shared = LCRemoteJobs()

    private var jobs: [String: LCRemoteJob] = [:]
    private let capacity = 50

    private init() {}

    func create(kind: String) -> LCRemoteJob {
        let job = LCRemoteJob(kind: kind)
        jobs[job.id] = job
        // 简单裁剪，只留最近 50 个
        if jobs.count > capacity {
            for key in jobs.keys.sorted(by: { (jobs[$0]?.createdAt ?? .distantPast) < (jobs[$1]?.createdAt ?? .distantPast) })
                .prefix(jobs.count - capacity) {
                jobs.removeValue(forKey: key)
            }
        }
        return job
    }

    func get(_ id: String) -> LCRemoteJob? { jobs[id] }

    func all() -> [LCRemoteJob] { jobs.values.sorted { $0.createdAt > $1.createdAt } }

    func finish(_ job: LCRemoteJob, result: [String: Any]? = nil, error: String? = nil) {
        job.updatedAt = Date()
        if let error {
            job.status = .failed
            job.message = error
        } else {
            job.status = .done
            job.result = result
            job.message = "ok"
        }
    }

    /// 设备自己下载 ipa 再安装；进度写在 job.message 里
    func runInstall(_ job: LCRemoteJob, urlString: String, replaceExisting: Bool) async {
        job.message = "downloading \(urlString)"
        guard let url = URL(string: urlString) else {
            finish(job, error: "非法 URL")
            return
        }
        do {
            let (tmpURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                finish(job, error: "下载失败 HTTP \(http.statusCode)")
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("lc-dl-\(UUID().uuidString).ipa")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            job.message = "downloaded \(dest.lastPathComponent), installing"
            let info = try await LCAppInstaller.install(ipa: dest, replaceExisting: replaceExisting)
            try? FileManager.default.removeItem(at: dest)
            finish(job, result: ["bundleId": info.bundleIdentifier() ?? "",
                                 "name": info.displayName() ?? "",
                                 "version": info.version() ?? "",
                                 "relativePath": info.relativeBundlePath ?? ""])
        } catch {
            finish(job, error: error.localizedDescription)
        }
    }
}
