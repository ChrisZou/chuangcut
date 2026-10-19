import AVFoundation
import AppKit

@MainActor final class ThumbnailStore: ObservableObject {
    @Published var poster: NSImage?
    @Published var generation = 0
    private var source: URL?
    private var generator: AVAssetImageGenerator?
    private let cache = NSCache<NSNumber, NSImage>()
    private var pending = Set<Int>()
    private var epoch = UUID()
    func load(_ url: URL) {
        guard source != url else { return }
        source = url
        epoch = UUID()
        generator?.cancelAllCGImageGeneration()
        cache.removeAllObjects()
        pending = []
        poster = nil
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        self.generator = generator
        cache.countLimit = 400
        request([0])
    }
    func image(at time: Double) -> NSImage? { cache.object(forKey: NSNumber(value: bucket(time))) }
    private func bucket(_ time: Double) -> Int { Int((max(0, time) * 2).rounded(.down)) }
    func request(_ times: [Double]) {
        guard let generator else { return }
        let keys = Set(times.map(bucket)).filter {
            !pending.contains($0) && cache.object(forKey: NSNumber(value: $0)) == nil
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
                if let cg {
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache.setObject(image, forKey: NSNumber(value: key))
                    if key == 0 { self.poster = image }
                    self.generation += 1
                }
            }
        }
    }
}
