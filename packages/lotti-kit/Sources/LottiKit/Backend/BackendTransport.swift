import Foundation

/// One open socket to the backend. Frames are JSON text.
public protocol BackendConnection: Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Throws when the socket closes or fails.
    func receive() async throws -> String
    /// A WebSocket ping; throws if no pong arrives. Used to find out whether a socket that looks
    /// open is dead (after the phone slept).
    func ping() async throws
    func close()
}

/// Opens sockets. The app uses `URLSessionBackendTransport`; tests use an in-process mock backend.
public protocol BackendTransport: Sendable {
    func connect(to url: URL, token: String) async throws -> any BackendConnection
}

/// `URLSessionWebSocketTask` transport. The token goes in the `Authorization` header.
public struct URLSessionBackendTransport: BackendTransport {
    public var session: URLSession

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func connect(to url: URL, token: String) async throws -> any BackendConnection {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        return SocketConnection(task: task)
    }

    private final class SocketConnection: BackendConnection, @unchecked Sendable {
        let task: URLSessionWebSocketTask

        init(task: URLSessionWebSocketTask) { self.task = task }

        /// A refused handshake (revoked or unknown token) reaches us as "bad response from the server":
        /// say what happened instead.
        private func translated(_ error: Error) -> Error {
            if let response = task.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
                return BackendError.http(response.statusCode, "")
            }
            return error
        }

        func send(_ text: String) async throws {
            do { try await task.send(.string(text)) } catch { throw translated(error) }
        }

        func receive() async throws -> String {
            do {
                switch try await task.receive() {
                case .string(let text): return text
                case .data(let data): return String(decoding: data, as: UTF8.self)
                @unknown default: throw BackendError.badResponse
                }
            } catch { throw translated(error) }
        }

        func ping() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }

        func close() { task.cancel(with: .goingAway, reason: nil) }
    }
}

/// Where the backend is and who we are.
public struct BackendConfiguration: Equatable, Sendable {
    /// `https://brain.example.com` (or `http://…` on a LAN). The socket is `/ws` on the same host.
    public var baseURL: URL
    /// The device token from pairing (Keychain).
    public var token: String
    public var deviceName: String
    public var appVersion: String
    public var apnsToken: String?

    public init(baseURL: URL, token: String, deviceName: String, appVersion: String, apnsToken: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.apnsToken = apnsToken
    }

    /// `ws(s)://host/ws`.
    public var socketURL: URL? {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.scheme = baseURL.scheme == "http" || baseURL.scheme == "ws" ? "ws" : "wss"
        parts.path = path + "/ws"
        return parts.url
    }
}

/// How long to wait before reconnect attempt n (0-based): doubles from `initial` up to `maximum`.
public struct ReconnectPolicy: Equatable, Sendable {
    public var initial: Duration
    public var maximum: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
        self.initial = initial
        self.maximum = maximum
    }

    public func delay(attempt: Int) -> Duration {
        var delay = initial
        for _ in 0..<max(attempt, 0) {
            delay = delay * 2
            if delay >= maximum { return maximum }
        }
        return min(delay, maximum)
    }
}
