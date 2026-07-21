import SwiftUI
import Foundation
import UIKit
import Kingfisher

/// Artwork cache backed by Kingfisher (memory + persistent disk in Application Support).
final class ImageCache {
    static let shared = ImageCache()

    private static let diskSizeLimit: UInt = 400 * 1024 * 1024
    private static let memoryCostLimit = 100 * 1024 * 1024
    private static let memoryCountLimit = 200

    private static let kingfisherCache: Kingfisher.ImageCache = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("ArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cache = try! Kingfisher.ImageCache(
            name: "muninn-artwork",
            cacheDirectoryURL: directory
        )
        cache.diskStorage.config.sizeLimit = diskSizeLimit
        cache.diskStorage.config.expiration = .days(365)
        cache.memoryStorage.config.totalCostLimit = memoryCostLimit
        cache.memoryStorage.config.countLimit = memoryCountLimit
        return cache
    }()

    private init() {}

    /// Call once at launch before any artwork loads.
    func configure() {
        KingfisherManager.shared.defaultOptions = Self.defaultOptions()
    }

    /// Synchronous memory or disk lookup for instant display on relaunch.
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        let key = url.cacheKey
        let cache = Self.kingfisherCache

        if let image = cache.retrieveImageInMemoryCache(forKey: key) {
            return image
        }

        guard cache.diskStorage.isCached(forKey: key),
              let data = try? cache.diskStorage.value(forKey: key),
              let image = UIImage(data: data) else {
            return nil
        }

        cache.store(image, forKey: key, options: .init([.cacheMemoryOnly]))
        return image
    }

    func image(for url: URL, downsampleTo size: CGSize? = nil) async -> UIImage? {
        if let cached = cachedImage(for: url) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            KingfisherManager.shared.retrieveImage(
                with: url,
                options: Self.retrieveOptions(downsampleTo: size)
            ) { result in
                continuation.resume(returning: try? result.get().image)
            }
        }
    }

    /// Preload one or more images into the artwork cache.
    func preload(url: URL, downsampleTo size: CGSize? = nil) async {
        await preload(urls: [url], downsampleTo: size)
    }

    func preload(urls: [URL], downsampleTo size: CGSize? = nil) async {
        guard !urls.isEmpty else { return }

        let options = Self.retrieveOptions(downsampleTo: size)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let prefetcher = ImagePrefetcher(
                urls: urls,
                options: options,
                completionHandler: { _, _, _ in
                    continuation.resume()
                }
            )
            prefetcher.start()
        }
    }

    /// Check if image is already cached (memory or disk).
    nonisolated func isCached(url: URL) -> Bool {
        let key = url.cacheKey
        let cache = Self.kingfisherCache
        return cache.retrieveImageInMemoryCache(forKey: key) != nil
            || cache.diskStorage.isCached(forKey: key)
    }

    func clearCache() async {
        let cache = Self.kingfisherCache
        cache.clearMemoryCache()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cache.clearDiskCache {
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    private static func defaultOptions() -> KingfisherOptionsInfo {
        [
            .targetCache(kingfisherCache),
            .requestModifier(ArtworkRequestModifier())
        ]
    }

    private static func retrieveOptions(downsampleTo size: CGSize?) -> KingfisherOptionsInfo {
        var options = defaultOptions()
        if let size, size.width > 0, size.height > 0 {
            options.append(.processor(DownsamplingImageProcessor(size: size)))
        }
        return options
    }
}

// MARK: - Display sizes

/// Pixel dimensions for downsampling (points × screen scale).
enum ArtworkDisplaySize {
    static func pixels(side: CGFloat) -> CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: side * scale, height: side * scale)
    }

    static let list = pixels(side: 60)
    static let episodeRow = pixels(side: 50)
    static let grid = pixels(side: 120)
    static let miniPlayer = pixels(side: 48)
    static let miniPlayerInline = pixels(side: 36)
    static let queue = pixels(side: 50)
    static let podcastDetail = pixels(side: 150)
    static let episodeDetail = pixels(side: 200)
    static let nowPlaying = pixels(side: 280)
    static let nowPlayingBackground = pixels(side: 200)
    static let insightRow = pixels(side: 56)
    static let insightHero = pixels(side: 260)
    static let picker = pixels(side: 44)
    static let searchResult = pixels(side: 50)
}

// MARK: - Request headers

private struct ArtworkRequestModifier: ImageDownloadRequestModifier {
    func modified(for request: URLRequest) -> URLRequest? {
        var request = request
        request.setValue(
            "Muninn/1.0 (iOS podcast player; insight artwork)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "image/webp,image/avif,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        return request
    }
}

// MARK: - Cached Async Image View

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// When set, decodes a downsampled bitmap sized for the view (faster loads, less memory).
    var displaySize: CGSize?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadingURL: URL?

    private var syncCachedImage: UIImage? {
        guard let url = url else { return nil }
        return ImageCache.shared.cachedImage(for: url)
    }

    var body: some View {
        Group {
            if let cached = syncCachedImage {
                content(Image(uiImage: cached))
            } else if let image = image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    func artworkDisplaySize(_ size: CGSize) -> CachedAsyncImage {
        var copy = self
        copy.displaySize = size
        return copy
    }

    func artworkDisplaySize(side: CGFloat) -> CachedAsyncImage {
        artworkDisplaySize(ArtworkDisplaySize.pixels(side: side))
    }

    private func loadImage() async {
        guard let url = url else {
            image = nil
            loadingURL = nil
            return
        }

        if ImageCache.shared.cachedImage(for: url) != nil {
            return
        }

        if loadingURL == url && image != nil {
            return
        }

        loadingURL = url

        if let cachedImage = await ImageCache.shared.image(for: url, downsampleTo: displaySize) {
            if loadingURL == url {
                await MainActor.run {
                    withTransaction(.init(animation: .easeIn(duration: 0.15))) {
                        self.image = cachedImage
                    }
                }
            }
        }
    }
}

import SwiftData

extension ImageCache {
    /// Warms list-sized artwork for every subscribed podcast.
    func prefetchLibraryArtwork(from context: ModelContext) async {
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? context.fetch(descriptor) else { return }
        let urls = podcasts.compactMap(\.artworkURL).compactMap { URL(string: $0) }
        await preload(urls: urls, downsampleTo: ArtworkDisplaySize.list)
    }

    func prefetchInsightArtwork(for insight: EpisodeInsight) async {
        let urls = insight.characters.compactMap(\.artworkURL).compactMap { URL(string: $0) }
        await preload(urls: urls, downsampleTo: ArtworkDisplaySize.insightRow)
    }
}

// Convenience initializer matching AsyncImage API
extension CachedAsyncImage where Placeholder == Color {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.displaySize = nil
        self.content = content
        self.placeholder = { Color.secondary.opacity(0.2) }
    }
}
