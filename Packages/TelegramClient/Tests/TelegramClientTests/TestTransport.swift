import Foundation
import MusicCore
@testable import TelegramClient

internal struct TransportRecord: Sendable {
    let clientID: Int32
    let data: Data

    var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var type: String {
        object["@type"] as? String ?? ""
    }

    var extra: String? {
        object["@extra"] as? String
    }
}

internal final class TestTransport: TelegramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var nextClientID: Int32 = 1
    private var continuations: [Int32: AsyncStream<Data>.Continuation] = [:]
    private var records: [TransportRecord] = []
    private var handler: (@Sendable (TransportRecord) -> Void)?
    private let requests: AsyncStream<TransportRecord>
    private let requestContinuation: AsyncStream<TransportRecord>.Continuation

    init() {
        (requests, requestContinuation) = AsyncStream.makeStream()
    }

    func createClientID() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextClientID
        nextClientID += 1
        return id
    }

    func send(_ request: Data, clientID: Int32) {
        let record = TransportRecord(clientID: clientID, data: request)
        lock.lock()
        records.append(record)
        let handler = handler
        lock.unlock()
        requestContinuation.yield(record)
        handler?(record)
    }

    func events(for clientID: Int32) -> AsyncStream<Data> {
        lock.lock()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuations[clientID] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.remove(clientID)
        }
        return stream
    }

    func setHandler(_ handler: @escaping @Sendable (TransportRecord) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func emit(_ object: [String: Any], clientID: Int32? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        lock.lock()
        let id = clientID ?? nextClientID - 1
        let continuation = continuations[id]
        let isClosed = TDLibMapper.isAuthorizationClosed(data)
        lock.unlock()
        continuation?.yield(data)
        if isClosed {
            continuation?.finish()
            remove(id)
        }
    }

    func respond(_ object: [String: Any], to record: TransportRecord) {
        var response = object
        if let extra = record.extra { response["@extra"] = extra }
        try? emit(response, clientID: record.clientID)
    }

    func respondOK(to record: TransportRecord) {
        var response: [String: Any] = ["@type": "ok"]
        if let extra = record.extra { response["@extra"] = extra }
        try? emit(response, clientID: record.clientID)
    }

    func respondError(code: Int32, to record: TransportRecord) {
        var response: [String: Any] = ["@type": "error", "code": code]
        if let extra = record.extra { response["@extra"] = extra }
        try? emit(response, clientID: record.clientID)
    }

    func sentRecords() -> [TransportRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func nextRequest(ofType type: String) async throws -> TransportRecord {
        try await withTimeout {
            for await record in self.requests where record.type == type {
                return record
            }
            throw TestFailure.timedOut
        }
    }

    private func remove(_ clientID: Int32) {
        lock.lock()
        continuations.removeValue(forKey: clientID)
        lock.unlock()
    }
}

internal enum TestFailure: Error {
    case timedOut
    case unexpectedState(TelegramAuthState)
}

internal func withTimeout<T: Sendable>(
    seconds: TimeInterval = 3,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestFailure.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

internal func waitForAuth(
    _ expected: TelegramAuthState,
    from gateway: TelegramGatewayClient
) async throws {
    try await withTimeout {
        let stream = gateway.observeAuthState()
        for await state in stream {
            if state == expected { return }
            if case let .failure(error) = state { throw error }
        }
        throw TestFailure.unexpectedState(expected)
    }
}

internal final class ProgressRecorder: @unchecked Sendable {
    let updates: AsyncStream<DownloadProgress>
    private let continuation: AsyncStream<DownloadProgress>.Continuation
    private let lock = NSLock()
    private var values: [DownloadProgress] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream()
    }

    func record(_ progress: DownloadProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
        continuation.yield(progress)
    }

    func snapshot() -> [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
