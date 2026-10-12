import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Minimal socket surface so the protocol logic is testable without a network.
public protocol WebSocketTransport: AnyObject, Sendable {
    func send(_ message: WebSocketMessage) async throws
    /// Throws when the socket closes.
    func receive() async throws -> WebSocketMessage
    func close()
}

public typealias WebSocketConnector = @Sendable (URLRequest) -> any WebSocketTransport

public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.resume()
    }

    public static let connector: WebSocketConnector = { URLSessionWebSocketTransport(request: $0) }

    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    public func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
