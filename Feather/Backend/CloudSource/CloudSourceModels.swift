import Foundation

struct CloudSourceConfiguration: Codable, Equatable {
    var kind = "github"
    var repository: String? = ""
    var url: String?
    var tagPrefix: String? = ""
    var assetPattern: String? = ""
    var includePrereleases: Bool? = false
    var paused = false

    func matchesSubscription(_ other: Self) -> Bool {
        guard kind == other.kind, paused == other.paused else { return false }
        if kind == "url" { return url?.trimmingCharacters(in: .whitespacesAndNewlines) == other.url?.trimmingCharacters(in: .whitespacesAndNewlines) }
        func repositoryKey(_ value: String?) -> String {
            var key = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.hasPrefix("https://github.com/") { key = String(key.dropFirst(19)) }
            if key.hasSuffix("/") { key.removeLast() }
            if key.hasSuffix(".git") { key = String(key.dropLast(4)) }
            return key
        }
        return repositoryKey(repository) == repositoryKey(other.repository)
            && (tagPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == (other.tagPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            && (assetPattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == (other.assetPattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && (includePrereleases ?? false) == (other.includePrereleases ?? false)
    }

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
    let icon: CloudSourceIcon?
}

struct CloudSourceIcon: Codable {
    let sha256: String
}

struct CloudSourcePresentation: Codable {
    let iconURL: String?
}

struct CloudSourceVersion: Codable {
    let metadata: CloudSourceMetadata
    let downloadURL: String
    let date: String
    let inspectedAt: String
    let inspection: CloudSourceInspection
    let iconURL: String?
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
    let presentation: CloudSourcePresentation?

    func iconURL(relativeTo endpoint: URL?) -> URL? {
        if let sha = current?.inspection.icon?.sha256, sha.count == 64,
           sha.allSatisfy({ "0123456789abcdef".contains($0) }), let endpoint {
            return endpoint.appendingPathComponent("app-icons/\(sha).png")
        }
        return (presentation?.iconURL ?? current?.iconURL).flatMap(URL.init(string:))
    }

    var versionText: String {
        guard let metadata = current?.metadata else { return "版本待解析" }
        if let build = metadata.buildVersion, !build.isEmpty { return "\(metadata.version) (\(build))" }
        return metadata.version
    }

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

    /// Candidate feed paths; verify the service before exposing management UI.
    static func managementURL(for sourceURL: URL?) -> URL? {
        guard let sourceURL, sourceURL.scheme?.lowercased() == "https", sourceURL.host != nil,
              sourceURL.user == nil, sourceURL.password == nil else { return nil }
        let path = sourceURL.path
        guard path == "/source.json" || path == "/appstore" ||
              (path.hasPrefix("/sources/") && path.hasSuffix(".json") && sourceURL.pathComponents.count == 3) else { return nil }
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    static func baseURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "CloudSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入软件源服务的 HTTPS 地址，例如 https://example.workers.dev"])
        }
        return url
    }

    static func verifiedManagementURL(for sourceURL: URL?, session: URLSession = .shared) async -> URL? {
        guard let endpoint = managementURL(for: sourceURL) else { return nil }
        struct Health: Decodable { let service: String }
        let request = URLRequest(url: endpoint.appendingPathComponent("health"),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                  try JSONDecoder().decode(Health.self, from: data).service == "signos-source-aggregator" else { return nil }
            return endpoint
        } catch {
            return nil
        }
    }
}
