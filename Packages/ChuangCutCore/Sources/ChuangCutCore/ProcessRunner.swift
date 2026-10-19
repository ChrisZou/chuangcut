import Foundation

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    public func check() throws { if isCancelled { throw CancellationError() } }
    public func cancel() {
        lock.lock()
        cancelled = true
        let active = processes
        lock.unlock()
        for process in active where process.isRunning { process.terminate() }
    }
    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        processes.append(process)
    }
    func remove(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }
}
public struct ProcessOutput {
    public var stdout: Data
    public var stderr: String
}
private final class DataBuffer: @unchecked Sendable {
    let lock = NSLock()
    var bytes = Data()
    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }
}
public enum ProcessRunner {
    /// Pipes are drained on separate queues so verbose tools and raw PCM never deadlock.
    public static func run(
        _ executable: String, _ arguments: [String], cancellation: CancellationToken = CancellationToken(),
        stdout: ((String) -> Void)? = nil, stderr: ((String) -> Void)? = nil
    ) throws -> ProcessOutput {
        try cancellation.check()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try cancellation.launch(process)
        let group = DispatchGroup()
        let outData = DataBuffer()
        let errData = DataBuffer()
        for (pipe, buffer, callback) in [(out, outData, stdout), (err, errData, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    if let callback {
                        pending.append(data)
                        while let range = pending.firstRange(of: Data([10])) {
                            callback(String(decoding: pending[..<range.lowerBound], as: UTF8.self))
                            pending.removeSubrange(...range.lowerBound)
                        }
                    }
                }
                if !pending.isEmpty { callback?(String(decoding: pending, as: UTF8.self)) }
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()
        cancellation.remove(process)
        try cancellation.check()
        let error = String(decoding: errData.bytes, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ChuangCutError.message(
                "\(URL(fileURLWithPath: executable).lastPathComponent) exited \(process.terminationStatus):\n\(error.suffix(5000))"
            )
        }
        return ProcessOutput(stdout: outData.bytes, stderr: error)
    }
}
public struct ToolPaths: Sendable {
    public var ffmpeg: String
    public var whisper: String
    public var ffprobe: String {
        let sibling = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : Self.resolve("ffprobe")
    }
    public init(ffmpeg: String = ToolPaths.resolve("ffmpeg"), whisper: String = ToolPaths.resolve("whisper-cli")) {
        self.ffmpeg = ffmpeg
        self.whisper = whisper
    }
    public static func resolve(_ name: String) -> String {
        for root in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(root)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let result = try? ProcessRunner.run("/usr/bin/which", [name]),
            let path = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        {
            return path
        }
        return "/opt/homebrew/bin/\(name)"
    }
}
