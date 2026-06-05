//
//  ArtworkCacheProtocol.swift
//  MacIsland
//
//  Created by GeminiMortal on 2026/6/4.
//

import Foundation
import AppKit

// MARK: - Artwork Cache Manager Protocol

/// 专辑封面缓存管理协议
protocol ArtworkCacheManagerProtocol: AnyObject {
    /// 根据 key 获取缓存的封面图片（先内存，后磁盘）
    func artwork(forKey key: String) -> NSImage?

    /// 存储封面图片到缓存（内存 + 磁盘）
    func store(artwork: NSImage, forKey key: String)

    /// 删除指定 key 的封面缓存
    func removeArtwork(forKey key: String)

    /// 清空所有缓存
    func clearAll()

    /// 清理过期缓存（30天过期，最多200条）
    func cleanupExpired()
}
