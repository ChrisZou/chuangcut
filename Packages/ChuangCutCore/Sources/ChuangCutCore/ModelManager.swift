import Foundation

public final class ModelManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let recommended = ["ggml-large-v3-turbo-q5_0.bin", "ggml-medium.bin", "ggml-small.bin"]
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/ChuangCut/models", isDirectory: true)
    }
    public static func discover(includeDownloads: Bool = true) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            directory, URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"),
            home.appendingPathComponent(".cache/whisper"), home.appendingPathComponent("models"),
        ]
        if includeDownloads { roots.append(home.appendingPathComponent("Downloads")) }
        var result: [URL] = []
        for root in roots {
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for file in files {
                if file.lastPathComponent.hasPrefix("ggml-"), file.pathExtension == "bin" { result.append(file) }
                // One extra level only, bounded to model-related folders.
                if file.lastPathComponent.lowercased().contains("whisper") || file.lastPathComponent == "models" {
                    result +=
                        ((try? FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
                }
            }
        }
        return Array(Set(result)).sorted { a, b in
            let ai = recommended.firstIndex(of: a.lastPathComponent) ?? 99
            let bi = recommended.firstIndex(of: b.lastPathComponent) ?? 99
            return ai == bi ? a.path < b.path : ai < bi
        }
    }
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var completion: CheckedContinuation<URL, Error>?
    private var report: ((Double) -> Void)?
    private var target: URL?
    private var downloadError: Error?
    public func download(name: String, progress: @escaping (Double) -> Void) async throws -> URL {
        guard Self.recommended.contains(name) else { throw ChuangCutError.message("Unknown model") }
        guard completion == nil else { throw ChuangCutError.message("A download is already running") }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        target = Self.directory.appendingPathComponent(name)
        report = progress
        downloadError = nil
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion = continuation
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
                    let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)")!
                    task = session?.downloadTask(with: url)
                    task?.resume()
                    if Task.isCancelled { task?.cancel() }
                }
            }, onCancel: { self.cancel() })
    }
    public func cancel() { task?.cancel() }
    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 { report?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                let target
            else { throw ChuangCutError.message("Model download failed") }
            let size =
                (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 1_000_000 else { throw ChuangCutError.message("Downloaded file is not a ggml model") }
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: target)
            }
        } catch { downloadError = error }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? downloadError {
            completion?.resume(throwing: error)
        } else if let target {
            report?(1)
            completion?.resume(returning: target)
        }
        completion = nil
        report = nil
        self.task = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
