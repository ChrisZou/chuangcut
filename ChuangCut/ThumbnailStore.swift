import AVFoundation
import AppKit
import Observation

/// Timeline thumbnails, one per half second of source. They live in a bounded dictionary rather than an
/// NSCache: NSCache empties itself whenever the system reports memory pressure, and the timeline then
/// regenerated every visible tile at once, so the strip flickered for as long as the pressure lasted.
@MainActor @Observable final class ThumbnailStore {
    var poster: NSImage?
    var generation = 0
    @ObservationIgnored private var source: URL?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var posterGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var images: [Int: NSImage] = [:]
    /// Insertion order, oldest first, for evicting past `limit`.
    @ObservationIgnored private var order: [Int] = []
    @ObservationIgnored private var pending = Set<Int>()
    @ObservationIgnored private var failed = Set<Int>()
    @ObservationIgnored private var epoch = UUID()
    /// About 70 MB at 320 × 180; a full-width timeline shows a few dozen tiles.
    private let limit = 300
    /// An audio recording has no frames; its timeline tiles and preview stay dark.
    func load(_ url: URL, hasVideo: Bool = true) {
        guard source != url || (generator != nil) != hasVideo else { return }
        source = url
        epoch = UUID()
        generator?.cancelAllCGImageGeneration()
        posterGenerator?.cancelAllCGImageGeneration()
        images = [:]
        order = []
        pending = []
        failed = []
        poster = nil
        generator = nil
        guard hasVideo else { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Tiles are 92 × 64 pt; this covers them at 2× with room for the center crop.
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        self.generator = generator
        loadPoster(asset)
    }
    func image(at time: Double) -> NSImage? { images[bucket(time)] }
    private func bucket(_ time: Double) -> Int { Int((max(0, time) * 2).rounded(.down)) }
    func request(_ times: [Double]) {
        guard let generator else { return }
        let keys = Set(times.map(bucket)).filter {
            !pending.contains($0) && !failed.contains($0) && images[$0] == nil
        }
        guard !keys.isEmpty else { return }
        pending.formUnion(keys)
        let epoch = epoch
        generator.generateCGImagesAsynchronously(
            forTimes: keys.sorted().map { NSValue(time: CMTime(seconds: Double($0) / 2, preferredTimescale: 600)) }
        ) { [weak self] requested, cg, _, _, _ in
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                let key = self.bucket(requested.seconds)
                self.pending.remove(key)
                guard let cg else {
                    self.failed.insert(key)
                    return
                }
                self.store(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), at: key)
                self.generation += 1
            }
        }
    }
    private func store(_ image: NSImage, at key: Int) {
        if images.updateValue(image, forKey: key) == nil { order.append(key) }
        while order.count > limit { images[order.removeFirst()] = nil }
    }
    /// The subtitle preview shows the first frame large, so it gets its own sharper image.
    private func loadPoster(_ asset: AVURLAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        posterGenerator = generator
        let epoch = epoch
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, cg, _, _, _ in
            guard let cg else { return }
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                self.poster = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}
