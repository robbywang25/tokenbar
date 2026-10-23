import Foundation

enum GodError: Error, LocalizedError, Equatable {
    case invalidResponse, unavailable, signedOut, denied, expired, conflict, storage
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "工作台返回的数据未通过校验。"
        case .unavailable: return "暂时无法连接工作台，稍后会重试。"
        case .signedOut: return "请重新登录 God 工作台。"
        case .denied: return "此次登录未获授权。"
        case .expired: return "登录确认已过期，请重新开始。"
        case .conflict: return "另一台设备刚更新了数据，正在合并。"
        case .storage: return "登录或同步状态未能安全保存。"
        }
    }
}

struct GodHTTPResponse: Sendable {
    var status: Int
    var data: Data
}

struct GodHTTP: @unchecked Sendable {
    var configuration: URLSessionConfiguration = .ephemeral
    func send(_ request: URLRequest, limit: Int = 2 * 1024 * 1024) async throws -> GodHTTPResponse {
        try await GodHTTPRequest(configuration: configuration, limit: limit).run(request)
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func origin(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw GodError.invalidResponse }
        return url
    }
    static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme == "https" && url.host == origin.host && url.port == origin.port && url.user == nil && url.password == nil && url.fragment == nil
    }
}

/// Data delegates keep large history documents off the main actor, bounded
/// before allocation completes. Neither redirects nor cookies carry authority.
private final class GodHTTPRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let limit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GodHTTPResponse, Error>?
    private var session: URLSession?
    private var data = Data()
    private var status = 0
    private var cancelled = false
    init(configuration: URLSessionConfiguration, limit: Int) { self.configuration = configuration; self.limit = limit }
    func run(_ request: URLRequest) async throws -> GodHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = configuration.copy() as! URLSessionConfiguration
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
                config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                lock.unlock(); task.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; self.lock.unlock()
            self.finish(.failure(CancellationError()))
        }
    }
    private func finish(_ result: Result<GodHTTPResponse, Error>) {
        lock.lock()
        guard let pending = continuation else { lock.unlock(); return }
        continuation = nil; let oldSession = session; session = nil; data = Data()
        lock.unlock(); oldSession?.invalidateAndCancel(); pending.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.expectedContentLength <= limit,
              http.mimeType == "application/json" || (http.expectedContentLength == 0 && (200...299).contains(http.statusCode)) else {
            completionHandler(.cancel); finish(.failure(GodError.invalidResponse)); return
        }
        lock.lock(); status = http.statusCode; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        guard data.count + chunk.count <= limit else { lock.unlock(); finish(.failure(GodError.invalidResponse)); return }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let response = GodHTTPResponse(status: status, data: data); lock.unlock()
        finish(error == nil ? .success(response) : .failure(GodError.unavailable))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(GodError.invalidResponse))
    }
}
