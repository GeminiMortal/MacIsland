//
//  MusicOrchestrator.swift
//  MacIsland
//
//  Created by GeminiMortal on 2026/6/4.
//

import Foundation
import Combine
import AppKit

// MARK: - Detection Method

enum DetectionMethod: String {
    case none = "无"
    case distributedNotification = "系统通知"
    case appleScript = "AppleScript"
    case cgWindowList = "窗口标题"
    case accessibility = "无障碍"
    case shazam = "听歌识曲"
}

// MARK: - Music Orchestrator

/// 音乐编排器 — 唯一音乐状态源
/// - 自动订阅 SystemMusicService 状态变化
/// - 500ms 轮询回退检测（CGWindowList → 无障碍 → Shazam）
/// - 封面缓存集成
/// - 窗口尺寸同步
@MainActor
final class MusicOrchestrator: ObservableObject {
    // MARK: Published — 唯一音乐状态源

    @Published private(set) var info: MediaPlaybackInfo = .empty
    @Published private(set) var hasMedia: Bool = false
    @Published private(set) var detectionMethod: DetectionMethod = .none
    @Published private(set) var shazamState: ShazamState = .idle

    // MARK: Dependencies

    private let musicService: SystemMusicService
    private weak var lyricsService: LyricsService?
    private weak var timerService: TimerService?
    private let shazamService: ShazamServiceProtocol
    private let artworkCache: ArtworkCacheManagerProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: Internal State

    private var pollTimer: Timer?
    private var lastKnownTitle: String = ""
    private var lastKnownArtist: String = ""
    private var secondsSinceLastInfo: TimeInterval = 0
    private var hasAttemptedShazam: Bool = false
    private var shazamTask: Task<Void, Never>?
    private var lastFallbackTime: Date = .distantPast

    // MARK: - Init

    init(
        musicService: SystemMusicService,
        lyricsService: LyricsService,
        timerService: TimerService,
        shazamService: ShazamServiceProtocol,
        artworkCache: ArtworkCacheManagerProtocol
    ) {
        self.musicService = musicService
        self.lyricsService = lyricsService
        self.timerService = timerService
        self.shazamService = shazamService
        self.artworkCache = artworkCache

        // 监听 Shazam 状态
        if let shazamObservable = shazamService as? ShazamService {
            shazamObservable.$state
                .receive(on: RunLoop.main)
                .assign(to: &$shazamState)
        }

        // 自动订阅 SystemMusicService 变化 — 无需外部手动触发
        musicService.$hasMedia
            .combineLatest(musicService.$info)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasMedia, info in
                self?.onMusicServiceUpdate(hasMedia: hasMedia, info: info)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        // 初始同步
        syncFromMusicService()
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        shazamService.cancel()
        shazamTask?.cancel()
        shazamTask = nil
    }

    // MARK: - SystemMusicService → Orchestrator 自动同步

    /// 当 SystemMusicService 发布变化时自动调用
    private func onMusicServiceUpdate(hasMedia: Bool, info: MediaPlaybackInfo) {
        guard hasMedia, !info.title.isEmpty else {
            if !hasMedia && self.hasMedia {
                self.hasMedia = false
                self.info = .empty
                self.lastKnownTitle = ""
                self.lyricsService?.clearLyrics()
            }
            return
        }

        let songChanged = info.title != lastKnownTitle

        // 更新发布状态
        self.info = info
        self.hasMedia = true

        // 歌曲变化时：完整处理（歌词/封面/检测方法）
        if songChanged {
            self.lastKnownTitle = info.title
            self.lastKnownArtist = info.artist
            self.detectionMethod = musicService.currentAdapter?.supportsAppleScript == true
                ? .appleScript
                : .distributedNotification
            secondsSinceLastInfo = 0
            hasAttemptedShazam = false

            if let artwork = info.artwork {
                artworkCache.store(artwork: artwork, forKey: info.cacheKey)
            } else {
                tryLoadArtworkFromCache()
            }

            Task { [weak self] in
                await self?.lyricsService?.fetchLyrics(
                    title: info.title, artist: info.artist, duration: info.duration
                )
            }
        }
    }


    // MARK: - 500ms Tick（回退检测）

    private func tick() {
        guard musicService.hasMedia || hasMedia else { return }

        // 如果 SystemMusicService 有数据，直接同步进度
        if musicService.hasMedia, !musicService.info.title.isEmpty {
            syncProgress(from: musicService.info)
            return
        }

        // SystemMusicService 无数据 → 回退链
        secondsSinceLastInfo += 0.5

        // CGWindowList + 无障碍（节流：每2秒）
        let now = Date()
        if now.timeIntervalSince(lastFallbackTime) >= 2.0 {
            lastFallbackTime = now
            let musicService = self.musicService
            Task { [weak self] in
                guard let self = self else { return }
                if let fallback = await musicService.attemptFallbackDetection() {
                    await self.applyFallbackResult(fallback)
                }
            }
        }

        // Shazam（>5秒无数据）
        if secondsSinceLastInfo > 5.0 && !hasAttemptedShazam {
            hasAttemptedShazam = true
            startShazamIdentification()
        }
    }

    // MARK: - Fallback Result

    private func applyFallbackResult(_ result: NowPlayingResult) {
        let previousTitle = lastKnownTitle
        let songChanged = result.title != previousTitle

        lastKnownTitle = result.title
        lastKnownArtist = result.artist
        secondsSinceLastInfo = 0
        hasAttemptedShazam = false

        detectionMethod = .cgWindowList
        info = MediaPlaybackInfo(
            title: result.title, artist: result.artist, album: result.album,
            isPlaying: result.isPlaying, duration: result.duration,
            elapsedTime: result.position, artwork: result.artwork ?? info.artwork,
            volume: info.volume, isShuffle: info.isShuffle, repeatMode: info.repeatMode
        )
        hasMedia = true

        if let artwork = result.artwork {
            artworkCache.store(artwork: artwork, forKey: info.cacheKey)
        }
        if result.artwork == nil || result.duration == 0 {
            musicService.enrichMetadata(title: result.title, artist: result.artist)
        }

        if songChanged {
            Task { [weak self] in
                await self?.lyricsService?.fetchLyrics(
                    title: result.title, artist: result.artist, duration: result.duration
                )
            }
        }
    }

    // MARK: - Progress Sync

    private func syncProgress(from serviceInfo: MediaPlaybackInfo) {
        // 仅同步进度，不触发完整状态更新
        guard hasMedia else { return }
        info = MediaPlaybackInfo(
            title: info.title, artist: info.artist, album: info.album,
            isPlaying: serviceInfo.isPlaying, duration: serviceInfo.duration,
            elapsedTime: serviceInfo.elapsedTime,
            artwork: serviceInfo.artwork ?? info.artwork,
            volume: serviceInfo.volume,
            isShuffle: serviceInfo.isShuffle,
            repeatMode: serviceInfo.repeatMode
        )
    }

    // MARK: - Artwork Cache

    private func tryLoadArtworkFromCache() {
        guard info.artwork == nil, !lastKnownTitle.isEmpty else { return }
        let key = MediaPlaybackInfo.cacheKey(title: lastKnownTitle, artist: lastKnownArtist)
        if let cached = artworkCache.artwork(forKey: key) {
            info = MediaPlaybackInfo(
                title: info.title, artist: info.artist, album: info.album,
                isPlaying: info.isPlaying, duration: info.duration,
                elapsedTime: info.elapsedTime, artwork: cached,
                volume: info.volume, isShuffle: info.isShuffle, repeatMode: info.repeatMode
            )
        }
    }

    // MARK: - Shazam

    private func startShazamIdentification() {
        shazamTask?.cancel()
        shazamTask = Task { [weak self] in
            guard let self = self else { return }
            guard let result = await self.shazamService.identify(duration: 3.0) else { return }
            guard !Task.isCancelled else { return }

            var artwork: NSImage?
            if let artURL = result.artworkURL, let (data, _) = try? await URLSession.shared.data(from: artURL) {
                artwork = NSImage(data: data)
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.lastKnownTitle = result.title
                self.lastKnownArtist = result.artist
                self.detectionMethod = .shazam
                self.info = MediaPlaybackInfo(
                    title: result.title, artist: result.artist, album: result.album,
                    isPlaying: true, duration: 0, elapsedTime: 0,
                    artwork: artwork ?? self.info.artwork,
                    volume: self.info.volume, isShuffle: self.info.isShuffle, repeatMode: self.info.repeatMode
                )
                self.hasMedia = true
                self.musicService.enrichMetadata(title: result.title, artist: result.artist)
            }
        }
    }

    // MARK: - Playback Controls (forward to SystemMusicService)

    func togglePlay() { musicService.togglePlay() }
    func nextTrack() { musicService.nextTrack() }
    func previousTrack() { musicService.previousTrack() }
    func seek(to position: TimeInterval) { musicService.seek(to: position) }
    func setVolume(_ volume: Float) { musicService.setVolume(volume) }
    func toggleShuffle() { musicService.toggleShuffle() }
    func cycleRepeat() { musicService.cycleRepeat() }

    // MARK: - Initial Sync

    private func syncFromMusicService() {
        guard musicService.hasMedia, !musicService.info.title.isEmpty else { return }
        onMusicServiceUpdate(hasMedia: true, info: musicService.info)
    }
}
