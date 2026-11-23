import Foundation
import Network

final class LocalCallAPIServer {
    typealias Handler = (LocalCallAPICommand, @escaping (LocalCallAPIResponse) -> Void) -> Void
    private let queue = DispatchQueue(label: "app.celldock.local-call-api")
    private let token: String
    private let port: UInt16
    private let host: String
    private let handler: Handler
    private var listener: NWListener?
    private var sessions: [UUID: LocalCallAPISession] = [:]

    /// `host` is 127.0.0.1, or this Mac's Tailscale address for remote access;
    /// a Tailscale listener only accepts peers inside 100.64.0.0/10.
    init(token: String, port: UInt16 = 7576, host: String = "127.0.0.1", handler: @escaping Handler) {
        self.token = token
        self.port = port
        self.host = host
        self.handler = handler
    }

    func start(onState: @escaping (String?) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: DispatchQueue.main.async { onState(nil) }
            case .failed(let error): DispatchQueue.main.async { onState(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.listener != nil, self.sessions.count < 16,
                  self.host == "127.0.0.1" || TailscaleAddress.isPeer(connection.endpoint) else {
                connection.cancel()
                return
            }
            let id = UUID()
            let session = LocalCallAPISession(connection: connection, queue: self.queue,
                                             token: self.token, port: self.port, host: self.host,
                                             handler: self.handler)
            self.sessions[id] = session
            session.onClose = { [weak self] in self?.sessions[id] = nil }
            session.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            let sessions = Array(self.sessions.values)
            self.sessions.removeAll()
            sessions.forEach { $0.close() }
        }
    }
}

private final class LocalCallAPISession {
    var onClose: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let port: UInt16
    private let host: String
    private let handler: LocalCallAPIServer.Handler
    private var data = Data()
    private var closed = false
    private var responding = false
    private var timeout: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, token: String, port: UInt16,
         host: String, handler: @escaping LocalCallAPIServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.port = port
        self.host = host
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        armTimeout(seconds: 5)
        receive()
    }

    private func armTimeout(seconds: Double) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.respond(.error(408, "Timed out; query status before retrying a call action"))
        }
        timeout = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, done, error in
            guard let self, !self.closed else { return }
            if let chunk { self.data.append(chunk) }
            do {
                if let command = try LocalCallAPIProtocol.decode(self.data, token: self.token, port: self.port, host: self.host) {
                    self.armTimeout(seconds: 90)
                    DispatchQueue.main.async {
                        guard !self.queue.sync(execute: { self.closed || self.responding }) else { return }
                        self.handler(command) { response in
                            self.queue.async { self.respond(response) }
                        }
                    }
                } else if done || error != nil {
                    self.respond(.error(400, "Incomplete request"))
                } else {
                    self.receive()
                }
            } catch let error as LocalCallAPIHTTPError {
                self.respond(.error(error.status, error.message))
            } catch {
                self.respond(.error(400, "Invalid request"))
            }
        }
    }

    private func respond(_ response: LocalCallAPIResponse) {
        guard !closed, !responding else { return }
        responding = true
        timeout?.cancel()
        // Bound clients that stop reading a response as well as slow uploads.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close() }
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        connection.cancel()
        onClose?()
        onClose = nil
    }
}

/// Tailscale's CGNAT range (100.64.0.0/10). Tailscale carries this traffic
/// inside WireGuard, so the remote listener relies on it for encryption.
enum TailscaleAddress {
    static func contains(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func isPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(address) = host else { return false }
        return contains(address.debugDescription)
    }

    /// This Mac's Tailscale IPv4 address, if Tailscale is up.
    static func local() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            if let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if contains(value) { return value }
                }
            }
            cursor = item.pointee.ifa_next
        }
        return nil
    }
}
