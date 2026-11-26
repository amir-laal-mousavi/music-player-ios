import AVFoundation
import Foundation
import MusicCore

/// Plays through AVAudioEngine so `AVAudioUnitEQ` can sit in the signal path.
///
/// The player node is reconnected per file because every file can carry a different
/// processing format; reconnecting while the graph is stopped avoids format clashes.
actor AVAudioEngineBacking: PlaybackBacking {
    nonisolated let events: AsyncStream<PlaybackBackingEvent>
    private let eventsContinuation: AsyncStream<PlaybackBackingEvent>.Continuation

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)

    private var file: AVAudioFile?
    private var settings: EqualizerSettings
    private var generation: UInt64 = 0
    private var scheduleToken = UUID()
    private var startFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44_100
    private var duration: TimeInterval = 0
    private var isPlaying = false
    private var progressTask: Task<Void, Never>?

    init(settings: EqualizerSettings) {
        self.settings = settings
        (events, eventsContinuation) = AsyncStream.makeStream()
        engine.attach(player)
        engine.attach(equalizer)
        applyBands()
    }

    func load(url: URL, generation: UInt64) async throws {
        self.generation = generation
        isPlaying = false
        stopProgress()
        player.stop()
        engine.stop()

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            eventsContinuation.yield(.init(generation: generation, kind: .failed(.unsupportedFormat)))
            throw DomainError.playback(.unsupportedFormat)
        }
        guard file.length > 0, file.processingFormat.sampleRate > 0 else {
            eventsContinuation.yield(.init(generation: generation, kind: .failed(.unsupportedFormat)))
            throw DomainError.playback(.unsupportedFormat)
        }

        self.file = file
        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate
        startFrame = 0

        engine.connect(player, to: equalizer, format: file.processingFormat)
        engine.connect(equalizer, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            eventsContinuation.yield(.init(generation: generation, kind: .failed(.playbackFailed)))
            throw DomainError.playback(.playbackFailed)
        }

        eventsContinuation.yield(.init(generation: generation, kind: .ready(duration: duration)))
        schedule(from: 0)
    }

    func play() async throws {
        guard file != nil else { throw DomainError.playback(.notReady) }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw DomainError.playback(.playbackFailed)
            }
        }
        player.play()
        isPlaying = true
        eventsContinuation.yield(.init(generation: generation, kind: .playing))
        startProgress()
    }

    func pause() async throws {
        player.pause()
        isPlaying = false
        stopProgress()
        eventsContinuation.yield(.init(generation: generation, kind: .paused))
    }

    func seek(to position: TimeInterval) async throws {
        guard let file else { throw DomainError.playback(.notReady) }
        let clamped = min(max(position, 0), duration)
        let frame = AVAudioFramePosition(clamped * sampleRate)
        schedule(from: min(frame, file.length))
        if isPlaying {
            player.play()
            startProgress()
        }
    }

    func stop() async throws {
        player.stop()
        engine.stop()
        isPlaying = false
        stopProgress()
        file = nil
        scheduleToken = UUID()
    }

    var currentPosition: TimeInterval? {
        guard file != nil else { return nil }
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return Double(startFrame) / sampleRate
        }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(Double(startFrame) / sampleRate + played, 0), duration)
    }

    func applyEqualizer(_ settings: EqualizerSettings) async {
        self.settings = settings
        applyBands()
    }

    // MARK: - Private

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        player.stop()
        let token = UUID()
        scheduleToken = token
        startFrame = frame

        let remaining = file.length - frame
        guard remaining > 0 else {
            eventsContinuation.yield(.init(generation: generation, kind: .completed))
            return
        }

        file.framePosition = frame
        player.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { await self?.finished(token: token) }
        }
    }

    private func finished(token: UUID) {
        guard token == scheduleToken, isPlaying else { return }
        isPlaying = false
        stopProgress()
        eventsContinuation.yield(.init(generation: generation, kind: .completed))
    }

    private func startProgress() {
        stopProgress()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.emitProgress()
            }
        }
    }

    private func stopProgress() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func emitProgress() {
        guard isPlaying, let position = currentPosition else { return }
        eventsContinuation.yield(
            .init(
                generation: generation,
                kind: .timeChanged(position: position, duration: duration)
            )
        )
    }

    private func applyBands() {
        equalizer.bypass = !settings.isEnabled
        for (index, band) in equalizer.bands.enumerated() {
            guard index < EqualizerSettings.bandCount else { break }
            band.filterType = .parametric
            band.frequency = EqualizerSettings.bandFrequencies[index]
            band.bandwidth = 1.0
            band.gain = settings.gains[index]
            band.bypass = false
        }
    }
}
