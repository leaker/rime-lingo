public import Foundation

/// The updater's only network access.
public protocol UpdateTransport: Sendable {
    /// A small file (the manifest, its signature), refused beyond `maxBytes`.
    func data(from url: URL, maxBytes: Int) async throws -> Data
    /// A large file straight to disk at `destination`, cancelled beyond `maxBytes`.
    /// Without `allowsConstrainedNetwork` nothing is transferred in Low Data Mode: that is
    /// how background downloads run, while one the user asked for goes ahead.
    func download(from url: URL, to destination: URL, maxBytes: Int, allowsConstrainedNetwork: Bool,
                  progress: (@Sendable (Double) -> Void)?) async throws
}

public enum UpdateTransportError: Error, Equatable {
    case forbiddenURL
    case badResponse(Int)
    case tooLarge
}

/// URLSession without cookies, cache or credentials; redirects are followed only where
/// `RedirectPolicy` allows.
public final class URLSessionUpdateTransport: UpdateTransport {
    private let session: URLSession

    public convenience init() { self.init(protocolClasses: nil) }

    /// `protocolClasses` lets tests answer requests without a network.
    init(protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        guard RedirectPolicy.allows(initial: url) else { throw UpdateTransportError.forbiddenURL }
        let (bytes, response) = try await session.bytes(from: url)
        try Self.check(response)
        guard response.expectedContentLength <= Int64(maxBytes) else { throw UpdateTransportError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw UpdateTransportError.tooLarge }
            data.append(byte)
        }
        return data
    }

    public func download(from url: URL, to destination: URL, maxBytes: Int, allowsConstrainedNetwork: Bool,
                         progress: (@Sendable (Double) -> Void)?) async throws {
        guard RedirectPolicy.allows(initial: url) else { throw UpdateTransportError.forbiddenURL }
        let request = Self.downloadRequest(url, allowsConstrainedNetwork: allowsConstrainedNetwork)
        let observation = Observation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    observation.clear()
                    do {
                        if let error { throw error }
                        guard let location, let response else { throw UpdateTransportError.badResponse(0) }
                        try Self.check(response)
                        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0
                        guard size <= maxBytes else { throw UpdateTransportError.tooLarge }
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: observation.tooLarge ? UpdateTransportError.tooLarge : error)
                    }
                }
                observation.watch(task, maxBytes: maxBytes, progress: progress)
                task.resume()
            }
        } onCancel: { observation.cancel() }
    }

    static func downloadRequest(_ url: URL, allowsConstrainedNetwork: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsConstrainedNetworkAccess = allowsConstrainedNetwork
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else { throw UpdateTransportError.badResponse(http.statusCode) }
    }

    /// Reports progress and stops a download that grows past its limit.
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var token: NSKeyValueObservation?
        private weak var task: URLSessionTask?
        private var exceeded = false

        var tooLarge: Bool { lock.withLock { exceeded } }

        func watch(_ task: URLSessionDownloadTask, maxBytes: Int, progress: (@Sendable (Double) -> Void)?) {
            let token = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
                if task.countOfBytesReceived > Int64(maxBytes) {
                    self?.lock.withLock { self?.exceeded = true }
                    task.cancel()
                } else if task.countOfBytesExpectedToReceive > 0 {
                    progress?(min(1, Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)))
                }
            }
            lock.withLock {
                self.token = token
                self.task = task
            }
        }

        func clear() { lock.withLock { token = nil } }
        func cancel() { lock.withLock { task }?.cancel() }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, RedirectPolicy.allows(redirectTo: url) else { return nil }
            return request
        }
    }
}
