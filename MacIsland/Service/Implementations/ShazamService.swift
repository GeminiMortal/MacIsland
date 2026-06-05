//
//  ShazamService.swift
//  MacIsland
//
//  Created by GeminiMortal on 2026/6/4.
//

import Foundation
import ShazamKit
import AVFoundation
import AppKit
import Combine

// MARK: - Shazam Service

/// 听歌识曲服务 — 使用 ShazamKit + AVAudioEngine 识别正在播放的音乐
final class ShazamService: NSObject, ShazamServiceProtocol, ObservableObject, SHSessionDelegate {
    @Published private(set) var state: ShazamState = .idle

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    private let session = SHSession()
    private var audioEngine: AVAudioEngine?
    private var signatureGenerator: SHSignatureGenerator?
    private var matchContinuation: CheckedContinuation<ShazamResult?, Never>?
    private var isResumed = false

    // MARK: - Init

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - Public API

    func identify(duration: TimeInterval = 3.0) async -> ShazamResult? {
        // 检查麦克风权限
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        switch permission {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                Task { @MainActor in self.state = .error("麦克风权限被拒绝") }
                return nil
            }
        case .denied, .restricted:
            Task { @MainActor in self.state = .error("麦克风权限被拒绝") }
            return nil
        case .authorized:
            break
        @unknown default:
            break
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.matchContinuation = continuation
                self.isResumed = false
                self.startListening(duration: duration)
            }
        }
    }

    func cancel() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.stopListening()
            self.resumeContinuation(with: nil)
            self.state = .idle
        }
    }

    // MARK: - Continuation Safety

    private func resumeContinuation(with result: ShazamResult?) {
        guard !isResumed, let cont = matchContinuation else { return }
        isResumed = true
        matchContinuation = nil
        cont.resume(returning: result)
    }

    // MARK: - Audio Capture

    private func startListening(duration: TimeInterval) {
        state = .listening

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!

        let generator = SHSignatureGenerator()
        self.signatureGenerator = generator
        self.audioEngine = engine

        // tap 在音频线程回调，仅追加 buffer（generator.append 是线程安全的）
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak generator] buffer, _ in
            try? generator?.append(buffer, at: nil)
        }

        do {
            try engine.start()
        } catch {
            print("[Shazam] Audio engine failed: \(error.localizedDescription)")
            cleanupAudio()
            state = .error("音频引擎启动失败")
            resumeContinuation(with: nil)
            return
        }

        // 录制指定时长后停止并匹配
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !isResumed else { return }

            // 先移除 tap，再停止引擎
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil

            guard let sig = self.signatureGenerator?.signature() else {
                self.signatureGenerator = nil
                self.state = .error("无法生成音频签名")
                self.resumeContinuation(with: nil)
                return
            }
            self.signatureGenerator = nil

            self.state = .identifying
            self.session.match(sig)
        }
    }

    private func stopListening() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        signatureGenerator = nil
    }

    private func cleanupAudio() {
        stopListening()
    }

    // MARK: - SHSessionDelegate

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        let mediaItems = match.mediaItems
        guard let item = mediaItems.first else {
            Task { @MainActor [weak self] in
                self?.state = .noMatch
                self?.resumeContinuation(with: nil)
            }
            return
        }

        let result = ShazamResult(
            title: item.title ?? "",
            artist: item.artist ?? "",
            album: "",
            artworkURL: item.artworkURL,
            appleMusicURL: item.appleMusicURL,
            matchConfidence: 1.0
        )

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard !result.title.isEmpty else {
                self.state = .noMatch
                self.resumeContinuation(with: nil)
                return
            }
            self.state = .matched(result)
            self.resumeContinuation(with: result)
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        if let error = error {
            print("[Shazam] Match error: \(error.localizedDescription)")
        }
        Task { @MainActor [weak self] in
            self?.state = .noMatch
            self?.resumeContinuation(with: nil)
        }
    }
}
