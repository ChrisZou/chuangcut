import Foundation

/// A ChuangCut project package: a `.chuangcut` directory with `project.json` and optional media state.
public enum ProjectPackage {
    public static let pathExtension = "chuangcut"
    public static let projectFileName = "project.json"
    public static let stateFileName = "state.json"

    /// Playhead and media bookmark/path stored beside the project payload.
    public struct State: Codable, Equatable, Sendable {
        public var playhead: Double
        public var previewCuts: Bool
        /// Absolute path fallback when the bookmark cannot be resolved.
        public var mediaPath: String?
        /// Security-scoped bookmark for the source media when available.
        public var mediaBookmark: Data?

        public init(
            playhead: Double = 0, previewCuts: Bool = true, mediaPath: String? = nil, mediaBookmark: Data? = nil
        ) {
            self.playhead = playhead
            self.previewCuts = previewCuts
            self.mediaPath = mediaPath
            self.mediaBookmark = mediaBookmark
        }
    }

    public static func packageURL(named name: String, in directory: URL) -> URL {
        let base = name.hasSuffix(".\(pathExtension)") ? name : "\(name).\(pathExtension)"
        return directory.appendingPathComponent(base)
    }

    /// Writes `project.json` + `state.json` into a directory package (creates/replaces contents).
    public static func save(project: Project, state: State, to packageURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageURL.path) {
            // Replace files in place so Finder package identity stays stable.
        } else {
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        }
        var project = project
        // Prefer the absolute media path recorded in state when present.
        if let path = state.mediaPath, !path.isEmpty {
            project.source = URL(fileURLWithPath: path)
        }
        try JSONFile.write(project, to: packageURL.appendingPathComponent(projectFileName))
        try JSONFile.write(state, to: packageURL.appendingPathComponent(stateFileName))
        var values = URLResourceValues()
        values.isPackage = true
        var mutable = packageURL
        try? mutable.setResourceValues(values)
    }

    /// Loads the project, restores punctuation, and resolves the media URL from bookmark or path.
    public static func load(from packageURL: URL) throws -> (project: Project, state: State, mediaURL: URL) {
        let projectPath = packageURL.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw ChuangCutError.message("Project package is missing project.json")
        }
        var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectPath))
        project.transcript?.normalizePunctuation()
        for i in project.candidates.indices {
            project.candidates[i].text = TextNormalization.cjkPunctuation(project.candidates[i].text)
        }
        let statePath = packageURL.appendingPathComponent(stateFileName)
        var state: State
        if FileManager.default.fileExists(atPath: statePath.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: statePath))
        } else {
            state = State(mediaPath: project.source.path)
        }
        let mediaURL = try resolveMediaURL(project: project, state: state)
        project.source = mediaURL
        if state.mediaPath == nil { state.mediaPath = mediaURL.path }
        return (project, state, mediaURL)
    }

    public static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveMediaURL(project: Project, state: State) throws -> URL {
        var isStale = false
        if let bookmark = state.mediaBookmark {
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                    bookmarkDataIsStale: &isStale)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            } catch {
                // Fall through to path.
            }
        }
        if let path = state.mediaPath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            throw ChuangCutError.message("Missing source media: \(path)")
        }
        if FileManager.default.fileExists(atPath: project.source.path) { return project.source }
        throw ChuangCutError.message("Missing source media: \(project.source.path)")
    }
}
