//
//  ArtworkCacheManager.swift
//  MacIsland
//
//  Created by GeminiMortal on 2026/6/4.
//

import Foundation
import AppKit
import Combine
import CommonCrypto

// MARK: - Artwork Cache Manager

/// 专辑封面缓存管理 — 双层缓存（内存字典 + 磁盘 JPEG）
/// 存储路径: ~/Library/Application Support/MacIsland/ArtworkCache/
/// 清理策略: 30天过期，最多200条
@MainActor
final class ArtworkCacheManager: ArtworkCacheManagerProtocol, ObservableObject {
    @Published private(set) var cacheCount: Int = 0
    private var memoryCache: [String: NSImage] = [:]
    private let cacheDirectory: URL
    private let metadataURL: URL
    private let diskQueue = DispatchQueue(label: "com.macisland.artworkcache.disk", qos: .utility)

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MacIsland/ArtworkCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDirectory = dir
        self.metadataURL = dir.appendingPathComponent("metadata.plist")
        cleanupExpired()
    }

    // MARK: - Public API

    func artwork(forKey key: String) -> NSImage? {
        if let cached = memoryCache[key] {
            return cached
        }

        let fileURL = cacheDirectory.appendingPathComponent(hashKey(key) + ".jpg")
        guard let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }

        memoryCache[key] = image
        return image
    }

    func store(artwork: NSImage, forKey key: String) {
        if memoryCache[key] == nil { cacheCount += 1 }
        memoryCache[key] = artwork

        // 在主线程将 NSImage 转为 JPEG Data（避免 NSImage 跨 actor 传递）
        guard let tiffData = artwork.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.85]
              ) else { return }

        let fileURL = cacheDirectory.appendingPathComponent(hashKey(key) + ".jpg")
        let hKey = hashKey(key)
        let metaURL = self.metadataURL
        diskQueue.async {
            try? jpegData.write(to: fileURL)
            Self.writeMetadataUpdate(forKey: hKey, date: Date(), url: metaURL)
        }
    }

    func removeArtwork(forKey key: String) {
        if memoryCache.removeValue(forKey: key) != nil { cacheCount = max(0, cacheCount - 1) }

        let fileURL = cacheDirectory.appendingPathComponent(hashKey(key) + ".jpg")
        diskQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func clearAll() {
        memoryCache.removeAll()
        cacheCount = 0
        let dir = self.cacheDirectory
        let metaURL = self.metadataURL
        diskQueue.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            (NSDictionary() as NSDictionary).write(to: metaURL, atomically: true)
        }
    }

    func cleanupExpired() {
        let dir = self.cacheDirectory
        let metaURL = self.metadataURL
        diskQueue.async {
            let calendar = Calendar.current
            let cutoffDate = calendar.date(byAdding: .day, value: -30, to: Date())!

            let metadata: [String: Date] = {
                guard let dict = NSDictionary(contentsOf: metaURL) as? [String: Date] else { return [:] }
                return dict
            }()

            let expiredKeys = metadata.filter { $0.value < cutoffDate }.map { $0.key }
            for key in expiredKeys {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(key + ".jpg"))
            }

            var remaining = metadata.filter { !expiredKeys.contains($0.key) }
            if remaining.count > 200 {
                let sorted = remaining.sorted { $0.value < $1.value }
                let toRemove = sorted.prefix(remaining.count - 200)
                for (key, _) in toRemove {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(key + ".jpg"))
                    remaining.removeValue(forKey: key)
                }
            }

            (remaining as NSDictionary).write(to: metaURL, atomically: true)
        }
    }

    // MARK: - Private Helpers

    private func hashKey(_ key: String) -> String {
        let data = Data(key.lowercased().utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 静态方法：在后台队列中安全地更新 metadata（不依赖 actor-isolated self）
    nonisolated private static func writeMetadataUpdate(forKey fileHash: String, date: Date, url: URL) {
        let metadata: [String: Date] = {
            guard let dict = NSDictionary(contentsOf: url) as? [String: Date] else { return [:] }
            return dict
        }()
        var updated = metadata
        updated[fileHash] = date
        (updated as NSDictionary).write(to: url, atomically: true)
    }
}
