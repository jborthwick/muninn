import SwiftUI
import Foundation
import ImageIO

/// Simple image cache with memory and disk storage
actor ImageCache {
    static let shared = ImageCache()

    // NSCache is thread-safe, so we can access it synchronously from any thread
    private static let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private var cacheDirectory: URL?
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Muninn/1.0 (iOS podcast player; insight artwork)",
            "Accept": "image/webp,image/avif,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5"
        ]
        return URLSession(configuration: config)
    }()

    private init() {
        // Increase memory cache limits
        Self.memoryCache.countLimit = 200
        Self.memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        
        // Setup cache directory synchronously in init (safe since it's just file system operations)
        if let cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let imageCache = cachePath.appendingPathComponent("ImageCache", isDirectory: true)
            if !FileManager.default.fileExists(atPath: imageCache.path) {
                try? FileManager.default.createDirectory(at: imageCache, withIntermediateDirectories: true)
            }
            cacheDirectory = imageCache
        }
    }

    /// Synchronous memory cache lookup - can be called from any thread
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url) as NSString
        return Self.memoryCache.object(forKey: key)
    }

    /// Generate cache key - nonisolated for sync access
    nonisolated private func cacheKey(for url: URL) -> String {
        let urlString = url.absoluteString
        guard let data = urlString.data(using: .utf8) else {
            return UUID().uuidString + ".img"
        }
        var hash: UInt64 = 5381
        for byte in data {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash) + ".img"
    }


    func image(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)

        // Check memory cache first (already thread-safe)
        if let cached = Self.memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        if let diskImage = loadFromDisk(key: key) {
            let cost = diskImage.pngData()?.count ?? 0
            Self.memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            return diskImage
        }

        // Check if already downloading
        if let existingTask = inFlightRequests[key] {
            return await existingTask.value
        }

        // Download
        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await session.data(from: url) else {
                return nil
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let image = Self.decodeImage(data: data) else {
                return nil
            }

            let cost = data.count
            Self.memoryCache.setObject(image, forKey: key as NSString, cost: cost)
            await self.saveToDisk(image: image, key: key)

            return image
        }

        inFlightRequests[key] = task
        let result = await task.value
        inFlightRequests.removeValue(forKey: key)

        return result
    }

    /// Preload an image into cache
    func preload(url: URL) async {
        _ = await image(for: url)
    }

    /// Check if image is already cached (memory or disk)
    nonisolated func isCached(url: URL) -> Bool {
        let key = cacheKey(for: url)

        // Check memory (thread-safe)
        if Self.memoryCache.object(forKey: key as NSString) != nil {
            return true
        }

        // Check disk
        guard let cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let fileURL = cachePath.appendingPathComponent("ImageCache").appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func loadFromDisk(key: String) -> UIImage? {
        guard let cacheDir = cacheDirectory else { return nil }
        let fileURL = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return Self.decodeImage(data: data)
    }

    private func saveToDisk(image: UIImage, key: String) {
        guard let cacheDir = cacheDirectory else { return }
        // Prefer PNG so WebP-decoded images with alpha/odd color spaces still persist.
        let data = image.pngData() ?? image.jpegData(compressionQuality: 0.85)
        guard let data else { return }
        let fileURL = cacheDir.appendingPathComponent(key)
        try? data.write(to: fileURL)
    }

    /// Decode JPEG/PNG/WebP via UIKit, then ImageIO fallback.
    nonisolated private static func decodeImage(data: Data) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func clearCache() {
        Self.memoryCache.removeAllObjects()
        if let cacheDir = cacheDirectory {
            try? fileManager.removeItem(at: cacheDir)
            
            // Recreate cache directory
            if !fileManager.fileExists(atPath: cacheDir.path) {
                try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
        }
    }
}

// MARK: - Cached Async Image View

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadingURL: URL?

    // Check memory cache synchronously for instant display
    private var memoryCachedImage: UIImage? {
        guard let url = url else { return nil }
        return ImageCache.shared.cachedImage(for: url)
    }

    var body: some View {
        Group {
            // First check sync memory cache, then async-loaded image
            if let cached = memoryCachedImage {
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

    private func loadImage() async {
        guard let url = url else {
            image = nil
            loadingURL = nil
            return
        }

        // Skip if already in memory cache (will be shown via memoryCachedImage)
        if ImageCache.shared.cachedImage(for: url) != nil {
            return
        }

        // Don't reload if same URL and already have image
        if loadingURL == url && image != nil {
            return
        }

        loadingURL = url

        if let cachedImage = await ImageCache.shared.image(for: url) {
            // Only update if URL hasn't changed.
            // Use an explicit transaction so the image load doesn't inherit (and
            // interrupt) whatever SwiftUI transaction is active at the call site —
            // most importantly the navigation slide animation.
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

// Convenience initializer matching AsyncImage API
extension CachedAsyncImage where Placeholder == Color {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.content = content
        self.placeholder = { Color.secondary.opacity(0.2) }
    }
}
