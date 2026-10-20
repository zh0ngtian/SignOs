import Foundation

struct DownloadTransferFailure: Error, LocalizedError, Sendable {
    let message: String
    let requiresRestart: Bool
    let singleStream: Bool
    var errorDescription: String? { message }

    static func restart(_ message: String, singleStream: Bool = false) -> Self {
        Self(message: message, requiresRestart: true, singleStream: singleStream)
    }
    static func interrupted(_ message: String = "下载中断，已保留已下载部分。") -> Self {
        Self(message: message, requiresRestart: false, singleStream: false)
    }
}
