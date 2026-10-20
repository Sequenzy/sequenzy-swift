import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct SequenzyHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, method: String = "POST", headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct SequenzyHTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Sends one HTTP request. Swapped for a fake in tests.
public protocol SequenzyTransport: Sendable {
    func send(_ request: SequenzyHTTPRequest) async throws -> SequenzyHTTPResponse
}

public struct URLSessionTransport: SequenzyTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: SequenzyHTTPRequest) async throws -> SequenzyHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // The completion-handler API exists on every platform the core
        // supports, including Linux, unlike the async URLSession methods.
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: SequenzyHTTPResponse(status: status, body: data ?? Data()))
            }.resume()
        }
    }
}
