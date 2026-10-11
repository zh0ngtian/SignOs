import Foundation

struct CloudSourceConfiguration: Codable, Equatable {
    var kind = "github"
    var repository: String? = ""
    var url: String?
    var tagPrefix: String? = ""
    var assetPattern: String? = ""
    var includePrereleases: Bool? = false
    var paused = false

    static func directURL(_ url: String) -> Self {
        var config = Self()
        config.kind = "url"
        config.url = url
        config.repository = nil
        config.tagPrefix = nil
        config.assetPattern = nil
        config.includePrereleases = nil
        return config
    }
}

struct CloudSourceMetadata: Codable, Equatable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let buildVersion: String?
    let minOSVersion: String?
}

struct CloudSourceInspection: Codable {
    let fullBytes: Int64
    let downloadedBytes: Int64
    let crc32: String
    let plistFormat: String
}

struct CloudSourceVersion: Codable {
    let metadata: CloudSourceMetadata
    let downloadURL: String
    let date: String
    let inspectedAt: String
    let inspection: CloudSourceInspection
}

struct CloudSourceFailure: Codable {
    let code: String
    let message: String
    let retryable: Bool?
}

struct CloudSourceEntry: Codable, Identifiable {
    let id: String
    let revision: Int
    let config: CloudSourceConfiguration
    let published: Bool
    let current: CloudSourceVersion?
    let history: [CloudSourceVersion]
    let status: String
    let error: CloudSourceFailure?
    let lastSuccessAt: String?

    var title: String { current?.metadata.name ?? config.repository ?? config.url ?? "新订阅" }
    var isWorking: Bool { ["queued", "parsing", "retrying"].contains(status) }
    var statusText: String {
        if config.paused { return "已暂停自动同步" }
        switch status {
        case "queued": return "等待解析"
        case "parsing": return "正在解析 IPA"
        case "retrying": return "等待重试"
        case "ready": return "解析成功，等待确认添加"
        case "succeeded": return "同步成功"
        case "failed": return published ? "本次更新失败，保留原版本" : "解析失败，未发布"
        default: return "待处理"
        }
    }
}

struct CloudSourceSettings: Codable {
    let id: String
    let identifier: String
    let name: String
    let description: String
}

struct CloudSourceSnapshot: Codable {
    let revision: Int
    let settings: CloudSourceSettings
    let entries: [CloudSourceEntry]
}

struct CloudSourceCandidate: Codable, Identifiable {
    let id: Int64
    let name: String
    let size: Int64
    let url: String
    let tag: String

    var caption: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return tag + " · " + sizeText
    }
}

enum CloudSourceEndpoint {
    static let defaultURL = "https://signos-source-aggregator.305301890.workers.dev"

    static func baseURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "CloudSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入软件源服务的 HTTPS 地址，例如 https://example.workers.dev"])
        }
        return url
    }
}
