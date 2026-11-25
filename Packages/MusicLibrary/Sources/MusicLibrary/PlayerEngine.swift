import AVFoundation
import Foundation
import MusicCore

protocol PlaybackBacking: Sendable {
    var events: AsyncStream<PlaybackBackingEvent> { get }
    var currentPosition: TimeInterval? { get async }
    func load(url: URL, autoplay: Bool, generation: UInt64) async throws
    func play() async throws
    func pause() async throws
    func seek(to position: TimeInterval) async throws
    func stop() async throws
}

struct PlaybackBackingEvent: Sendable {
    let generation: UInt64
    let kind: Kind

    enum Kind: Sendable {
        case ready(duration: TimeInterval)
        case playing
        case paused
        case timeChanged(position: TimeInterval, duration: TimeInterval?)
        case completed
        case failed(PlayerError)
    }
}

public actor AVFoundationPlayerEngine: PlayerEngine {
    public private(set) var state: PlaybackState = .idle
    public private(set) var queue: PlaybackQueue?

    private let backing: any PlaybackBacking
    private var stateObservers: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var controlGeneration: UInt64 = 0
    private var pendingAutoplay = false

    public convenience init() throws {
        try self.init(backing: AVPlayerBacking())
    }

    init(
        backing: any PlaybackBacking,
        configureAudioSession: @escaping @Sendable () throws -> Void = configurePlaybackAudioSession
    ) throws {
        self.backing = backing
        try configureAudioSession()
        eventTask = Task { [weak self] in
            for await event in backing.events {
                await self?.process(event)
            }
        }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let interruptions = NotificationCenter.default.notifications(
            named: AVAudioSession.interruptionNotification,
            object: nil
        )
        let routes = NotificationCenter.default.notifications(
            named: AVAudioSession.routeChangeNotification,
            object: nil
        )
        notificationTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await notification in interruptions {
                        await self?.handleInterruptionNotification(notification)
                    }
                }
                group.addTask {
                    for await notification in routes {
                        await self?.handleRouteNotification(notification)
                    }
                }
            }
        }
        #endif
    }

    public nonisolated func observeState() -> AsyncStream<PlaybackState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.addStateObserver(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateObserver(id: id) }
            }
        }
    }

    public func play(_ track: Track) async throws {
        let queue = try PlaybackQueue(tracks: [track])
        try await load(queue: queue)
    }

    public func play(_ tracks: [Track], startingAt index: Int) async throws {
        try await load(queue: PlaybackQueue(tracks: tracks, currentIndex: index))
    }

    public func previous() async throws {
        guard let queue else { throw DomainError.playback(.notReady) }
        try await load(queue: queue.previous())
    }

    public func next() async throws {
        guard let queue else { throw DomainError.playback(.notReady) }
        try await load(queue: queue.next())
    }

    public func pause() async throws {
        guard state.status == .playing || state.status == .loading else {
            throw DomainError.playback(.notReady)
        }
        controlGeneration += 1
        let token = controlGeneration
        let trackID = state.currentTrackID
        pendingAutoplay = false
        do {
            try await backing.pause()
            let position = await backing.currentPosition ?? state.position
            guard controlGeneration == token, trackID != nil else { return }
            publish(try PlaybackState(
                status: .paused,
                currentTrackID: trackID,
                position: position,
                duration: state.duration
            ))
        } catch {
            guard controlGeneration == token, state.status == .playing || state.status == .loading else { return }
            let error = domainError(error)
            fail(error)
            throw error
        }
    }

    public func resume() async throws {
        guard state.status == .paused || isInterrupted(state.status), queue != nil else {
            throw DomainError.playback(.notReady)
        }
        controlGeneration += 1
        let token = controlGeneration
        pendingAutoplay = true
        do {
            try await backing.play()
            guard controlGeneration == token,
                  state.status == .paused || isInterrupted(state.status) else { return }
            publish(try PlaybackState(
                status: .playing,
                currentTrackID: state.currentTrackID,
                position: state.position,
                duration: state.duration
            ))
        } catch {
            guard controlGeneration == token else { return }
            let error = domainError(error)
            fail(error)
            throw error
        }
    }

    public func stop() async throws {
        controlGeneration += 1
        generation += 1
        let token = controlGeneration
        pendingAutoplay = false
        do {
            try await backing.stop()
            guard controlGeneration == token else { return }
            queue = nil
            publish(.idle)
        } catch {
            guard controlGeneration == token else { return }
            let error = domainError(error)
            fail(error)
            throw error
        }
    }

    public func seek(to position: TimeInterval) async throws {
        guard canSeek, queue != nil else { throw DomainError.playback(.notReady) }
        guard position.isFinite, position >= 0, position <= state.duration else {
            throw DomainError.playback(.playbackFailed)
        }
        controlGeneration += 1
        let token = controlGeneration
        do {
            try await backing.seek(to: position)
            guard controlGeneration == token, canSeek, queue != nil else { return }
            let status: PlaybackStatus = state.status == .completed && position < state.duration ? .paused : state.status
            publish(try PlaybackState(
                status: status,
                currentTrackID: state.currentTrackID,
                position: position,
                duration: state.duration
            ))
        } catch {
            guard controlGeneration == token else { return }
            let error = domainError(error)
            fail(error)
            throw error
        }
    }

    func interrupt(reason: PlaybackInterruptionReason) async throws {
        guard state.status == .playing || state.status == .loading else { return }
        controlGeneration += 1
        let token = controlGeneration
        let trackID = state.currentTrackID
        pendingAutoplay = false
        do {
            try await backing.pause()
            let position = await backing.currentPosition ?? state.position
            guard controlGeneration == token, trackID != nil else { return }
            publish(try PlaybackState(
                status: .interrupted(reason),
                currentTrackID: trackID,
                position: position,
                duration: state.duration
            ))
        } catch {
            guard controlGeneration == token else { return }
            let error = domainError(error)
            fail(error)
            throw error
        }
    }

    private func load(queue: PlaybackQueue) async throws {
        generation += 1
        controlGeneration += 1
        let token = generation
        let controlToken = controlGeneration
        self.queue = queue
        pendingAutoplay = true
        publish(try PlaybackState(
            status: .loading,
            currentTrackID: queue.currentTrack.id,
            duration: queue.currentTrack.duration
        ))
        do {
            try await backing.load(url: queue.currentTrack.localURL, autoplay: false, generation: token)
        } catch {
            guard generation == token, controlGeneration == controlToken, state.status == .loading else { return }
            pendingAutoplay = false
            let error = domainError(error)
            fail(error)
            throw error
        }
    }

    private func process(_ event: PlaybackBackingEvent) async {
        guard event.generation == generation else { return }
        await handle(event.kind)
    }

    private func handle(_ event: PlaybackBackingEvent.Kind) async {
        switch event {
        case let .ready(duration):
            guard duration.isFinite, duration >= 0,
                  state.status == .loading || state.status == .playing || state.status == .paused
                    || isInterrupted(state.status),
                  let trackID = state.currentTrackID else { return }
            publish(try PlaybackState(
                status: state.status,
                currentTrackID: trackID,
                position: min(state.position, duration),
                duration: duration
            ))
            if state.status == .loading, pendingAutoplay {
                do {
                    try await startPlayback()
                } catch {
                    fail(domainError(error))
                }
            }
        case .playing:
            guard state.status == .loading || state.status == .paused || isInterrupted(state.status) else { return }
            publish(try PlaybackState(
                status: .playing,
                currentTrackID: state.currentTrackID,
                position: state.position,
                duration: state.duration
            ))
        case .paused:
            guard state.status == .playing || state.status == .loading else { return }
            publish(try PlaybackState(
                status: .paused,
                currentTrackID: state.currentTrackID,
                position: state.position,
                duration: state.duration
            ))
        case let .timeChanged(position, duration):
            guard state.status == .playing || state.status == .paused || isInterrupted(state.status),
                  position.isFinite, position >= 0, queue != nil else { return }
            let nextDuration = duration ?? state.duration
            guard nextDuration.isFinite, nextDuration >= 0, position <= nextDuration else { return }
            publish(try PlaybackState(
                status: state.status,
                currentTrackID: state.currentTrackID,
                position: position,
                duration: nextDuration
            ))
        case .completed:
            guard queue != nil, state.status == .playing else { return }
            pendingAutoplay = false
            publish(try PlaybackState(
                status: .completed,
                currentTrackID: state.currentTrackID,
                position: state.duration,
                duration: state.duration
            ))
        case let .failed(error):
            fail(.playback(error))
        }
    }

    private func startPlayback() async throws {
        controlGeneration += 1
        let token = controlGeneration
        try await backing.play()
        guard controlGeneration == token,
              state.status == .loading || state.status == .paused || isInterrupted(state.status) else { return }
        publish(try PlaybackState(
            status: .playing,
            currentTrackID: state.currentTrackID,
            position: state.position,
            duration: state.duration
        ))
    }

    private func fail(_ error: DomainError) {
        pendingAutoplay = false
        publish(try PlaybackState(
            status: .failed,
            currentTrackID: state.currentTrackID,
            position: state.position,
            duration: state.duration,
            error: error
        ))
    }

    private func domainError(_ error: Error) -> DomainError {
        if let error = error as? DomainError { return error }
        if let error = error as? PlayerError { return .playback(error) }
        return .playback(.playbackFailed)
    }

    private func publish(_ state: PlaybackState) {
        self.state = state
        for continuation in stateObservers.values { continuation.yield(state) }
    }

    private func addStateObserver(
        id: UUID,
        continuation: AsyncStream<PlaybackState>.Continuation
    ) {
        stateObservers[id] = continuation
        continuation.yield(state)
    }

    private func removeStateObserver(id: UUID) {
        stateObservers[id] = nil
    }

    private var canSeek: Bool {
        switch state.status {
        case .playing, .paused, .completed, .interrupted:
            return true
        case .idle, .loading, .failed:
            return false
        }
    }

    private func isInterrupted(_ status: PlaybackStatus) -> Bool {
        if case .interrupted = status { return true }
        return false
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    private func handleInterruptionNotification(_ notification: Notification) async {
        let info = notification.userInfo
        let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        switch type {
        case .began:
            try? await interrupt(reason: .audioSession)
        case .ended:
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.flatMap(AVAudioSession.InterruptionOptions.init(rawValue:))
            if options?.contains(.shouldResume) == true,
               case .interrupted(.audioSession) = state.status {
                try? await resume()
            }
        default:
            break
        }
    }

    private func handleRouteNotification(_ notification: Notification) async {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable || reason == .newDeviceUnavailable else { return }
        try? await interrupt(reason: .routeChange)
    }
    #endif
}

func configurePlaybackAudioSession() throws {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    // The app target must declare UIBackgroundModes audio to continue beyond suspension.
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
    #endif
}

actor AVPlayerBacking: PlaybackBacking {
    let events: AsyncStream<PlaybackBackingEvent>

    private let continuation: AsyncStream<PlaybackBackingEvent>.Continuation
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var currentPosition: TimeInterval? {
        guard let player else { return nil }
        let time = player.currentTime().seconds
        guard time.isFinite, time >= 0 else { return nil }
        return time
    }

    func load(url: URL, autoplay: Bool, generation: UInt64) async throws {
        removeObservers()
        player?.pause()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let status = observed.status
            let errorCode = (observed.error as NSError?)?.code
            Task { await self?.statusChanged(generation, status, errorCode: errorCode) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { await self?.timeControlChanged(generation, status) }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: nil
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { await self?.emit(generation, .timeChanged(position: seconds, duration: nil)) }
        }
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.emit(generation, .completed) }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.emit(generation, .failed(.fileUnavailable)) }
        })
        if autoplay { player.play() }
    }

    func play() async throws {
        guard let player else { throw PlayerError.notReady }
        player.play()
    }

    func pause() async throws {
        player?.pause()
    }

    func seek(to position: TimeInterval) async throws {
        guard let player, player.currentItem != nil else { throw PlayerError.notReady }
        guard position.isFinite, position >= 0 else { throw PlayerError.playbackFailed }
        await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
    }

    func stop() async throws {
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(withNil())
        player = nil
    }

    private func statusChanged(_ generation: UInt64, _ status: AVPlayerItem.Status, errorCode: Int?) async {
        switch status {
        case .readyToPlay:
            guard let player, let item = player.currentItem else { return }
            let duration = item.duration.seconds
            guard duration.isFinite, duration >= 0 else { return }
            emit(generation, .ready(duration: duration))
        case .failed:
            let playerError: PlayerError = errorCode == AVError.fileFormatUnsupported.rawValue
                ? .unsupportedFormat : .fileUnavailable
            emit(generation, .failed(playerError))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func timeControlChanged(_ generation: UInt64, _ status: AVPlayer.TimeControlStatus) async {
        switch status {
        case .playing:
            emit(generation, .playing)
        case .paused:
            emit(generation, .paused)
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }

    private func emit(_ generation: UInt64, _ kind: PlaybackBackingEvent.Kind) {
        continuation.yield(PlaybackBackingEvent(generation: generation, kind: kind))
    }

    private func removeObservers() {
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        statusObservation = nil
        timeControlObservation = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
}
