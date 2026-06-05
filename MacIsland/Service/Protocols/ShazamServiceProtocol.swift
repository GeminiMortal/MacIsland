//
//  ShazamServiceProtocol.swift
//  MacIsland
//
//  Created by GeminiMortal on 2026/6/4.
//

import Foundation

// MARK: - Shazam Result

/// Shazam 识别结果
struct ShazamResult: Equatable {
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let appleMusicURL: URL?
    let matchConfidence: Double  // 0.0 - 1.0
}

// MARK: - Shazam State

/// Shazam 识别状态
enum ShazamState: Equatable {
    case idle
    case listening        // 麦克风正在采集音频
    case identifying      // 正在向 Shazam 服务器匹配
    case matched(ShazamResult)
    case noMatch
    case error(String)
}

// MARK: - Shazam Service Protocol

/// 听歌识曲服务协议
protocol ShazamServiceProtocol: AnyObject {
    var state: ShazamState { get }
    var isListening: Bool { get }

    /// 录制指定时长音频并识别歌曲
    /// - Parameter duration: 录制时长（秒），默认 3.0
    /// - Returns: 识别结果，失败返回 nil
    func identify(duration: TimeInterval) async -> ShazamResult?

    /// 取消正在进行的识别
    func cancel()
}
