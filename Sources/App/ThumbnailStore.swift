import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Last still seen for each camera, kept on disk so the panel can show it
/// without opening a stream.
@MainActor
final class ThumbnailStore: ObservableObject {
    struct Thumbnail {
        let image: NSImage
        let date: Date
    }

    @Published private(set) var thumbnails: [String: Thumbnail] = [:]
    /// Cameras whose stream is currently showing video.
    @Published private(set) var live: Set<String> = []

    private let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("fr.teos.AventMonitor/Thumbnails", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "jpg" {
            guard let image = NSImage(contentsOf: url) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            thumbnails[url.deletingPathExtension().lastPathComponent] = Thumbnail(image: image, date: date)
        }
    }

    func store(_ image: CGImage, for cameraID: String) {
        thumbnails[cameraID] = Thumbnail(image: NSImage(cgImage: image, size: .zero), date: Date())
        let url = fileURL(for: cameraID)
        DispatchQueue.global(qos: .utility).async {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    func setLive(_ isLive: Bool, for cameraID: String) {
        if isLive { live.insert(cameraID) } else { live.remove(cameraID) }
    }

    /// Forget every still (on logout: they show the user's home).
    func removeAll() {
        thumbnails = [:]
        live = []
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for cameraID: String) -> URL {
        let safe = cameraID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("jpg")
    }
}
