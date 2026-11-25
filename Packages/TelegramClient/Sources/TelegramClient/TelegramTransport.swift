import Foundation
#if canImport(TDLibFramework)
import TDLibFramework
#endif

internal protocol TelegramTransport: Sendable {
    func createClientID() -> Int32
    func send(_ request: Data, clientID: Int32)
    func events(for clientID: Int32) -> AsyncStream<Data>
}

internal final class TelegramConnection: @unchecked Sendable {
    let clientID: Int32
    let events: AsyncStream<Data>

    private let transport: TelegramTransport
    private let closeLock = NSLock()
    private var closed = false

    init(transport: TelegramTransport) {
        self.transport = transport
        self.clientID = transport.createClientID()
        self.events = transport.events(for: self.clientID)
    }

    func send(_ request: Data) {
        transport.send(request, clientID: clientID)
    }

    func close() {
        closeLock.lock()
        guard !closed else {
            closeLock.unlock()
            return
        }
        closed = true
        closeLock.unlock()
        transport.send(Data(#"{"@type":"close"}"#.utf8), clientID: clientID)
    }

    deinit {
        close()
    }
}

#if canImport(TDLibFramework)
private func discardTDLibLog(_ level: Int32, _ message: UnsafePointer<CChar>?) {}

private final class TDLibEventHub: @unchecked Sendable {
    static let shared = TDLibEventHub()

    private let lock = NSLock()
    private var continuations: [Int32: AsyncStream<Data>.Continuation] = [:]
    private var pumpStarted = false

    func events(for clientID: Int32) -> AsyncStream<Data> {
        lock.lock()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuations[clientID] = continuation
        let shouldStart = !pumpStarted
        pumpStarted = true
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.remove(clientID)
        }
        if shouldStart {
            Task.detached(priority: .utility) { self.pump() }
        }
        return stream
    }

    private func remove(_ clientID: Int32) {
        lock.lock()
        continuations.removeValue(forKey: clientID)
        lock.unlock()
    }

    private func pump() {
        while true {
            guard let pointer = td_receive(1) else { continue }
            let data = Data(String(cString: pointer).utf8)
            guard let object = try? TDLibJSON.object(from: data),
                  let clientID = try? TDLibJSON.int32(object["@client_id"]) else {
                continue
            }
            let isClosed = TDLibMapper.isAuthorizationClosed(data)
            lock.lock()
            let continuation = continuations[clientID]
            if isClosed {
                continuations.removeValue(forKey: clientID)
            }
            lock.unlock()
            continuation?.yield(data)
            if isClosed { continuation?.finish() }
        }
    }
}

internal struct TDLibTransport: TelegramTransport {
    init() {
        _ = Self.configureLogging
    }

    func createClientID() -> Int32 {
        td_create_client_id()
    }

    func send(_ request: Data, clientID: Int32) {
        var bytes = Array(request)
        bytes.append(0)
        bytes.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return }
            td_send(clientID, pointer)
        }
    }

    func events(for clientID: Int32) -> AsyncStream<Data> {
        TDLibEventHub.shared.events(for: clientID)
    }

    // TDLib request logs can contain authentication secrets.
    private static let configureLogging: Void = {
        td_set_log_message_callback(1024, discardTDLibLog)
    }()
}
#endif
